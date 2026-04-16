import { useState, useRef, useEffect } from 'react';
import './App.css';
import aiBrainImg from './images/ai_brain.png';

const AGENT_URL = '/api/invocations';
const POLL_INTERVAL_MS = 2000;
const POLL_MAX_ATTEMPTS = 90;

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

const AGENTS = (import.meta.env.VITE_AGENT_RUNTIME_ARNS || '')
  .split(',')
  .map((arn) => arn.trim())
  .filter(Boolean)
  .map((arn) => {
    const id = arn.split('/').pop();
    const label = id
      .replace(/-[A-Za-z0-9]{6,}$/, '')  // strip random suffix e.g. -4TSwFt5CWU
      .replace(/[_-]+/g, ' ')            // underscores/hyphens → spaces
      .replace(/\b\w/g, (c) => c.toUpperCase()); // title case
    return { label, arn };
  });

const SUGGESTIONS = [
  'What can you help me with?',
  'Summarize your capabilities',
  'Give me an example query',
];

function Avatar({ role }) {
  return (
    <div className={`avatar avatar-${role}`}>
      {role === 'user' ? (
        <svg viewBox="0 0 24 24" fill="currentColor"><path d="M12 12c2.7 0 4.8-2.1 4.8-4.8S14.7 2.4 12 2.4 7.2 4.5 7.2 7.2 9.3 12 12 12zm0 2.4c-3.2 0-9.6 1.6-9.6 4.8v2.4h19.2v-2.4c0-3.2-6.4-4.8-9.6-4.8z"/></svg>
      ) : (
        <img src={aiBrainImg} alt="AI" className="avatar-brain" />
      )}
    </div>
  );
}

function CopyButton({ text }) {
  const [copied, setCopied] = useState(false);
  const copy = () => {
    navigator.clipboard.writeText(text);
    setCopied(true);
    setTimeout(() => setCopied(false), 2000);
  };
  return (
    <button className="copy-btn" onClick={copy} title="Copy">
      {copied ? (
        <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2"><polyline points="20 6 9 17 4 12"/></svg>
      ) : (
        <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2"><rect x="9" y="9" width="13" height="13" rx="2"/><path d="M5 15H4a2 2 0 01-2-2V4a2 2 0 012-2h9a2 2 0 012 2v1"/></svg>
      )}
    </button>
  );
}

function Message({ role, text, isNew }) {
  return (
    <div className={`message-row ${role} ${isNew ? 'slide-in' : ''}`}>
      <Avatar role={role} />
      <div className="bubble-wrap">
        <div className={`bubble bubble-${role}`}>
          <p>{text}</p>
        </div>
        {role === 'agent' && <CopyButton text={text} />}
      </div>
    </div>
  );
}

function TypingIndicator() {
  return (
    <div className="message-row agent slide-in">
      <Avatar role="agent" />
      <div className="bubble bubble-agent typing">
        <span/><span/><span/>
      </div>
    </div>
  );
}

const HISTORY_KEY = 'px_conversations';

function loadHistory() {
  try { return JSON.parse(localStorage.getItem(HISTORY_KEY)) || []; }
  catch { return []; }
}

function saveHistory(list) {
  localStorage.setItem(HISTORY_KEY, JSON.stringify(list));
}

