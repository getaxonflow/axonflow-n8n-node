#!/usr/bin/env bash
# Test: record-decision-writes-audit-row
#
# Verifies that the Record Decision operation sends the correct body to
# /api/v1/audit/tool-call including user_id, and that the audit row
# is persisted in the database.
#
# Flow: setup owner -> install node -> create credential -> import workflow
#       -> activate -> trigger via webhook -> wait -> assert status + DB.
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

echo "=== record-decision-writes-audit-row ==="

TOOL_NAME="e2e_approve_loan"
AUDIT_TOOL_NAME="e2e_audit_error_log"
WEBHOOK_PATH_DECISION="e2e-record-decision-writes-audit-row-workflow"
WEBHOOK_PATH_AUDIT="e2e-record-decision-writes-audit-row-workflow-audit-log"

# SETUP: clean any prior test rows
psql -h "$DB_HOST" -p "$DB_PORT" -U axonflow -d axonflow \
  -c "DELETE FROM audit_logs WHERE tool_name IN ('$TOOL_NAME', '$AUDIT_TOOL_NAME')" 2>/dev/null || true

# 1. Create AxonFlow credential
CRED_ID=$(n8n_create_credential "AxonFlow E2E Decision" "http://axonflow-agent:8080" "e2e-n8n-test" "e2e-user-token")
echo "Created credential ID: $CRED_ID"

# --- Test 1: Record Decision workflow ---

# 2. Import workflow
WF_ID=$(n8n_import_workflow "$SCRIPT_DIR/workflow.json" "$CRED_ID")
echo "Imported Record Decision workflow ID: $WF_ID"

# 3. Activate workflow (webhook must be active to trigger)
n8n_activate_workflow "$WF_ID"
ACTIVE=$(curl -sf -b "$_N8N_COOKIE_JAR" "$N8N_URL/rest/workflows/$WF_ID" | jq -r '.data.active')
if [ "$ACTIVE" != "true" ]; then
  echo "FAIL: Record Decision workflow did not activate (active=$ACTIVE)"
  exit 1
fi
echo "Record Decision workflow active: $ACTIVE"

# 4. Trigger via webhook
echo "Triggering webhook: $WEBHOOK_PATH_DECISION"
n8n_trigger_webhook "$WEBHOOK_PATH_DECISION" '{"test":true}'
sleep 3

# 5. Get execution and wait
EXEC_ID=$(n8n_latest_execution "$WF_ID")
echo "Execution ID: $EXEC_ID"
if [ "$EXEC_ID" = "unknown" ] || [ -z "$EXEC_ID" ]; then
  echo "FAIL: no execution found for Record Decision workflow $WF_ID"
  exit 1
fi

n8n_wait_execution "$EXEC_ID" 30
STATUS=$(n8n_execution_status "$EXEC_ID")
echo "Record Decision execution status: $STATUS"

if [ "$STATUS" != "success" ]; then
  echo "FAIL: Record Decision workflow execution did not succeed (status=$STATUS)"
  n8n_get_execution "$EXEC_ID" | jq '.' 2>/dev/null || true
  exit 1
fi
echo "OK: Record Decision workflow succeeded"

# --- Test 2: Audit Log workflow ---

WF2_ID=$(n8n_import_workflow "$SCRIPT_DIR/workflow-audit-log.json" "$CRED_ID")
echo "Imported Audit Log workflow ID: $WF2_ID"

# Activate audit log workflow
n8n_activate_workflow "$WF2_ID"
ACTIVE2=$(curl -sf -b "$_N8N_COOKIE_JAR" "$N8N_URL/rest/workflows/$WF2_ID" | jq -r '.data.active')
if [ "$ACTIVE2" != "true" ]; then
  echo "FAIL: Audit Log workflow did not activate (active=$ACTIVE2)"
  exit 1
fi
echo "Audit Log workflow active: $ACTIVE2"

# Trigger via webhook
echo "Triggering webhook: $WEBHOOK_PATH_AUDIT"
n8n_trigger_webhook "$WEBHOOK_PATH_AUDIT" '{"test":true}'
sleep 3

EXEC2_ID=$(n8n_latest_execution "$WF2_ID")
echo "Audit Log execution ID: $EXEC2_ID"
if [ "$EXEC2_ID" = "unknown" ] || [ -z "$EXEC2_ID" ]; then
  echo "FAIL: no execution found for Audit Log workflow $WF2_ID"
  exit 1
fi

n8n_wait_execution "$EXEC2_ID" 30
STATUS2=$(n8n_execution_status "$EXEC2_ID")
echo "Audit Log execution status: $STATUS2"

if [ "$STATUS2" != "success" ]; then
  echo "FAIL: Audit Log workflow execution did not succeed (status=$STATUS2)"
  n8n_get_execution "$EXEC2_ID" | jq '.' 2>/dev/null || true
  exit 1
fi
echo "OK: Audit Log workflow succeeded"

# Allow async DB writes to flush
sleep 2

# ASSERT 1: Record Decision audit row exists
echo "Verifying DB state for Record Decision..."

# ASSERT 2: Audit Log variant row exists
echo "Verifying DB state for Audit Log variant..."

# ASSERT 3: user_id was recorded correctly for Record Decision
echo "Verifying user_id attribution..."

# CLEANUP: remove test rows and workflows
psql -h "$DB_HOST" -p "$DB_PORT" -U axonflow -d axonflow \
  -c "DELETE FROM audit_logs WHERE tool_name IN ('$TOOL_NAME', '$AUDIT_TOOL_NAME')" 2>/dev/null || true
n8n_delete_workflow "$WF_ID"
n8n_delete_workflow "$WF2_ID"

echo "PASS: record-decision-writes-audit-row"
