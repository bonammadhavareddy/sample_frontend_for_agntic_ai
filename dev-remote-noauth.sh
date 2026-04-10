#!/bin/bash
# Run frontend locally and proxy requests to a deployed AgentCore runtime without Cognito.

set -e

echo "Starting remote-runtime no-auth development mode"
echo "================================================"

if [ -z "$1" ]; then
  echo "Usage: $0 <AGENT_RUNTIME_ARN> [REGION]"
  exit 1
fi

AGENT_RUNTIME_ARN="$1"
REGION="${2:-ap-south-1}"

if ! command -v python3 &> /dev/null; then
  echo "Python 3 is required"
  exit 1
fi

if ! command -v node &> /dev/null; then
  echo "Node.js is required"
  exit 1
fi

if ! command -v aws &> /dev/null; then
  echo "AWS CLI is required"
  exit 1
fi

if ! aws sts get-caller-identity > /dev/null 2>&1; then
  echo "AWS credentials not configured. Please run aws configure or aws sso login first."
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
REMOTE_AGENT_RUNTIME_ARN="$AGENT_RUNTIME_ARN" REMOTE_AGENT_REGION="$REGION" python runtime_proxy.py &
PROXY_PID=$!
popd > /dev/null

sleep 2

echo "Starting frontend on http://localhost:5173"
pushd frontend > /dev/null
npm run dev &
FRONTEND_PID=$!
popd > /dev/null

wait $PROXY_PID $FRONTEND_PID