export default function App() {
  const [messages, setMessages] = useState([]);
  const [currentConvId, setCurrentConvId] = useState(null);
  const [history, setHistory] = useState(() => loadHistory());
  const [prompt, setPrompt] = useState('');
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState('');
  const [selectedArn, setSelectedArn] = useState(AGENTS[0]?.arn ?? '');
  const [sidebarOpen, setSidebarOpen] = useState(false);
  const [theme, setTheme] = useState(() => localStorage.getItem('theme') || 'dark');
  const bottomRef = useRef(null);
  const inputRef = useRef(null);

  const selectedAgent = AGENTS.find(a => a.arn === selectedArn) || AGENTS[0];

  useEffect(() => {
    document.documentElement.setAttribute('data-theme', theme);
    localStorage.setItem('theme', theme);
  }, [theme]);

  const toggleTheme = () => setTheme(t => t === 'dark' ? 'light' : 'dark');

  // Persist conversation when messages change
  useEffect(() => {
    if (messages.length === 0) return;
    setHistory((prev) => {
      const title = messages.find(m => m.role === 'user')?.text?.slice(0, 50) || 'Conversation';
      const existing = prev.find(c => c.id === currentConvId);
      let updated;
      if (existing) {
        updated = prev.map(c => c.id === currentConvId ? { ...c, messages, title } : c);
      } else {
        const id = Date.now().toString();
        setCurrentConvId(id);
        updated = [{ id, title, arn: selectedArn, messages, ts: Date.now() }, ...prev].slice(0, 30);
      }
      saveHistory(updated);
      return updated;
    });
  }, [messages]);

  const loadConversation = (conv) => {
    setMessages(conv.messages);
    setCurrentConvId(conv.id);
    setSelectedArn(conv.arn);
    setError('');
    setSidebarOpen(false);
  };

  const deleteConversation = (e, id) => {
    e.stopPropagation();
    setHistory((prev) => {
      const updated = prev.filter(c => c.id !== id);
      saveHistory(updated);
      return updated;
    });
    if (currentConvId === id) {
      setMessages([]);
      setCurrentConvId(null);
    }
  };

  useEffect(() => {
    bottomRef.current?.scrollIntoView({ behavior: 'smooth' });
  }, [messages, loading]);

  const sendMessage = async (text) => {
    if (!text.trim() || loading) return;
    setPrompt('');
    setError('');
    setMessages((prev) => [...prev, { role: 'user', text, id: Date.now() }]);
    setLoading(true);
    try {
      const submitRes = await fetch(AGENT_URL, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ prompt: text, runtimeArn: selectedArn }),
      });

      const submitRaw = await submitRes.text();
      if (!submitRes.ok) throw new Error(`Server error ${submitRes.status}: ${submitRaw}`);

      let submitData = {};
      try {
        submitData = JSON.parse(submitRaw);
      } catch {
        submitData = {};
      }

      // Backward compatibility if backend returns immediate response.
      if (submitData?.response) {
        setMessages((prev) => [...prev, { role: 'agent', text: submitData.response, id: Date.now() }]);
        return;
      }

      const requestId = submitData?.requestId;
      if (!requestId) {
        throw new Error(`Unexpected submit response: ${submitRaw}`);
      }

      let reply = '';
      for (let i = 0; i < POLL_MAX_ATTEMPTS; i += 1) {
        const pollRes = await fetch(`${AGENT_URL}/${encodeURIComponent(requestId)}`);
        const pollRaw = await pollRes.text();
        if (!pollRes.ok) {
          throw new Error(`Status error ${pollRes.status}: ${pollRaw}`);
        }

        let pollData = {};
        try {
          pollData = JSON.parse(pollRaw);
        } catch {
          pollData = {};
        }

        const status = pollData?.status;
        if (status === 'COMPLETED') {
          reply = pollData.response || '';
          break;
        }

        if (status === 'FAILED') {
          throw new Error(pollData.error || 'Async request failed');
        }

        await sleep(POLL_INTERVAL_MS);
      }

      if (!reply) {
        throw new Error('Request is still processing. Please try again in a moment.');
      }

      setMessages((prev) => [...prev, { role: 'agent', text: reply, id: Date.now() }]);
    } catch (err) {
      setError(err.message);
    } finally {
      setLoading(false);
      setTimeout(() => inputRef.current?.focus(), 50);
    }
  };

  const handleSubmit = (e) => {
    e.preventDefault();
    sendMessage(prompt.trim());
  };

  const handleKeyDown = (e) => {
    if (e.key === 'Enter' && !e.shiftKey) {
      e.preventDefault();
      sendMessage(prompt.trim());
    }
  };

  const clearChat = () => {
    setMessages([]);
    setCurrentConvId(null);
    setError('');
    inputRef.current?.focus();
  };

  return (
    <div className="app">
      {/* Sidebar overlay */}
      {sidebarOpen && <div className="overlay" onClick={() => setSidebarOpen(false)} />}

      {/* Sidebar */}
      <aside className={`sidebar ${sidebarOpen ? 'open' : ''}`}>
        <div className="sidebar-header">
          <div className="brand">
            <div className="brand-icon">
              <svg viewBox="0 0 24 24" fill="currentColor"><path d="M12 2L2 7l10 5 10-5-10-5zM2 17l10 5 10-5M2 12l10 5 10-5"/></svg>
            </div>
            <span>PX AI Agentic Platform</span>
          </div>
          <button className="close-sidebar" onClick={() => setSidebarOpen(false)}>
            <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2"><line x1="18" y1="6" x2="6" y2="18"/><line x1="6" y1="6" x2="18" y2="18"/></svg>
          </button>
        </div>

        <div className="sidebar-section">
          <p className="sidebar-label">Active Agent</p>
          {AGENTS.map((a) => (
            <button
              key={a.arn}
              className={`agent-item ${a.arn === selectedArn ? 'active' : ''}`}
              onClick={() => { setSelectedArn(a.arn); setMessages([]); setError(''); setSidebarOpen(false); }}
            >
              <div className="agent-item-dot" />
              <div>
                <div className="agent-item-name">{a.label}</div>
              </div>
            </button>
          ))}
        </div>

        <div className="sidebar-section">
          <p className="sidebar-label">Appearance</p>
          <button className="sidebar-action theme-toggle" onClick={toggleTheme}>
            {theme === 'dark' ? (
              <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2"><circle cx="12" cy="12" r="5"/><line x1="12" y1="1" x2="12" y2="3"/><line x1="12" y1="21" x2="12" y2="23"/><line x1="4.22" y1="4.22" x2="5.64" y2="5.64"/><line x1="18.36" y1="18.36" x2="19.78" y2="19.78"/><line x1="1" y1="12" x2="3" y2="12"/><line x1="21" y1="12" x2="23" y2="12"/><line x1="4.22" y1="19.78" x2="5.64" y2="18.36"/><line x1="18.36" y1="5.64" x2="19.78" y2="4.22"/></svg>
            ) : (
              <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2"><path d="M21 12.79A9 9 0 1111.21 3 7 7 0 0021 12.79z"/></svg>
            )}
            {theme === 'dark' ? 'Light mode' : 'Dark mode'}
          </button>
        </div>

        <div className="sidebar-section">
          <p className="sidebar-label">Actions</p>
          <button className="sidebar-action" onClick={() => { clearChat(); setSidebarOpen(false); }}>
            <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2"><line x1="12" y1="5" x2="12" y2="19"/><line x1="5" y1="12" x2="19" y2="12"/></svg>
            New conversation
          </button>
        </div>

        {history.length > 0 && (
          <div className="sidebar-section sidebar-history">
            <p className="sidebar-label">Recent Conversations</p>
            {history.map((conv) => (
              <div
                key={conv.id}
                className={`history-item ${conv.id === currentConvId ? 'active' : ''}`}
                onClick={() => loadConversation(conv)}
              >
                <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2"><path d="M21 15a2 2 0 01-2 2H7l-4 4V5a2 2 0 012-2h14a2 2 0 012 2z"/></svg>
                <span className="history-title">{conv.title}</span>
                <button
                  className="history-delete"
                  onClick={(e) => deleteConversation(e, conv.id)}
                  title="Delete"
                >
                  <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2"><line x1="18" y1="6" x2="6" y2="18"/><line x1="6" y1="6" x2="18" y2="18"/></svg>
                </button>
              </div>
            ))}
          </div>
        )}
      </aside>

      {/* Main layout */}
      <div className="main-layout">
        <header className="topbar">
          <button className="menu-btn" onClick={() => setSidebarOpen(true)}>
            <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2"><line x1="3" y1="12" x2="21" y2="12"/><line x1="3" y1="6" x2="21" y2="6"/><line x1="3" y1="18" x2="21" y2="18"/></svg>
          </button>
          <div className="topbar-brand">
            <div className="topbar-logo">
              <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2"><path d="M12 2L2 7l10 5 10-5-10-5zM2 17l10 5 10-5M2 12l10 5 10-5"/></svg>
            </div>
            <span className="topbar-title">PX AI Agentic Platform</span>
          </div>
          <div className="topbar-center">
            <div className="status-dot" />
            <span className="topbar-agent">{selectedAgent.label}</span>
          </div>
        </header>

        <main className="chat-window">
          {messages.length === 0 && !loading && (
            <div className="welcome">
              <div className="welcome-icon">
                <svg viewBox="0 0 24 24" fill="currentColor"><path d="M12 2L2 7l10 5 10-5-10-5zM2 17l10 5 10-5M2 12l10 5 10-5"/></svg>
              </div>
              <h2>How can I help you today?</h2>
              <div className="suggestions">
                {SUGGESTIONS.map((s) => (
                  <button key={s} className="suggestion" onClick={() => sendMessage(s)}>{s}</button>
                ))}
              </div>
            </div>
          )}

          {messages.map((m, i) => (
            <Message key={m.id} role={m.role} text={m.text} isNew={i === messages.length - 1} />
          ))}
          {loading && <TypingIndicator />}
          {error && (
            <div className="error-banner">
              <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2"><circle cx="12" cy="12" r="10"/><line x1="12" y1="8" x2="12" y2="12"/><line x1="12" y1="16" x2="12.01" y2="16"/></svg>
              {error}
            </div>
          )}
          <div ref={bottomRef} />
        </main>

        <div className="input-area">
          <form className="input-form" onSubmit={handleSubmit}>
            <textarea
              ref={inputRef}
              className="input-field"
              placeholder="Ask anything..."
              value={prompt}
              onChange={(e) => setPrompt(e.target.value)}
              onKeyDown={handleKeyDown}
              disabled={loading}
              rows={1}
            />
            <button type="submit" className="send-btn" disabled={loading || !prompt.trim()}>
              <svg viewBox="0 0 24 24" fill="currentColor"><path d="M2.01 21L23 12 2.01 3 2 10l15 2-15 2z"/></svg>
            </button>
          </form>
          <p className="input-hint">Enter to send · Shift+Enter for new line</p>
        </div>
      </div>
    </div>
  );
}



