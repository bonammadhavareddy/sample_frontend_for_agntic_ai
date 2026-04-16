"""Async Lambda proxy for AgentCore.

API flow:
- POST /api/invocations: create a job and enqueue background processing
- GET /api/invocations/{requestId}: poll for status/result

Worker flow:
- Lambda invokes itself asynchronously to process queued jobs.
"""

import base64
import json
import os
import socket
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid

import boto3
from botocore.auth import SigV4Auth
from botocore.awsrequest import AWSRequest

_ARNS_RAW = os.environ.get("AGENT_RUNTIME_ARNS") or os.environ.get("AGENT_RUNTIME_ARN", "")
ALLOWED_ARNS = [a.strip() for a in _ARNS_RAW.split(",") if a.strip()]
DEFAULT_ARN = ALLOWED_ARNS[0] if ALLOWED_ARNS else ""
REGION = os.environ.get("AWS_REGION", "eu-central-1")
JOBS_TABLE_NAME = os.environ.get("JOBS_TABLE_NAME", "agentcore-frontend-jobs")

try:
    AGENTCORE_ASYNC_HTTP_TIMEOUT_SECONDS = int(
        os.environ.get("AGENTCORE_ASYNC_HTTP_TIMEOUT_SECONDS", "120")
    )
except ValueError:
    AGENTCORE_ASYNC_HTTP_TIMEOUT_SECONDS = 120
AGENTCORE_ASYNC_HTTP_TIMEOUT_SECONDS = max(5, min(840, AGENTCORE_ASYNC_HTTP_TIMEOUT_SECONDS))

dynamodb = boto3.resource("dynamodb")
jobs_table = dynamodb.Table(JOBS_TABLE_NAME)
lambda_client = boto3.client("lambda")

CORS_HEADERS = {
    "Access-Control-Allow-Origin": "*",
    "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
    "Access-Control-Allow-Headers": "Content-Type",
}


def _json_response(status_code, body):
    return {
        "statusCode": status_code,
        "headers": {**CORS_HEADERS, "Content-Type": "application/json"},
        "body": json.dumps(body),
    }


def _now_ms():
    return int(time.time() * 1000)


def _extract_method(event):
    rc = event.get("requestContext", {})
    return (rc.get("http", {}).get("method") or event.get("httpMethod", "POST")).upper()


def _extract_path(event):
    return event.get("rawPath") or event.get("path") or "/"


def _parse_json_body(event):
    raw_body = event.get("body") or "{}"
    if event.get("isBase64Encoded"):
        raw_body = base64.b64decode(raw_body).decode("utf-8")
    try:
        return json.loads(raw_body)
    except Exception:
        return None


def _resolve_arn(payload):
    requested_arn = (payload.get("runtimeArn") or "").strip()
    if requested_arn:
        if requested_arn not in ALLOWED_ARNS:
            raise ValueError("Requested runtimeArn is not allowed")
        return requested_arn
    return DEFAULT_ARN


def _invoke_agentcore(prompt, selected_arn, timeout_seconds):
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

    with urllib.request.urlopen(http_req, timeout=timeout_seconds) as resp:
        return resp.read().decode("utf-8")


def _extract_response_text(raw_response):
    try:
        data = json.loads(raw_response)
        if isinstance(data, dict):
            return (
                data.get("response")
                or data.get("content")
                or data.get("text")
                or data.get("message")
                or data.get("output")
                or raw_response
            )
        return raw_response
    except Exception:
        return raw_response


def _enqueue_job(context, request_id, prompt, selected_arn):
    lambda_client.invoke(
        FunctionName=context.invoked_function_arn,
        InvocationType="Event",
        Payload=json.dumps(
            {
                "source": "agentcore-async-worker",
                "requestId": request_id,
                "prompt": prompt,
                "runtimeArn": selected_arn,
            }
        ).encode("utf-8"),
    )


