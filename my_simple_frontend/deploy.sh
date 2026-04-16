#!/bin/bash
# Deploy AgentCore Chat — S3 + CloudFront + Lambda (no CDK)
# Run once to create everything. Re-run to update Lambda code + frontend assets.
# Usage: bash deploy.sh

set -e

cd "$(dirname "$0")"

# ── Load config from .env ──────────────────────────────────────────────────────
if [ ! -f .env ]; then
  echo "ERROR: .env file not found. Create one with VITE_AGENT_RUNTIME_ARNS and REGION."
  exit 1
fi

# Parse VITE_AGENT_RUNTIME_ARNS and REGION from .env (ignore comments/blank lines)
AGENT_RUNTIME_ARNS=$(grep -E '^VITE_AGENT_RUNTIME_ARNS=' .env | head -1 | cut -d'=' -f2-)
REGION=$(grep -E '^REGION=' .env | head -1 | cut -d'=' -f2-)

if [ -z "$AGENT_RUNTIME_ARNS" ]; then
  echo "ERROR: VITE_AGENT_RUNTIME_ARNS is not set in .env"
  exit 1
fi

if [ -z "$REGION" ]; then
  echo "ERROR: REGION is not set in .env"
  exit 1
fi
STACK_NAME="agentcore-frontend"
LAMBDA_NAME="${STACK_NAME}-proxy"
ROLE_NAME="${STACK_NAME}-lambda-role"
STATE_FILE=".deploy-state"

cd "$(dirname "$0")"

echo "=== AgentCore Chat Deployment ==="
echo "Region : $REGION"

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
BUCKET_NAME="${STACK_NAME}-${ACCOUNT_ID}"
echo "Account: $ACCOUNT_ID"
echo "Bucket : $BUCKET_NAME"

# ── 1. Build frontend ──────────────────────────────────────────────────────────
echo ""
echo "[1/7] Building frontend..."
VITE_AGENT_RUNTIME_ARNS="$AGENT_RUNTIME_ARNS" npm run build

# ── 2. S3 bucket ───────────────────────────────────────────────────────────────
echo ""
echo "[2/7] S3 bucket: $BUCKET_NAME"
if ! aws s3api head-bucket --bucket "$BUCKET_NAME" 2>/dev/null; then
  if [ "$REGION" = "us-east-1" ]; then
    aws s3api create-bucket --bucket "$BUCKET_NAME" --region "$REGION"
  else
    aws s3api create-bucket --bucket "$BUCKET_NAME" --region "$REGION" \
      --create-bucket-configuration LocationConstraint="$REGION"
  fi
  echo "  Bucket created."
fi
aws s3api put-public-access-block --bucket "$BUCKET_NAME" \
  --public-access-block-configuration \
  BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true

# ── 3. IAM role ────────────────────────────────────────────────────────────────
echo ""
echo "[3/7] IAM role: $ROLE_NAME"
if ! aws iam get-role --role-name "$ROLE_NAME" > /dev/null 2>&1; then
  TRUST='{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"lambda.amazonaws.com"},"Action":"sts:AssumeRole"}]}'
  aws iam create-role --role-name "$ROLE_NAME" \
    --assume-role-policy-document "$TRUST" > /dev/null
  aws iam attach-role-policy --role-name "$ROLE_NAME" \
    --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole
  echo "  Waiting 15s for IAM role propagation..."
  sleep 15
fi
ROLE_ARN=$(aws iam get-role --role-name "$ROLE_NAME" --query Role.Arn --output text)

