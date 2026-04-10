#!/bin/bash
# Run frontend locally and proxy requests to a deployed AgentCore runtime without Cognito.

set -e

echo "Starting remote-runtime no-auth development mode"
echo "================================================"

if [ -z "$1" ]; then
  echo "Usage: $0 <AGENT_RUNTIME_ARN or comma-separated ARNs> [REGION]"
  exit 1
fi

AGENT_RUNTIME_ARNS="$1"
AGENT_RUNTIME_ARN="${AGENT_RUNTIME_ARNS%%,*}"
REGION="${2:-ap-south-1}"

if ! command -v python3 &> /dev/null; then
  echo "Python 3 is required"
  exit 1
fi

if ! command -v node &> /dev/null; then
  echo "Node.js is required"
  exit 1
fi

echo "Preparing Python environment..."
if [ ! -d "agent/venv" ]; then
  pushd agent > /dev/null
  python3 -m venv venv
  popd > /dev/null
fi

pushd agent > /dev/null
source venv/bin/activate
pip install -r requirements.txt

if ! python - << 'PY'
import boto3
try:
    boto3.client('sts').get_caller_identity()
except Exception:
    raise SystemExit(1)
PY
then
  echo "AWS credentials not configured for boto3. Export AWS_ACCESS_KEY_ID/AWS_SECRET_ACCESS_KEY (and optional AWS_SESSION_TOKEN), or run credentials setup in this shell."
  exit 1
fi

popd > /dev/null

echo "Preparing frontend dependencies..."
pushd frontend > /dev/null
if [ ! -d "node_modules" ]; then
  npm install
fi

cat > .env.local << EOF
VITE_LOCAL_DEV=true
VITE_AGENT_RUNTIME_URL=/api
EOF
popd > /dev/null

cleanup() {
  echo "Stopping services..."
  jobs -p | xargs -r kill
  exit 0
}
trap cleanup SIGINT SIGTERM

echo "Starting runtime proxy on http://localhost:8080"
pushd agent > /dev/null
source venv/bin/activate
REMOTE_AGENT_RUNTIME_ARN="$AGENT_RUNTIME_ARN" REMOTE_AGENT_RUNTIME_ARNS="$AGENT_RUNTIME_ARNS" REMOTE_AGENT_REGION="$REGION" python runtime_proxy.py &
PROXY_PID=$!
popd > /dev/null

sleep 2

echo "Starting frontend on http://localhost:5173"
pushd frontend > /dev/null
npm run dev &
FRONTEND_PID=$!
popd > /dev/null

wait $PROXY_PID $FRONTEND_PID
