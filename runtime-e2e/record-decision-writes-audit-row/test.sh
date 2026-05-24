#!/usr/bin/env bash
# Test: record-decision-writes-audit-row
#
# Verifies that the Record Decision operation sends the correct body to
# /api/v1/audit/tool-call including user_id, and that the audit row
# is persisted in the database.
#
# Flow: import workflow -> execute via n8n REST API -> wait for completion ->
#       assert execution succeeded -> assert audit rows exist in DB.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$SCRIPT_DIR/../_lib"
N8N_URL="${N8N_URL:-http://localhost:15678}"

export PGPASSWORD="${DB_PASSWORD:-localdev123}"
DB_HOST="${DB_HOST:-localhost}"
DB_PORT="${DB_PORT:-15432}"

source "$LIB_DIR/n8n-api.sh"
n8n_setup_owner

echo "=== record-decision-writes-audit-row ==="

TOOL_NAME="e2e_approve_loan"
AUDIT_TOOL_NAME="e2e_audit_error_log"

# SETUP: clean any prior test rows
psql -h "$DB_HOST" -p "$DB_PORT" -U axonflow -d axonflow \
  -c "DELETE FROM audit_logs WHERE tool_name IN ('$TOOL_NAME', '$AUDIT_TOOL_NAME')" 2>/dev/null || true

# 1. Create AxonFlow credential
CRED_ID=$(n8n_create_credential "AxonFlow E2E Decision" "http://axonflow-agent:8080" "e2e-n8n-test" "e2e-user-token")
echo "Created credential ID: $CRED_ID"

# --- Test 1: Record Decision workflow ---

# 2. Import and execute the Record Decision workflow
WF_ID=$(n8n_import_workflow "$SCRIPT_DIR/workflow.json" "$CRED_ID")
echo "Imported Record Decision workflow ID: $WF_ID"

echo "Executing Record Decision workflow via n8n REST API..."
EXEC_ID=$(n8n_execute_workflow "$WF_ID")
echo "Execution ID: $EXEC_ID"

if [ "$EXEC_ID" = "unknown" ] || [ -z "$EXEC_ID" ]; then
  echo "FAIL: n8n did not return an execution ID for Record Decision"
  exit 1
fi

echo "Waiting for Record Decision execution to complete..."
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

echo "Executing Audit Log workflow via n8n REST API..."
EXEC2_ID=$(n8n_execute_workflow "$WF2_ID")
echo "Execution ID: $EXEC2_ID"

if [ "$EXEC2_ID" = "unknown" ] || [ -z "$EXEC2_ID" ]; then
  echo "FAIL: n8n did not return an execution ID for Audit Log"
  exit 1
fi

echo "Waiting for Audit Log execution to complete..."
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
"$LIB_DIR/verify-db.sh" audit-row-exists "$TOOL_NAME"

# ASSERT 2: Audit Log variant row exists
echo "Verifying DB state for Audit Log variant..."
"$LIB_DIR/verify-db.sh" audit-row-exists "$AUDIT_TOOL_NAME"

# ASSERT 3: user_id was recorded correctly for Record Decision
echo "Verifying user_id attribution..."
"$LIB_DIR/verify-db.sh" audit-row-has-user-id "$TOOL_NAME" "e2e-user-token"

# CLEANUP: remove test rows and workflows
psql -h "$DB_HOST" -p "$DB_PORT" -U axonflow -d axonflow \
  -c "DELETE FROM audit_logs WHERE tool_name IN ('$TOOL_NAME', '$AUDIT_TOOL_NAME')" 2>/dev/null || true
n8n_delete_workflow "$WF_ID"
n8n_delete_workflow "$WF2_ID"

echo "PASS: record-decision-writes-audit-row"
