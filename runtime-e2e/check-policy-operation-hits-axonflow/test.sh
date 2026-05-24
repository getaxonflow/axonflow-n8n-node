#!/usr/bin/env bash
# Test: check-policy-operation-hits-axonflow
#
# Verifies that an n8n workflow using the Check Policy operation successfully
# calls the AxonFlow agent and records the request in mcp_query_audits.
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

echo "=== check-policy-operation-hits-axonflow ==="

CONNECTOR_NAME="e2e-check-policy"
WEBHOOK_PATH="e2e-check-policy-operation-hits-axonflow-workflow"

# SETUP: clean prior rows
psql -h "$DB_HOST" -p "$DB_PORT" -U axonflow -d axonflow \
  -c "DELETE FROM mcp_query_audits WHERE connector_name = '$CONNECTOR_NAME'" 2>/dev/null || true

# 1. Create credential
CRED_ID=$(n8n_create_credential "AxonFlow E2E Check" "http://axonflow-agent:8080" "e2e-n8n-test" "e2e-user-token")
echo "Credential ID: $CRED_ID"

# 2. Import workflow
WF_ID=$(n8n_import_workflow "$SCRIPT_DIR/workflow.json" "$CRED_ID")
echo "Workflow ID: $WF_ID"

# 3. Activate workflow (webhook must be active to trigger)
n8n_activate_workflow "$WF_ID"
ACTIVE=$(curl -sf -b "$_N8N_COOKIE_JAR" "$N8N_URL/rest/workflows/$WF_ID" | jq -r '.data.active')
if [ "$ACTIVE" != "true" ]; then
  echo "FAIL: workflow did not activate (active=$ACTIVE)"
  exit 1
fi
echo "Workflow active: $ACTIVE"

# 4. Trigger via webhook
echo "Triggering webhook: $WEBHOOK_PATH"
n8n_trigger_webhook "$WEBHOOK_PATH" '{"test":true}'
sleep 3

# 5. Get execution and wait
EXEC_ID=$(n8n_latest_execution "$WF_ID")
echo "Execution ID: $EXEC_ID"
if [ "$EXEC_ID" = "unknown" ] || [ -z "$EXEC_ID" ]; then
  echo "FAIL: no execution found for workflow $WF_ID"
  exit 1
fi

n8n_wait_execution "$EXEC_ID" 30
STATUS=$(n8n_execution_status "$EXEC_ID")
echo "Execution status: $STATUS"

if [ "$STATUS" != "success" ]; then
  echo "FAIL: workflow execution did not succeed (status=$STATUS)"
  exit 1
fi
echo "OK: workflow execution succeeded"

# 6. Assert: DB row exists
"$LIB_DIR/verify-db.sh" mcp-audit-exists "$CONNECTOR_NAME"

# CLEANUP
psql -h "$DB_HOST" -p "$DB_PORT" -U axonflow -d axonflow \
  -c "DELETE FROM mcp_query_audits WHERE connector_name = '$CONNECTOR_NAME'" 2>/dev/null || true
n8n_delete_workflow "$WF_ID"

echo "PASS: check-policy-operation-hits-axonflow"
