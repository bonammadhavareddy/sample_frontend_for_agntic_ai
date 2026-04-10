#!/usr/bin/env python3
"""Local no-auth proxy for invoking a deployed AgentCore runtime.

This server accepts POST /invocations with {"prompt": "..."} and forwards requests
to Amazon Bedrock AgentCore using SigV4 with local AWS credentials.
"""

import json
import os
import urllib.parse
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import boto3
import requests
from botocore.auth import SigV4Auth
from botocore.awsrequest import AWSRequest


def _extract_text_from_json(data):
    if isinstance(data, str):
        return data
    if isinstance(data, dict):
        return (
            data.get("response")
            or data.get("content")
            or data.get("text")
            or data.get("message")
            or data.get("output")
            or json.dumps(data)
        )
    return ""


class RuntimeProxyHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def do_POST(self):
        if self.path != "/invocations":
            self._send_json(404, {"error": "Not found"})
            return

        runtime_arn = os.getenv("REMOTE_AGENT_RUNTIME_ARN")
        region = os.getenv("REMOTE_AGENT_REGION") or os.getenv("AWS_REGION") or "ap-south-1"

        if not runtime_arn:
            self._send_json(500, {
                "error": "Missing REMOTE_AGENT_RUNTIME_ARN environment variable"
            })
            return

        try:
            content_len = int(self.headers.get("Content-Length", "0"))
            body = self.rfile.read(content_len).decode("utf-8") if content_len > 0 else "{}"
            req_payload = json.loads(body or "{}")
        except Exception as exc:
            self._send_json(400, {"error": f"Invalid JSON body: {exc}"})
            return

        prompt = req_payload.get("prompt") if isinstance(req_payload, dict) else None
        if not prompt:
            self._send_json(400, {"error": "Missing 'prompt' in request body"})
            return

        encoded_arn = urllib.parse.quote(runtime_arn, safe="")
        url = (
            f"https://bedrock-agentcore.{region}.amazonaws.com"
            f"/runtimes/{encoded_arn}/invocations?qualifier=DEFAULT"
        )

        runtime_payload = json.dumps({"prompt": prompt})
        session_id = f"proxy-session-{uuid.uuid4().hex}"
        trace_id = f"proxy-trace-{uuid.uuid4().hex}"

        base_headers = {
            "Content-Type": "application/json",
            "X-Amzn-Bedrock-AgentCore-Runtime-Session-Id": session_id,
            "X-Amzn-Trace-Id": trace_id,
        }

        try:
            session = boto3.Session(region_name=region)
            creds = session.get_credentials()
            if creds is None:
                self._send_json(500, {"error": "AWS credentials not found"})
                return

            frozen = creds.get_frozen_credentials()
            aws_request = AWSRequest(method="POST", url=url, data=runtime_payload, headers=base_headers)
            SigV4Auth(frozen, "bedrock-agentcore", region).add_auth(aws_request)

            signed_headers = dict(aws_request.headers.items())
            response = requests.post(url, data=runtime_payload, headers=signed_headers, timeout=120)

            if not response.ok:
                self._send_json(response.status_code, {
                    "error": "AgentCore invocation failed",
                    "status": response.status_code,
                    "details": response.text,
                })
                return

            content_type = response.headers.get("content-type", "")
            response_text = ""

            if "application/json" in content_type:
                try:
                    data = response.json()
                    response_text = _extract_text_from_json(data)
                except Exception:
                    response_text = response.text
            elif "text/event-stream" in content_type:
                parts = []
                for line in response.text.splitlines():
                    if line.startswith("data: "):
                        token = line[6:]
                        try:
                            parsed = json.loads(token)
                            parts.append(parsed if isinstance(parsed, str) else str(parsed))
                        except Exception:
                            parts.append(token)
                response_text = "".join(parts)
            else:
                response_text = response.text

            self._send_json(200, {"response": response_text})

        except requests.Timeout:
            self._send_json(504, {"error": "Timeout calling AgentCore runtime"})
        except Exception as exc:
            self._send_json(500, {"error": f"Proxy failure: {exc}"})

    def do_GET(self):
        if self.path == "/":
            self._send_json(200, {
                "status": "ok",
                "message": "Runtime proxy is running. Open frontend at http://localhost:5173",
                "endpoints": ["/health", "/invocations"],
            })
            return

        if self.path == "/health":
            self._send_json(200, {"status": "ok"})
            return
        self._send_json(404, {"error": "Not found"})

    def _send_json(self, status_code, payload):
        body = json.dumps(payload).encode("utf-8")
        self.send_response(status_code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


def main():
    host = "0.0.0.0"
    port = int(os.getenv("RUNTIME_PROXY_PORT", "8080"))
    server = ThreadingHTTPServer((host, port), RuntimeProxyHandler)
    print(f"Runtime proxy listening on http://{host}:{port}")
    server.serve_forever()


if __name__ == "__main__":
    main()