def _handle_submit(event, context):
    payload = _parse_json_body(event)
    if payload is None:
        return _json_response(400, {"error": "Invalid JSON body"})

    prompt = (payload.get("prompt") or "").strip()
    if not prompt:
        return _json_response(400, {"error": "prompt is required"})

    try:
        selected_arn = _resolve_arn(payload)
    except ValueError as exc:
        return _json_response(403, {"error": str(exc)})

    request_id = str(uuid.uuid4())
    now = _now_ms()
    ttl = int(time.time()) + 24 * 60 * 60
    jobs_table.put_item(
        Item={
            "requestId": request_id,
            "status": "QUEUED",
            "createdAt": now,
            "updatedAt": now,
            "runtimeArn": selected_arn,
            "expiresAt": ttl,
        }
    )

    try:
        _enqueue_job(context, request_id, prompt, selected_arn)
    except Exception as exc:
        jobs_table.update_item(
            Key={"requestId": request_id},
            UpdateExpression="SET #s = :s, #u = :u, #e = :e",
            ExpressionAttributeNames={"#s": "status", "#u": "updatedAt", "#e": "error"},
            ExpressionAttributeValues={":s": "FAILED", ":u": _now_ms(), ":e": str(exc)},
        )
        return _json_response(200, {"requestId": request_id, "status": "FAILED", "error": str(exc)})

    return _json_response(200, {"requestId": request_id, "status": "QUEUED"})


def _handle_status(request_id):
    item = jobs_table.get_item(Key={"requestId": request_id}).get("Item")
    if not item:
        return _json_response(404, {"error": "Request not found"})

    body = {
        "requestId": request_id,
        "status": item.get("status", "UNKNOWN"),
        "response": item.get("response"),
        "error": item.get("error"),
    }
    return _json_response(200, {k: v for k, v in body.items() if v is not None})


def _handle_async_worker(event):
    request_id = event.get("requestId")
    prompt = event.get("prompt")
    runtime_arn = event.get("runtimeArn")
    if not request_id or not prompt or not runtime_arn:
        return {"ok": False, "error": "Invalid async worker payload"}

    jobs_table.update_item(
        Key={"requestId": request_id},
        UpdateExpression="SET #s = :s, #u = :u",
        ExpressionAttributeNames={"#s": "status", "#u": "updatedAt"},
        ExpressionAttributeValues={":s": "RUNNING", ":u": _now_ms()},
    )

    try:
        raw_response = _invoke_agentcore(
            prompt,
            runtime_arn,
            timeout_seconds=AGENTCORE_ASYNC_HTTP_TIMEOUT_SECONDS,
        )
        response_text = _extract_response_text(raw_response)
        jobs_table.update_item(
            Key={"requestId": request_id},
            UpdateExpression="SET #s = :s, #u = :u, #r = :r",
            ExpressionAttributeNames={"#s": "status", "#u": "updatedAt", "#r": "response"},
            ExpressionAttributeValues={":s": "COMPLETED", ":u": _now_ms(), ":r": response_text},
        )
    except socket.timeout:
        jobs_table.update_item(
            Key={"requestId": request_id},
            UpdateExpression="SET #s = :s, #u = :u, #e = :e",
            ExpressionAttributeNames={"#s": "status", "#u": "updatedAt", "#e": "error"},
            ExpressionAttributeValues={
                ":s": "FAILED",
                ":u": _now_ms(),
                ":e": (
                    "AgentCore async request timed out "
                    f"({AGENTCORE_ASYNC_HTTP_TIMEOUT_SECONDS}s)"
                ),
            },
        )
    except urllib.error.HTTPError as exc:
        error_body = exc.read().decode("utf-8")
        jobs_table.update_item(
            Key={"requestId": request_id},
            UpdateExpression="SET #s = :s, #u = :u, #e = :e",
            ExpressionAttributeNames={"#s": "status", "#u": "updatedAt", "#e": "error"},
            ExpressionAttributeValues={
                ":s": "FAILED",
                ":u": _now_ms(),
                ":e": f"AgentCore {exc.code}: {error_body}",
            },
        )
    except Exception as exc:
        jobs_table.update_item(
            Key={"requestId": request_id},
            UpdateExpression="SET #s = :s, #u = :u, #e = :e",
            ExpressionAttributeNames={"#s": "status", "#u": "updatedAt", "#e": "error"},
            ExpressionAttributeValues={":s": "FAILED", ":u": _now_ms(), ":e": str(exc)},
        )

    return {"ok": True}


def handler(event, context):
    if event.get("source") == "agentcore-async-worker":
        return _handle_async_worker(event)

    method = _extract_method(event)
    path = _extract_path(event)

    if method == "OPTIONS":
        return {"statusCode": 200, "headers": CORS_HEADERS, "body": ""}

    if not ALLOWED_ARNS:
        return _json_response(500, {"error": "No AGENT_RUNTIME_ARNS configured"})

    if method == "POST" and path == "/api/invocations":
        return _handle_submit(event, context)

    if method == "GET" and path.startswith("/api/invocations/"):
        request_id = path.rsplit("/", 1)[-1]
        if not request_id:
            return _json_response(400, {"error": "Missing request id"})
        return _handle_status(request_id)

    return _json_response(404, {"error": "Not found"})
