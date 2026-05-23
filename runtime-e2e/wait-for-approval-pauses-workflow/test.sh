#!/usr/bin/env bash
# Test: wait-for-approval-pauses-workflow
#
# Verifies that the Wait for Approval operation creates a HITL queue row
# with the correct fields including user_id, and that the polling sidecar
# can approve it and the DB reflects the status change.
#
# ASSERT: queries hitl_approval_queue for row existence, field values,
#         and post-approval status.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$SCRIPT_DIR/../_lib"
AGENT_URL="${AGENT_URL:-http://localhost:18080}"

export PGPASSWORD="${DB_PASSWORD:-localdev123}"
DB_HOST="${DB_HOST:-localhost}"
DB_PORT="${DB_PORT:-15432}"

echo "=== wait-for-approval-pauses-workflow ==="

USER_TOKEN="e2e-user-token"
AUTH="Basic $(printf 'e2e-n8n-test:%s' "$USER_TOKEN" | base64)"

# SETUP: clean any prior HITL test rows
psql -h "$DB_HOST" -p "$DB_PORT" -U axonflow -d axonflow \
  -c "DELETE FROM hitl_approval_queue WHERE client_id = 'e2e-n8n-test'" 2>/dev/null || true

# RUN 1: Create a HITL queue entry with user_id
echo "Creating HITL queue entry with user_id..."
RESP=$(curl -sf -X POST "$AGENT_URL/api/v1/hitl/queue" \
  -H "Content-Type: application/json" \
  -H "Authorization: $AUTH" \
  -H "Idempotency-Key: e2e-hitl-test-$(date +%s)-1" \
  -d "{
    \"client_id\": \"e2e-n8n-test\",
    \"user_id\": \"$USER_TOKEN\",
    \"original_query\": \"Approve loan L-E2E-001 for 5000\",
    \"request_type\": \"workflow_step\",
    \"request_context\": {\"loan_id\": \"L-E2E-001\", \"amount\": 5000},
    \"triggered_policy_id\": \"high-value-loan\",
    \"triggered_policy_name\": \"High Value Loan Approval\",
    \"trigger_reason\": \"Amount exceeds threshold\",
    \"severity\": \"high\",
    \"expires_in_seconds\": 3600
  }")

echo "HITL create response: $RESP"

# Extract approval ID from the response envelope
APPROVAL_ID=$(echo "$RESP" | jq -r '.data.id // .data.request_id // .id // empty' 2>/dev/null || echo "")

if [ -z "$APPROVAL_ID" ]; then
  echo "FAIL: HITL queue endpoint returned no approval ID"
  exit 1
fi

echo "Approval ID: $APPROVAL_ID"

# Allow async DB writes to flush
sleep 2

# ASSERT 1: HITL row exists in the DB
echo "Verifying HITL row in database..."
"$LIB_DIR/verify-db.sh" hitl-row "$APPROVAL_ID"

# ASSERT 2: severity field matches
"$LIB_DIR/verify-db.sh" hitl-field "$APPROVAL_ID" severity "high"

# ASSERT 3: user_id field matches
"$LIB_DIR/verify-db.sh" hitl-field "$APPROVAL_ID" user_id "$USER_TOKEN"

# ASSERT 4: status is pending before approval
"$LIB_DIR/verify-db.sh" hitl-field "$APPROVAL_ID" status "pending"

# RUN 2: Approve the request using the polling sidecar
echo ""
echo "Approving the HITL request via sidecar..."
USER_TOKEN="$USER_TOKEN" bash "$SCRIPT_DIR/polling-sidecar.sh" "$APPROVAL_ID" 15

# Allow async DB writes to flush
sleep 2

# ASSERT 5: status changed to approved
echo "Verifying post-approval status..."
"$LIB_DIR/verify-db.sh" hitl-field "$APPROVAL_ID" status "approved"

# CLEANUP: remove test HITL rows
psql -h "$DB_HOST" -p "$DB_PORT" -U axonflow -d axonflow \
  -c "DELETE FROM hitl_approval_queue WHERE client_id = 'e2e-n8n-test'" 2>/dev/null || true

echo "PASS: wait-for-approval-pauses-workflow"
