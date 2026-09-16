#!/usr/bin/env bash
# Test: wait-for-approval-creates-queue-row
#
# Drives the Wait for Approval operation through n8n's workflow runtime and
# asserts what it does on the edition the agent reports. The operation creates
# an approval request and returns at once; it does not pause a workflow (an n8n
# Wait node does that), so this leg asserts no pause.
#
#   Community: /api/v1/hitl/queue is Enterprise-only and answers 404. The
#     execution must END IN ERROR with the node's edition message, word for
#     word. Any other outcome fails.
#   Enterprise: the execution must SUCCEED with an item carrying an
#     approval_id, and hitl_approval_queue must hold exactly that row.
#
# This leg used to pass on success AND on error, so it asserted nothing.
#
# Flow: setup owner -> install node -> create credential -> import workflow
#       -> activate -> trigger via webhook -> wait -> assert per edition.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$SCRIPT_DIR/../_lib"
N8N_URL="${N8N_URL:-http://localhost:15678}"
AGENT_URL="${AGENT_URL:-http://localhost:18080}"
export WORK="${WORK:-/tmp}"
export PGPASSWORD="${DB_PASSWORD:-localdev123}"
DB_HOST="${DB_HOST:-localhost}"
DB_PORT="${DB_PORT:-15432}"
DB_NAME="${DB_NAME:-axonflow}"
DB_USER="${DB_USER:-axonflow}"

source "$LIB_DIR/n8n-api.sh"
n8n_setup_owner
n8n_install_axonflow_node

echo "=== wait-for-approval-creates-queue-row ==="

NODE_NAME="AxonFlow Wait for Approval"
WEBHOOK_PATH="e2e-wait-for-approval-creates-queue-row-workflow"
COMMUNITY_MESSAGE_PREFIX="AxonFlow has no approval queue at this endpoint (HTTP 404): /api/v1/hitl/queue is served by AxonFlow Enterprise only, so a Community deployment cannot create an approval request"

# The edition, from the agent itself. An edition this leg cannot read is a
# failure, not a guess.
HEALTH=$(curl -sf --max-time 5 "$AGENT_URL/health" || echo '{}')
# `edition` is the build's own (community | enterprise); `deployment_mode` is a
# different fact (how it is configured) and is not read here.
EDITION=$(jq -r '.edition // ""' <<<"$HEALTH")
echo "Agent edition: ${EDITION:-unknown} (from $AGENT_URL/health)"
case "$EDITION" in
  community|enterprise) ;;
  *)
    echo "FAIL: could not read the agent's edition from /health: $HEALTH"
    exit 1
    ;;
esac

CRED_ID=$(n8n_create_credential "AxonFlow E2E HITL" "http://axonflow-agent:8080" "e2e-n8n-test" "e2e-user-token")
echo "Created credential ID: $CRED_ID"
WF_ID=$(n8n_import_workflow "$SCRIPT_DIR/workflow.json" "$CRED_ID")
echo "Imported workflow ID: $WF_ID"
n8n_activate_workflow "$WF_ID"
ACTIVE=$(curl -sf -b "$_N8N_COOKIE_JAR" "$N8N_URL/rest/workflows/$WF_ID" | jq -r '.data.active')
if [ "$ACTIVE" != "true" ]; then
  echo "FAIL: workflow did not activate (active=$ACTIVE)"
  exit 1
fi

echo "Triggering webhook: $WEBHOOK_PATH"
n8n_trigger_webhook "$WEBHOOK_PATH" '{"test":true}'
sleep 3
EXEC_ID=$(n8n_latest_execution "$WF_ID")
echo "Execution ID: $EXEC_ID"
if [ "$EXEC_ID" = "unknown" ] || [ -z "$EXEC_ID" ]; then
  echo "FAIL: no execution found for workflow $WF_ID"
  exit 1
fi
n8n_wait_execution "$EXEC_ID" 30
STATUS=$(n8n_execution_status "$EXEC_ID")
echo "Execution status: $STATUS"
n8n_get_execution "$EXEC_ID" > "$WORK/wait-for-approval-execution.json"

FAILS=0
if [ "$EDITION" = "community" ]; then
  ERROR_MSG=$(n8n_node_error "$EXEC_ID" "$NODE_NAME")
  echo "Node error: $ERROR_MSG"
  if [ "$STATUS" != "error" ]; then
    echo "FAIL: on Community the execution must end in error (the queue route is Enterprise-only), got $STATUS"
    FAILS=1
  fi
  case "$ERROR_MSG" in
    "$COMMUNITY_MESSAGE_PREFIX"*) echo "OK: the node's error names the edition" ;;
    *)
      echo "FAIL: the node's error does not name the edition"
      echo "  want prefix: $COMMUNITY_MESSAGE_PREFIX"
      echo "  got:         ${ERROR_MSG:-(no error message read from the execution)}"
      FAILS=1
      ;;
  esac
else
  ITEM=$(n8n_node_item "$EXEC_ID" "$NODE_NAME")
  echo "Node item: $ITEM"
  [ -n "$ITEM" ] || ITEM='{}'
  APPROVAL_ID=$(jq -r '.approval_id // empty' <<<"$ITEM")
  if [ "$STATUS" != "success" ]; then
    echo "FAIL: on Enterprise the execution must succeed, got $STATUS"
    FAILS=1
  fi
  if [ -z "$APPROVAL_ID" ]; then
    echo "FAIL: the item carries no approval_id"
    FAILS=1
  else
    ROWS=$(psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -tAc \
      "SELECT count(*) FROM hitl_approval_queue WHERE id::text = '$APPROVAL_ID'")
    if [ "$ROWS" = "1" ]; then
      echo "OK: hitl_approval_queue holds the row $APPROVAL_ID"
    else
      echo "FAIL: hitl_approval_queue holds $ROWS row(s) for approval_id $APPROVAL_ID, want 1"
      FAILS=1
    fi
  fi
fi

n8n_delete_workflow "$WF_ID"
[ "$FAILS" -eq 0 ] || exit 1
echo "PASS: wait-for-approval-creates-queue-row ($EDITION)"
