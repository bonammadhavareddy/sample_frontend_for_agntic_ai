"""Lambda proxy: receives POST /api/invocations from CloudFront,
SigV4-signs the request using the Lambda execution role, and calls AgentCore."""

import base64
import json
import os
import urllib.error
import urllib.parse
import urllib.request

import boto3
from botocore.auth import SigV4Auth
from botocore.awsrequest import AWSRequest

# Comma-separated list of allowed ARNs, e.g. "arn1,arn2"
_ARNS_RAW = os.environ.get("AGENT_RUNTIME_ARNS") or os.environ.get("AGENT_RUNTIME_ARN", "")
ALLOWED_ARNS = [a.strip() for a in _ARNS_RAW.split(",") if a.strip()]
DEFAULT_ARN = ALLOWED_ARNS[0] if ALLOWED_ARNS else ""
REGION = os.environ.get("AWS_REGION", "eu-central-1")

CORS_HEADERS = {
    "Access-Control-Allow-Origin": "*",
    "Access-Control-Allow-Methods": "POST, OPTIONS",
    "Access-Control-Allow-Headers": "Content-Type",
}


def _json_response(status_code, body):
    return {
        "statusCode": status_code,
        "headers": {**CORS_HEADERS, "Content-Type": "application/json"},
        "body": json.dumps(body),
    }


def handler(event, context):
    rc = event.get("requestContext", {})
    method = (
        rc.get("http", {}).get("method") or event.get("httpMethod", "POST")
    ).upper()

    if method == "OPTIONS":
        return {"statusCode": 200, "headers": CORS_HEADERS, "body": ""}

    if not ALLOWED_ARNS:
        return _json_response(500, {"error": "No AGENT_RUNTIME_ARNS configured"})

    raw_body = event.get("body") or "{}"
    if event.get("isBase64Encoded"):
        raw_body = base64.b64decode(raw_body).decode("utf-8")

    try:
        payload = json.loads(raw_body)
    except Exception:
        return _json_response(400, {"error": "Invalid JSON body"})

    prompt = payload.get("prompt", "")

    # Frontend may request a specific ARN; validate it against the allowlist
    requested_arn = payload.get("runtimeArn", "").strip()
    if requested_arn:
        if requested_arn not in ALLOWED_ARNS:
            return _json_response(403, {"error": "Requested runtimeArn is not allowed"})
        selected_arn = requested_arn
    else:
        selected_arn = DEFAULT_ARN

    encoded_arn = urllib.parse.quote(selected_arn, safe="")
    url = (
        f"https://bedrock-agentcore.{REGION}.amazonaws.com"
        f"/runtimes/{encoded_arn}/invocations?qualifier=DEFAULT"
    )

    request_body = json.dumps({"prompt": prompt}).encode("utf-8")

    session = boto3.Session()
    credentials = session.get_credentials().get_frozen_credentials()
    aws_req = AWSRequest(
        method="POST",
        url=url,
        data=request_body,
        headers={"Content-Type": "application/json"},
    )
    SigV4Auth(credentials, "bedrock-agentcore", REGION).add_auth(aws_req)
    prepared = aws_req.prepare()

    body_bytes = (
        prepared.body
        if isinstance(prepared.body, bytes)
        else prepared.body.encode("utf-8")
    )
    http_req = urllib.request.Request(
        url, data=body_bytes, headers=dict(prepared.headers), method="POST"
    )

    try:
        with urllib.request.urlopen(http_req, timeout=60) as resp:
            raw_response = resp.read().decode("utf-8")
    except urllib.error.HTTPError as exc:
        error_body = exc.read().decode("utf-8")
        # Always return 200 so CloudFront doesn't intercept 4xx/5xx
        # and serve index.html (SPA fallback) instead of the real error.
        return _json_response(200, {"error": f"AgentCore {exc.code}: {error_body}"})
    except Exception as exc:
        return _json_response(200, {"error": str(exc)})

    try:
        data = json.loads(raw_response)
        response_text = (
            (
                data.get("response")
                or data.get("content")
                or data.get("text")
                or data.get("message")
                or data.get("output")
                or raw_response
            )
            if isinstance(data, dict)
            else raw_response
        )
    except Exception:
        response_text = raw_response

    return _json_response(200, {"response": response_text})
