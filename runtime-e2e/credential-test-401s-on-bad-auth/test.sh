#!/usr/bin/env bash
# Test: credential-test-401s-on-bad-auth
#
# Verifies the credential test endpoint behavior: valid creds should
# return 200, invalid creds should return non-200. Also verifies the
# response body contains an error indicator on bad auth.
#
# ASSERT: HTTP status codes + response body content for good/bad/missing auth.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AGENT_URL="${AGENT_URL:-http://localhost:18080}"

echo "=== credential-test-401s-on-bad-auth ==="

# Test 1: Valid credentials — must return 200
echo "Test 1: Valid credentials..."
VALID_RESP=$(mktemp)
VALID_CODE=$(curl -s -o "$VALID_RESP" -w "%{http_code}" -X POST \
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
if [ "$VALID_CODE" != "200" ]; then
  echo "FAIL: Valid credentials rejected with HTTP $VALID_CODE"
  echo "Response body: $(cat "$VALID_RESP")"
  rm -f "$VALID_RESP"
  exit 1
fi
echo "OK: Valid credentials accepted with HTTP 200"
rm -f "$VALID_RESP"

# Test 2: Invalid credentials — must NOT return 200
echo ""
echo "Test 2: Invalid credentials..."
BAD_RESP=$(mktemp)
BAD_CODE=$(curl -s -o "$BAD_RESP" -w "%{http_code}" -X POST \
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

echo "Invalid creds HTTP status: $BAD_CODE"
BAD_BODY=$(cat "$BAD_RESP")
rm -f "$BAD_RESP"

if [ "$BAD_CODE" = "200" ]; then
  echo "FAIL: Invalid credentials returned HTTP 200 (silent green = bug)"
  echo "Response body: $BAD_BODY"
  exit 1
fi
if [ "$BAD_CODE" = "401" ] || [ "$BAD_CODE" = "403" ]; then
  echo "OK: Invalid credentials correctly rejected with HTTP $BAD_CODE"
else
  echo "OK: Invalid credentials returned HTTP $BAD_CODE (non-200)"
fi

# ASSERT: response body contains an error indicator
if echo "$BAD_BODY" | grep -qi "error\|unauthorized\|forbidden\|denied" 2>/dev/null; then
  echo "OK: Response body contains error indicator"
else
  echo "FAIL: Response body for bad auth does not contain error indicator"
  echo "Body: $BAD_BODY"
  exit 1
fi

# Test 3: No auth header at all — must NOT return 200
echo ""
echo "Test 3: No auth header..."
NOAUTH_RESP=$(mktemp)
NOAUTH_CODE=$(curl -s -o "$NOAUTH_RESP" -w "%{http_code}" -X POST \
  "$AGENT_URL/api/v1/mcp/check-input" \
  -H "Content-Type: application/json" \
  -d '{
    "client_id": "no-auth",
    "connector_type": "credential_test",
    "statement": "n8n_credential_test_noop"
  }' 2>/dev/null || echo "000")

echo "No auth HTTP status: $NOAUTH_CODE"
NOAUTH_BODY=$(cat "$NOAUTH_RESP")
rm -f "$NOAUTH_RESP"

if [ "$NOAUTH_CODE" = "200" ]; then
  echo "FAIL: No-auth request returned HTTP 200 (silent green = bug)"
  echo "Response body: $NOAUTH_BODY"
  exit 1
fi
echo "OK: No-auth request returned HTTP $NOAUTH_CODE (non-200)"

echo ""
echo "PASS: credential-test-401s-on-bad-auth"
