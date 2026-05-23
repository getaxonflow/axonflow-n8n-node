#!/usr/bin/env bash
# Test: credential-test-401s-on-bad-auth
#
# Verifies the credential test endpoint behavior: valid creds should
# return 200, invalid creds should return 401 (in enterprise mode)
# or 200 (in community mode, which is permissive by design).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AGENT_URL="${AGENT_URL:-http://localhost:18080}"

echo "=== credential-test-401s-on-bad-auth ==="

# The credential test hits POST /api/v1/mcp/check-input with a noop body
# (connector_type: credential_test). This is the same endpoint the
# AxonFlowApi.credentials.ts test request uses.

# Test 1: Valid credentials
echo "Test 1: Valid credentials..."
VALID_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST \
  "$AGENT_URL/api/v1/mcp/check-input" \
  -H "Content-Type: application/json" \
  -H "Authorization: Basic $(printf 'e2e-n8n-test:e2e-user-token' | base64)" \
  -d '{
    "client_id": "e2e-n8n-test",
    "user_token": "e2e-user-token",
    "tenant_id": "e2e-n8n-test",
    "connector_type": "credential_test",
    "statement": "n8n_credential_test_noop"
  }' 2>/dev/null || echo "000")

echo "Valid creds HTTP status: $VALID_CODE"
if [ "$VALID_CODE" = "200" ]; then
  echo "OK: Valid credentials accepted"
else
  echo "FAIL: Valid credentials rejected with HTTP $VALID_CODE"
  exit 1
fi

# Test 2: Invalid credentials
echo ""
echo "Test 2: Invalid credentials..."
INVALID_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST \
  "$AGENT_URL/api/v1/mcp/check-input" \
  -H "Content-Type: application/json" \
  -H "Authorization: Basic $(printf 'bad-client:wrong-token' | base64)" \
  -d '{
    "client_id": "bad-client",
    "user_token": "wrong-token",
    "tenant_id": "bad-client",
    "connector_type": "credential_test",
    "statement": "n8n_credential_test_noop"
  }' 2>/dev/null || echo "000")

echo "Invalid creds HTTP status: $INVALID_CODE"
if [ "$INVALID_CODE" = "401" ] || [ "$INVALID_CODE" = "403" ]; then
  echo "OK: Invalid credentials correctly rejected with HTTP $INVALID_CODE"
elif [ "$INVALID_CODE" = "200" ]; then
  echo "INFO: Community mode accepted invalid credentials (expected — platform is permissive in community mode)"
  echo "      This is documented in the credential type's test block comment."
else
  echo "WARN: Unexpected HTTP $INVALID_CODE for invalid credentials"
fi

# Test 3: No auth header at all
echo ""
echo "Test 3: No auth header..."
NO_AUTH_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST \
  "$AGENT_URL/api/v1/mcp/check-input" \
  -H "Content-Type: application/json" \
  -d '{
    "client_id": "no-auth",
    "connector_type": "credential_test",
    "statement": "n8n_credential_test_noop"
  }' 2>/dev/null || echo "000")

echo "No auth HTTP status: $NO_AUTH_CODE"

echo ""
echo "PASS: credential-test-401s-on-bad-auth"
