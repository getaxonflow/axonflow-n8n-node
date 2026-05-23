#!/usr/bin/env bash
# Test: idempotency-retry-does-not-double-record
#
# Verifies that sending the same Idempotency-Key twice does NOT create
# a duplicate audit row. This validates that n8n's "Retry on Fail"
# feature combined with the node's Idempotency-Key header is safe.
#
# ASSERT: queries audit_tool_calls for exactly 1 row, and idempotency_keys
#         for 1 row matching the key.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$SCRIPT_DIR/../_lib"
AGENT_URL="${AGENT_URL:-http://localhost:18080}"

export PGPASSWORD="${DB_PASSWORD:-localdev123}"
DB_HOST="${DB_HOST:-localhost}"
DB_PORT="${DB_PORT:-15432}"

echo "=== idempotency-retry-does-not-double-record ==="

USER_TOKEN="e2e-user-token"
IDEM_KEY="e2e-idempotency-test-$(date +%s)"
TOOL_NAME="e2e-idem-check-$(date +%s)"
AUTH="Basic $(printf 'e2e-n8n-test:%s' "$USER_TOKEN" | base64)"

# SETUP: clean any prior test rows
psql -h "$DB_HOST" -p "$DB_PORT" -U axonflow -d axonflow \
  -c "DELETE FROM audit_tool_calls WHERE tool_name LIKE 'e2e-idem-check-%'" 2>/dev/null || true
psql -h "$DB_HOST" -p "$DB_PORT" -U axonflow -d axonflow \
  -c "DELETE FROM idempotency_keys WHERE key LIKE 'e2e-idempotency-test-%'" 2>/dev/null || true

# RUN 1: First call with the idempotency key
echo "First call with Idempotency-Key: $IDEM_KEY"
RESP1_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$AGENT_URL/api/v1/audit/tool-call" \
  -H "Content-Type: application/json" \
  -H "Authorization: $AUTH" \
  -H "Idempotency-Key: $IDEM_KEY" \
  -d "{
    \"tool_name\": \"$TOOL_NAME\",
    \"tool_type\": \"n8n_decision\",
    \"user_id\": \"$USER_TOKEN\",
    \"workflow_id\": \"wf-idem-test\",
    \"step_id\": \"idem-step\",
    \"input\": {\"test\": true},
    \"output\": {\"result\": \"ok\"},
    \"success\": true,
    \"error_message\": \"\"
  }")
echo "First call HTTP status: $RESP1_CODE"
if [ "$RESP1_CODE" = "000" ]; then
  echo "FAIL: agent unreachable for first idempotency call"
  exit 1
fi

# RUN 2: Same call again with the SAME idempotency key (simulating a retry)
echo "Second call (retry) with same Idempotency-Key: $IDEM_KEY"
RESP2_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$AGENT_URL/api/v1/audit/tool-call" \
  -H "Content-Type: application/json" \
  -H "Authorization: $AUTH" \
  -H "Idempotency-Key: $IDEM_KEY" \
  -d "{
    \"tool_name\": \"$TOOL_NAME\",
    \"tool_type\": \"n8n_decision\",
    \"user_id\": \"$USER_TOKEN\",
    \"workflow_id\": \"wf-idem-test\",
    \"step_id\": \"idem-step\",
    \"input\": {\"test\": true},
    \"output\": {\"result\": \"ok\"},
    \"success\": true,
    \"error_message\": \"\"
  }")
echo "Second call HTTP status: $RESP2_CODE"

# Allow async DB writes to flush
sleep 2

# ASSERT 1: exactly 1 audit row (not 2) for this tool_name
echo "Verifying idempotency — should have exactly 1 audit row..."
"$LIB_DIR/verify-db.sh" audit-row-count "$TOOL_NAME" 1

# ASSERT 2: exactly 1 idempotency key row
echo "Verifying idempotency key row..."
"$LIB_DIR/verify-db.sh" idempotency-count "$IDEM_KEY" 1

# CLEANUP: remove test rows
psql -h "$DB_HOST" -p "$DB_PORT" -U axonflow -d axonflow \
  -c "DELETE FROM audit_tool_calls WHERE tool_name LIKE 'e2e-idem-check-%'" 2>/dev/null || true
psql -h "$DB_HOST" -p "$DB_PORT" -U axonflow -d axonflow \
  -c "DELETE FROM idempotency_keys WHERE key LIKE 'e2e-idempotency-test-%'" 2>/dev/null || true

echo "PASS: idempotency-retry-does-not-double-record"
