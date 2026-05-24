#!/usr/bin/env bash
# Test: check-policy-operation-hits-axonflow
#
# Verifies that an n8n workflow using the Check Policy operation successfully
# calls the AxonFlow agent's /api/v1/mcp/check-input endpoint and that the
# request is recorded in the mcp_query_audits table.
#
# Flow: import workflow -> execute via n8n REST API -> wait for completion ->
#       assert execution succeeded -> assert DB row exists.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$SCRIPT_DIR/../_lib"
N8N_URL="${N8N_URL:-http://localhost:15678}"

export PGPASSWORD="${DB_PASSWORD:-localdev123}"
DB_HOST="${DB_HOST:-localhost}"
DB_PORT="${DB_PORT:-15432}"

source "$LIB_DIR/n8n-api.sh"
n8n_setup_owner

echo "=== check-policy-operation-hits-axonflow ==="

CONNECTOR_NAME="e2e-check-policy"

# SETUP: clean any prior rows for this connector
psql -h "$DB_HOST" -p "$DB_PORT" -U axonflow -d axonflow \
  -c "DELETE FROM mcp_query_audits WHERE connector_name = '$CONNECTOR_NAME'" 2>/dev/null || true

# 1. Create AxonFlow credential pointing to the in-compose agent
CRED_ID=$(n8n_create_credential "AxonFlow E2E Check" "http://axonflow-agent:8080" "e2e-n8n-test" "e2e-user-token")
echo "Created credential ID: $CRED_ID"

# 2. Import workflow with the credential ID patched in
WF_ID=$(n8n_import_workflow "$SCRIPT_DIR/workflow.json" "$CRED_ID")
echo "Imported workflow ID: $WF_ID"

# 3. Execute the workflow via n8n's REST API
echo "Executing workflow via n8n REST API..."
EXEC_ID=$(n8n_execute_workflow "$WF_ID")
echo "Execution ID: $EXEC_ID"

if [ "$EXEC_ID" = "unknown" ] || [ -z "$EXEC_ID" ]; then
  echo "FAIL: n8n did not return an execution ID"
  exit 1
fi

# 4. Wait for execution to complete
echo "Waiting for execution to complete..."
n8n_wait_execution "$EXEC_ID" 30

# 5. Assert: execution completed successfully
STATUS=$(n8n_execution_status "$EXEC_ID")
echo "Execution status: $STATUS"

if [ "$STATUS" != "success" ]; then
  echo "FAIL: workflow execution did not succeed (status=$STATUS)"
  echo "Execution detail:"
  n8n_get_execution "$EXEC_ID" | jq '.' 2>/dev/null || true
  exit 1
fi
echo "OK: workflow execution succeeded"

# 6. Assert: mcp_query_audits row exists for this connector
echo "Verifying mcp_query_audits DB state..."
"$LIB_DIR/verify-db.sh" mcp-audit-exists "$CONNECTOR_NAME"

# CLEANUP: remove test rows and workflow
psql -h "$DB_HOST" -p "$DB_PORT" -U axonflow -d axonflow \
  -c "DELETE FROM mcp_query_audits WHERE connector_name = '$CONNECTOR_NAME'" 2>/dev/null || true
n8n_delete_workflow "$WF_ID"

echo "PASS: check-policy-operation-hits-axonflow"
