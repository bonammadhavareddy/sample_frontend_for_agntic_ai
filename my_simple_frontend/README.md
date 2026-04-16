# PX AI Agentic Platform — Simple Frontend

A lightweight React chat UI for Amazon Bedrock AgentCore. No CDK required. Supports one or many AgentCore Runtime ARNs with a sidebar agent switcher and persistent conversation history.

---

## Architecture

```
Browser → CloudFront → S3 (static assets)
                     → API Gateway → Lambda (SigV4 proxy) → AgentCore Runtime
```

In local dev, Vite's dev server proxies `/api` to a local Node.js server that performs the SigV4 signing.

---

## Prerequisites

- Node.js 18+
- AWS CLI v2, configured with credentials (`aws configure` or environment variables)
- Permissions: `bedrock-agentcore:InvokeAgentRuntime` on your runtime ARN(s)

---

## Local Development

### 1. Install dependencies

```bash
cd my_simple_frontend
npm install
```

### 2. Configure your ARN(s)

Edit `.env` in the `my_simple_frontend/` folder:

**Single ARN:**
```env
VITE_AGENT_RUNTIME_ARNS=arn:aws:bedrock-agentcore:eu-central-1:111111111111:runtime/my-agent-id
```

**Multiple ARNs** (comma-separated, no spaces):
```env
VITE_AGENT_RUNTIME_ARNS=arn:aws:bedrock-agentcore:eu-central-1:111111111111:runtime/agent-one,arn:aws:bedrock-agentcore:us-east-1:111111111111:runtime/agent-two
```

> The sidebar will automatically list each agent. The label is derived from the runtime ID (random suffix stripped, underscores replaced with spaces, title-cased).

### 3. Set AWS credentials

The local Node.js API server signs requests using your local credentials. Any of these work:

```bash
# Option A — AWS profile
export AWS_PROFILE=my-profile

# Option B — environment variables
export AWS_ACCESS_KEY_ID=...
export AWS_SECRET_ACCESS_KEY=...
export AWS_SESSION_TOKEN=...      # if using temporary credentials

# Option C — SSO / IAM Identity Center (already configured via aws configure sso)
aws sso login --profile my-profile
export AWS_PROFILE=my-profile
```

### 4. Start the dev server

```bash
npm run dev
```

This starts two processes concurrently:
- **UI** — Vite dev server on `http://localhost:5173`
- **API** — Node.js proxy server on `http://localhost:3001`

Open `http://localhost:5173` in your browser.

---

## Deploy to AWS (S3 + CloudFront + Lambda)

> Run `bash deploy.sh` once to create all resources. Re-run it anytime to update the Lambda code or frontend assets.

### 1. Configure ARN(s) in `deploy.sh`

Open `deploy.sh` and edit the `AGENT_RUNTIME_ARNS` line near the top:

**Single ARN:**
```bash
AGENT_RUNTIME_ARNS="arn:aws:bedrock-agentcore:eu-central-1:111111111111:runtime/my-agent-id"
```

**Multiple ARNs** (comma-separated, no spaces):
```bash
AGENT_RUNTIME_ARNS="arn:aws:bedrock-agentcore:eu-central-1:111111111111:runtime/agent-one,arn:aws:bedrock-agentcore:us-east-1:111111111111:runtime/agent-two"
```

Also set the correct AWS region:
```bash
REGION="eu-central-1"
```

### 2. Run the deploy script

```bash
bash deploy.sh
```

The script performs the following steps automatically:

| Step | What it does |
|------|-------------|
| 1/7 | Builds the React frontend with `VITE_AGENT_RUNTIME_ARNS` injected |
| 2/7 | Creates an S3 bucket (private, no public access) |
| 3/7 | Creates an IAM role for Lambda with `bedrock-agentcore:InvokeAgentRuntime` on all ARNs |
| 4/7 | Deploys/updates the Lambda proxy function with `AGENT_RUNTIME_ARNS` as an env var |
| 5/7 | Creates an API Gateway HTTP API routing `POST /api/invocations` to Lambda |
| 6/7 | Creates a CloudFront distribution (OAC) pointing to S3 and the API Gateway |
| 7/7 | Uploads the built frontend to S3 |

At the end the script prints the CloudFront URL. The site is live immediately.

### 3. Re-deploying after changes

Just run `bash deploy.sh` again. It will:
- Rebuild and re-upload the frontend
- Update Lambda code and environment variables
- Skip resource creation steps (S3, IAM, API GW, CloudFront already exist)

---

## Adding or changing agents after deployment

1. Update `AGENT_RUNTIME_ARNS` in `deploy.sh`
2. Re-run `bash deploy.sh`

That's it — the Lambda IAM policy, Lambda env var, and frontend bundle are all updated in one step.

---

## Project structure

```
my_simple_frontend/
├── deploy.sh          # One-shot AWS deploy script
├── server.js          # Local dev API proxy (SigV4 signing)
├── vite.config.js     # Vite config (proxies /api → server.js in dev)
├── .env               # Local dev ARN config (not used in production builds)
├── lambda/
│   └── index.py       # Lambda proxy — validates ARN allowlist, calls AgentCore
└── src/
    ├── App.jsx        # Main React app (agent switcher, chat, conversation history)
    └── App.css        # Styles
```

---

## Environment variables reference

| Variable | Where set | Purpose |
|---|---|---|
| `VITE_AGENT_RUNTIME_ARNS` | `.env` (dev) / `deploy.sh` (prod build) | Comma-separated ARNs baked into the frontend bundle |
| `AGENT_RUNTIME_ARNS` | Lambda env var (set by `deploy.sh`) | Allowlist for the Lambda proxy — validates frontend requests |
| `AWS_REGION` | Lambda runtime (automatic) | Region used by Lambda to build the AgentCore endpoint URL |

---

## Notes

- The `.env` file is **only for local dev**. It has no effect on production builds — `deploy.sh` injects `VITE_AGENT_RUNTIME_ARNS` directly at build time.
- Conversation history is stored in the browser's `localStorage` (up to 30 conversations). It is never sent to any server.
- The Lambda proxy validates every `runtimeArn` sent by the frontend against the `AGENT_RUNTIME_ARNS` allowlist, rejecting unknown ARNs with a `403`.
