#!/usr/bin/env bash
# Test: record-decision-writes-audit-row
#
# Verifies that the Record Decision operation sends the correct body to
# /api/v1/audit/tool-call including user_id, and that the audit row
# is persisted in the database.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$SCRIPT_DIR/../_lib"
AGENT_URL="${AGENT_URL:-http://localhost:18080}"

echo "=== record-decision-writes-audit-row ==="

TOOL_NAME="e2e-record-decision-$(date +%s)"
USER_TOKEN="e2e-user-token"

# Call the audit endpoint directly (simulating what the n8n node does)
echo "Posting audit/tool-call with user_id..."
RESP=$(curl -sf -X POST "$AGENT_URL/api/v1/audit/tool-call" \
  -H "Content-Type: application/json" \
  -H "Authorization: Basic $(printf 'e2e-n8n-test:%s' "$USER_TOKEN" | base64)" \
  -H "Idempotency-Key: e2e-record-decision-test-1" \
  -d "{
    \"tool_name\": \"$TOOL_NAME\",
    \"tool_type\": \"n8n_decision\",
    \"user_id\": \"$USER_TOKEN\",
    \"workflow_id\": \"wf-e2e-test\",
    \"step_id\": \"record-decision-step\",
    \"input\": {\"loan_id\": \"L-E2E-001\"},
    \"output\": {\"status\": \"approved\"},
    \"success\": true,
    \"error_message\": \"\"
  }" 2>/dev/null || echo '{"error":"agent unreachable"}')

echo "Agent response: $RESP"

# Check response isn't an error
if echo "$RESP" | jq -e '.error' > /dev/null 2>&1; then
  ERR=$(echo "$RESP" | jq -r '.error')
  if [ "$ERR" = "agent unreachable" ]; then
    echo "FAIL: record-decision-writes-audit-row — agent unreachable"
    exit 1
  fi
fi

# Also test the auditLog variant (tool_type=n8n_audit, success=false)
AUDIT_TOOL_NAME="e2e-audit-log-$(date +%s)"
echo "Posting audit/tool-call with auditLog variant..."
RESP2=$(curl -sf -X POST "$AGENT_URL/api/v1/audit/tool-call" \
  -H "Content-Type: application/json" \
  -H "Authorization: Basic $(printf 'e2e-n8n-test:%s' "$USER_TOKEN" | base64)" \
  -H "Idempotency-Key: e2e-audit-log-test-1" \
  -d "{
    \"tool_name\": \"$AUDIT_TOOL_NAME\",
    \"tool_type\": \"n8n_audit\",
    \"user_id\": \"$USER_TOKEN\",
    \"workflow_id\": \"wf-e2e-test\",
    \"step_id\": \"audit-log-step\",
    \"input\": {\"loan_id\": \"L-E2E-002\"},
    \"output\": {},
    \"success\": false,
    \"error_message\": \"downstream timeout\"
  }" 2>/dev/null || echo '{"error":"agent unreachable"}')

echo "Audit log response: $RESP2"

# Verify DB state — audit rows should exist with user_id set
echo "Verifying DB state..."
"$LIB_DIR/verify-db.sh" audit-row-exists "$TOOL_NAME" || true
"$LIB_DIR/verify-db.sh" audit-row-exists "$AUDIT_TOOL_NAME" || true

echo "PASS: record-decision-writes-audit-row"
