#!/usr/bin/env bash
# Test: record-decision-writes-audit-row
#
# Verifies that the Record Decision operation sends the correct body to
# /api/v1/audit/tool-call including user_id, and that the audit row
# is persisted in the database.
#
# ASSERT: queries audit_logs table for the tool_name, fails if absent.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$SCRIPT_DIR/../_lib"
AGENT_URL="${AGENT_URL:-http://localhost:18080}"

export PGPASSWORD="${DB_PASSWORD:-localdev123}"
DB_HOST="${DB_HOST:-localhost}"
DB_PORT="${DB_PORT:-15432}"

echo "=== record-decision-writes-audit-row ==="

TOOL_NAME="e2e-record-decision-$(date +%s)"
AUDIT_TOOL_NAME="e2e-audit-log-$(date +%s)"
USER_TOKEN="e2e-user-token"
AUTH="Basic $(printf 'e2e-n8n-test:%s' "$USER_TOKEN" | base64)"

# SETUP: clean any prior test rows
psql -h "$DB_HOST" -p "$DB_PORT" -U axonflow -d axonflow \
  -c "DELETE FROM audit_logs WHERE tool_name LIKE 'e2e-record-decision-%' OR tool_name LIKE 'e2e-audit-log-%'" 2>/dev/null || true

# RUN 1: Post audit/tool-call with user_id (record decision)
echo "Posting audit/tool-call with user_id..."
RESP_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$AGENT_URL/api/v1/audit/tool-call" \
  -H "Content-Type: application/json" \
  -H "Authorization: $AUTH" \
  -H "Idempotency-Key: e2e-record-decision-test-$(date +%s)" \
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
  }")

echo "Record decision HTTP status: $RESP_CODE"
if [ "$RESP_CODE" = "000" ]; then
  echo "FAIL: agent unreachable for record decision call"
  exit 1
fi

# RUN 2: Post the auditLog variant (tool_type=n8n_audit, success=false)
echo "Posting audit/tool-call with auditLog variant..."
RESP2_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$AGENT_URL/api/v1/audit/tool-call" \
  -H "Content-Type: application/json" \
  -H "Authorization: $AUTH" \
  -H "Idempotency-Key: e2e-audit-log-test-$(date +%s)" \
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
  }")

echo "Audit log HTTP status: $RESP2_CODE"

# Allow async DB writes to flush
sleep 2

# ASSERT 1: record decision audit row exists
echo "Verifying DB state for record decision..."
"$LIB_DIR/verify-db.sh" audit-row-exists "$TOOL_NAME"

# ASSERT 2: audit log variant row exists
echo "Verifying DB state for audit log variant..."
"$LIB_DIR/verify-db.sh" audit-row-exists "$AUDIT_TOOL_NAME"

# ASSERT 3: user_id was recorded correctly
echo "Verifying user_id attribution..."
"$LIB_DIR/verify-db.sh" audit-row-has-user-id "$TOOL_NAME" "$USER_TOKEN"

# CLEANUP: remove test rows
psql -h "$DB_HOST" -p "$DB_PORT" -U axonflow -d axonflow \
  -c "DELETE FROM audit_logs WHERE tool_name LIKE 'e2e-record-decision-%' OR tool_name LIKE 'e2e-audit-log-%'" 2>/dev/null || true

echo "PASS: record-decision-writes-audit-row"
