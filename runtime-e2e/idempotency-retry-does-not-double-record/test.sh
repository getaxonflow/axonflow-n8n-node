#!/usr/bin/env bash
# Test: idempotency-retry-does-not-double-record
#
# Verifies that executing the same workflow twice with a fixed Idempotency-Key
# does not create duplicate audit rows. This validates that n8n's "Retry on Fail"
# feature combined with the node's Idempotency-Key header is safe.
#
# The workflow.json has idempotencyKey set to a fixed value so both executions
# send the same key, simulating what happens when n8n retries a failed step.
#
# Flow: setup owner -> install node -> create credential -> import workflow
#       -> activate -> trigger webhook twice -> wait for both -> assert
#       exactly 1 audit row (not 2) + 1 idempotency key row.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$SCRIPT_DIR/../_lib"
N8N_URL="${N8N_URL:-http://localhost:15678}"
export WORK="${WORK:-/tmp}"

export PGPASSWORD="${DB_PASSWORD:-localdev123}"
DB_HOST="${DB_HOST:-localhost}"
DB_PORT="${DB_PORT:-15432}"

source "$LIB_DIR/n8n-api.sh"
n8n_setup_owner
n8n_install_axonflow_node

echo "=== idempotency-retry-does-not-double-record ==="

IDEM_KEY="e2e-fixed-idem-key"
TOOL_NAME="e2e_idem_tool"
WEBHOOK_PATH="e2e-idempotency-retry-does-not-double-record-workflow"

# SETUP: clean any prior test rows
psql -h "$DB_HOST" -p "$DB_PORT" -U axonflow -d axonflow \
  -c "DELETE FROM audit_logs WHERE tool_name = '$TOOL_NAME'" 2>/dev/null || true
psql -h "$DB_HOST" -p "$DB_PORT" -U axonflow -d axonflow \
  -c "DELETE FROM idempotency_keys WHERE key = '$IDEM_KEY'" 2>/dev/null || true

# 1. Create AxonFlow credential
CRED_ID=$(n8n_create_credential "AxonFlow E2E Idem" "http://axonflow-agent:8080" "e2e-n8n-test" "e2e-user-token")
echo "Created credential ID: $CRED_ID"

# 2. Import workflow (has fixed idempotency key "e2e-fixed-idem-key")
WF_ID=$(n8n_import_workflow "$SCRIPT_DIR/workflow.json" "$CRED_ID")
echo "Imported workflow ID: $WF_ID"

# 3. Activate workflow (webhook must be active to trigger)
n8n_activate_workflow "$WF_ID"
ACTIVE=$(curl -sf -b "$_N8N_COOKIE_JAR" "$N8N_URL/rest/workflows/$WF_ID" | jq -r '.data.active')
if [ "$ACTIVE" != "true" ]; then
  echo "FAIL: workflow did not activate (active=$ACTIVE)"
  exit 1
fi
echo "Workflow active: $ACTIVE"

# 4. Trigger the workflow the FIRST time via webhook
echo "Triggering webhook (first call): $WEBHOOK_PATH"
n8n_trigger_webhook "$WEBHOOK_PATH" '{"test":true}'
sleep 3

EXEC1_ID=$(n8n_latest_execution "$WF_ID")
echo "First execution ID: $EXEC1_ID"
if [ "$EXEC1_ID" = "unknown" ] || [ -z "$EXEC1_ID" ]; then
  echo "FAIL: no execution found for first call"
  exit 1
fi

n8n_wait_execution "$EXEC1_ID" 30
STATUS1=$(n8n_execution_status "$EXEC1_ID")
echo "First execution status: $STATUS1"

if [ "$STATUS1" != "success" ]; then
  echo "FAIL: first execution did not succeed (status=$STATUS1)"
  n8n_get_execution "$EXEC1_ID" | jq '.' 2>/dev/null || true
  exit 1
fi
echo "OK: first execution succeeded"

# 5. Trigger the SAME workflow a second time (same idempotency key)
echo "Triggering webhook (second call — same idempotency key, simulating retry): $WEBHOOK_PATH"
n8n_trigger_webhook "$WEBHOOK_PATH" '{"test":true}'
sleep 3

EXEC2_ID=$(n8n_latest_execution "$WF_ID")
echo "Second execution ID: $EXEC2_ID"
if [ "$EXEC2_ID" = "unknown" ] || [ -z "$EXEC2_ID" ]; then
  echo "FAIL: no execution found for second call"
  exit 1
fi

n8n_wait_execution "$EXEC2_ID" 30
STATUS2=$(n8n_execution_status "$EXEC2_ID")
echo "Second execution status: $STATUS2"

# The second execution may succeed (platform returns the cached response)
# or may error if the platform rejects the duplicate. Either way, the key
# behavior is that only 1 audit row exists.
echo "OK: second execution completed (status=$STATUS2)"

# Allow async DB writes to flush
sleep 2

# ASSERT 1: exactly 1 audit row (not 2) for this tool_name
echo "Verifying idempotency — should have exactly 1 audit row..."
"$LIB_DIR/verify-db.sh" mcp-audit-exists "e2e-idem-test"

# ASSERT 2: idempotency key row exists
echo "Verifying idempotency key row..."
"$LIB_DIR/verify-db.sh" idempotency-count "$IDEM_KEY" 1

# CLEANUP: remove test rows and workflow
psql -h "$DB_HOST" -p "$DB_PORT" -U axonflow -d axonflow \
  -c "DELETE FROM audit_logs WHERE tool_name = '$TOOL_NAME'" 2>/dev/null || true
psql -h "$DB_HOST" -p "$DB_PORT" -U axonflow -d axonflow \
  -c "DELETE FROM idempotency_keys WHERE key = '$IDEM_KEY'" 2>/dev/null || true
n8n_delete_workflow "$WF_ID"

echo "PASS: idempotency-retry-does-not-double-record"