# Allow Lambda to invoke the AgentCore runtime
# Build resource list — wildcard suffix so sub-resource /runtime-endpoint/DEFAULT is covered
POLICY_RESOURCES=$(python3 -c "
import json, sys
arns = [a.strip() + '*' for a in '''$AGENT_RUNTIME_ARNS'''.split(',') if a.strip()]
print(json.dumps(arns))
")

aws iam put-role-policy --role-name "$ROLE_NAME" \
  --policy-name AgentCoreInvoke \
  --policy-document "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Action\":\"bedrock-agentcore:InvokeAgentRuntime\",\"Resource\":${POLICY_RESOURCES}}]}"

# ── 4. Lambda function ─────────────────────────────────────────────────────────
echo ""
echo "[4/7] Lambda function: $LAMBDA_NAME"
(cd lambda && zip -q ../lambda.zip index.py)

if aws lambda get-function --function-name "$LAMBDA_NAME" --region "$REGION" > /dev/null 2>&1; then
  echo "  Updating existing function..."
  aws lambda update-function-code \
    --function-name "$LAMBDA_NAME" \
    --zip-file fileb://lambda.zip \
    --region "$REGION" > /dev/null
  aws lambda wait function-updated \
    --function-name "$LAMBDA_NAME" --region "$REGION"
  aws lambda update-function-configuration \
    --function-name "$LAMBDA_NAME" \
    --environment "{\"Variables\":{\"AGENT_RUNTIME_ARNS\":\"${AGENT_RUNTIME_ARNS}\"}}" \
    --region "$REGION" > /dev/null
else
  echo "  Creating new function..."
  aws lambda create-function \
    --function-name "$LAMBDA_NAME" \
    --runtime python3.12 \
    --role "$ROLE_ARN" \
    --handler index.handler \
    --zip-file fileb://lambda.zip \
    --timeout 60 \
    --environment "{\"Variables\":{\"AGENT_RUNTIME_ARNS\":\"${AGENT_RUNTIME_ARNS}\"}}" \
    --region "$REGION" > /dev/null
  aws lambda wait function-active \
    --function-name "$LAMBDA_NAME" --region "$REGION"
fi
rm -f lambda.zip

# ── API Gateway HTTP API ───────────────────────────────────────────────────────
API_NAME="${STACK_NAME}-api"
API_ID=$(aws apigatewayv2 get-apis --region "$REGION" \
  --query "Items[?Name=='${API_NAME}'].ApiId" --output text 2>/dev/null)

if [ -z "$API_ID" ]; then
  echo "  Creating API Gateway HTTP API..."
  API_ID=$(aws apigatewayv2 create-api \
    --name "$API_NAME" \
    --protocol-type HTTP \
    --cors-configuration AllowOrigins='*',AllowMethods='*',AllowHeaders='*' \
    --region "$REGION" \
    --query ApiId --output text)

  LAMBDA_ARN=$(aws lambda get-function --function-name "$LAMBDA_NAME" \
    --region "$REGION" --query Configuration.FunctionArn --output text)

  INTEGRATION_ID=$(aws apigatewayv2 create-integration \
    --api-id "$API_ID" \
    --integration-type AWS_PROXY \
    --integration-uri "$LAMBDA_ARN" \
    --payload-format-version 2.0 \
    --region "$REGION" \
    --query IntegrationId --output text)

  aws apigatewayv2 create-route \
    --api-id "$API_ID" \
    --route-key "POST /api/invocations" \
    --target "integrations/${INTEGRATION_ID}" \
    --region "$REGION" > /dev/null

  aws apigatewayv2 create-route \
    --api-id "$API_ID" \
    --route-key "OPTIONS /api/invocations" \
    --target "integrations/${INTEGRATION_ID}" \
    --region "$REGION" > /dev/null

  aws apigatewayv2 create-stage \
    --api-id "$API_ID" \
    --stage-name '$default' \
    --auto-deploy \
    --region "$REGION" > /dev/null

  LAMBDA_ARN_FULL=$(aws lambda get-function --function-name "$LAMBDA_NAME" \
    --region "$REGION" --query Configuration.FunctionArn --output text)

  aws lambda add-permission \
    --function-name "$LAMBDA_NAME" \
    --statement-id apigw-invoke \
    --action lambda:InvokeFunction \
    --principal apigateway.amazonaws.com \
    --source-arn "arn:aws:execute-api:${REGION}:${ACCOUNT_ID}:${API_ID}/*/*/api/invocations" \
    --region "$REGION" > /dev/null 2>&1 || true

  echo "  API Gateway ID: $API_ID"
else
  echo "  API Gateway already exists: $API_ID"
fi

API_HOST="${API_ID}.execute-api.${REGION}.amazonaws.com"
echo "  API host: $API_HOST"

# ── 5–7: Skip CloudFront if already deployed (re-run = update only) ────────────
if [ -f "$STATE_FILE" ]; then
  # shellcheck source=.deploy-state
  source "$STATE_FILE"
  echo ""
  echo "[5-6/7] CloudFront distribution already exists ($DIST_ID) — skipping."
else
  # ── 5. CloudFront OAC ───────────────────────────────────────────────────────
  echo ""
  echo "[5/7] CloudFront Origin Access Control..."
  OAC_ID=$(aws cloudfront list-origin-access-controls \
    --query "OriginAccessControlList.Items[?Name=='${STACK_NAME}-oac'].Id" \
    --output text)
  if [ -z "$OAC_ID" ]; then
    OAC_ID=$(aws cloudfront create-origin-access-control \
      --origin-access-control-config \
      "{\"Name\":\"${STACK_NAME}-oac\",\"Description\":\"\",\"SigningProtocol\":\"sigv4\",\"SigningBehavior\":\"always\",\"OriginAccessControlOriginType\":\"s3\"}" \
      --query 'OriginAccessControl.Id' --output text)
  fi
  echo "  OAC ID: $OAC_ID"

  # ── 6. CloudFront distribution ─────────────────────────────────────────────
  echo ""
  echo "[6/7] Creating CloudFront distribution (takes a few minutes to deploy)..."
  S3_DOMAIN="${BUCKET_NAME}.s3.${REGION}.amazonaws.com"

  DIST_CONFIG=$(cat <<CFEOF
{
  "CallerReference": "${STACK_NAME}-$(date +%s)",
  "Comment": "AgentCore Chat",
  "DefaultRootObject": "index.html",
  "Origins": {
    "Quantity": 2,
    "Items": [
      {
        "Id": "S3",
        "DomainName": "${S3_DOMAIN}",
        "S3OriginConfig": {"OriginAccessIdentity": ""},
        "OriginAccessControlId": "${OAC_ID}"
      },
      {
        "Id": "Lambda",
        "DomainName": "${API_HOST}",
        "CustomOriginConfig": {
          "HTTPPort": 80,
          "HTTPSPort": 443,
          "OriginProtocolPolicy": "https-only",
          "OriginSslProtocols": {"Quantity": 1, "Items": ["TLSv1.2"]}
        }
      }
    ]
  },
  "DefaultCacheBehavior": {
    "TargetOriginId": "S3",
    "ViewerProtocolPolicy": "redirect-to-https",
    "AllowedMethods": {
      "Quantity": 2,
      "Items": ["GET", "HEAD"],
      "CachedMethods": {"Quantity": 2, "Items": ["GET", "HEAD"]}
    },
    "CachePolicyId": "658327ea-f89d-4fab-a63d-7e88639e58f6",
    "Compress": true
  },
  "CacheBehaviors": {
    "Quantity": 1,
    "Items": [
      {
        "PathPattern": "/api/*",
        "TargetOriginId": "Lambda",
        "ViewerProtocolPolicy": "https-only",
        "AllowedMethods": {
          "Quantity": 7,
          "Items": ["GET", "HEAD", "OPTIONS", "PUT", "POST", "PATCH", "DELETE"],
          "CachedMethods": {"Quantity": 2, "Items": ["GET", "HEAD"]}
        },
        "CachePolicyId": "4135ea2d-6df8-44a3-9df3-4b5a84be39ad",
        "OriginRequestPolicyId": "b689b0a8-53d0-40ab-baf2-68738e2966ac",
        "Compress": false
      }
    ]
  },
  "CustomErrorResponses": {
    "Quantity": 2,
    "Items": [
      {"ErrorCode": 403, "ResponseCode": "200", "ResponsePagePath": "/index.html"},
      {"ErrorCode": 404, "ResponseCode": "200", "ResponsePagePath": "/index.html"}
    ]
  },
  "Enabled": true,
  "PriceClass": "PriceClass_100"
}
CFEOF
)

  DIST_RESULT=$(aws cloudfront create-distribution \
    --distribution-config "$DIST_CONFIG")

  DIST_ID=$(echo "$DIST_RESULT" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['Distribution']['Id'])")
  DIST_DOMAIN=$(echo "$DIST_RESULT" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['Distribution']['DomainName'])")

  # Save state so re-runs skip CloudFront creation
  cat > "$STATE_FILE" <<STEOF
DIST_ID=${DIST_ID}
DIST_DOMAIN=${DIST_DOMAIN}
OAC_ID=${OAC_ID}
API_ID=${API_ID}
STEOF

  echo "  Distribution ID: $DIST_ID"
  echo "  Domain: $DIST_DOMAIN"

  # S3 bucket policy — allow CloudFront OAC
  aws s3api put-bucket-policy --bucket "$BUCKET_NAME" --policy "{
    \"Version\": \"2012-10-17\",
    \"Statement\": [{
      \"Sid\": \"AllowCloudFront\",
      \"Effect\": \"Allow\",
      \"Principal\": {\"Service\": \"cloudfront.amazonaws.com\"},
      \"Action\": \"s3:GetObject\",
      \"Resource\": \"arn:aws:s3:::${BUCKET_NAME}/*\",
      \"Condition\": {\"StringEquals\": {\"AWS:SourceArn\": \"arn:aws:cloudfront::${ACCOUNT_ID}:distribution/${DIST_ID}\"}}
    }]
  }"
fi

# ── 7. Upload frontend to S3 ───────────────────────────────────────────────────
echo ""
echo "[7/7] Uploading frontend to S3..."
aws s3 sync dist/ "s3://${BUCKET_NAME}/" --delete

# Invalidate CloudFront cache if distribution already existed
if [ -n "$DIST_ID" ]; then
  aws cloudfront create-invalidation \
    --distribution-id "$DIST_ID" --paths "/*" > /dev/null 2>&1 || true
fi

echo ""
echo "========================================="
echo " Deployment complete!"
echo " URL: https://${DIST_DOMAIN}"
echo " (CloudFront takes ~5 minutes on first deploy)"
echo "========================================="
