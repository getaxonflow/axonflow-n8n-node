#!/usr/bin/env bash
# Test: check-policy-deny-stops-a-version-1-node
#
# The same workflow as check-policy-deny-is-a-branchable-item, with the AxonFlow
# node at typeVersion 1 and On Deny NOT set: the shape of every workflow saved
# before On Deny existed. A deny must still STOP it, as a deny always did, now
# with the reason named:
#   - the execution ends in error;
#   - the node's error is "AxonFlow denied the request: explicit_constraint
#     (decision <id>)";
#   - neither branch of the IF after it ran.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$SCRIPT_DIR/../_lib"
N8N_URL="${N8N_URL:-http://localhost:15678}"
# A leg run on its own gets a private directory: /tmp is shared by every run.
export WORK="${WORK:-$(mktemp -d)}"

source "$LIB_DIR/n8n-api.sh"
n8n_setup_owner
n8n_install_axonflow_node

echo "=== check-policy-deny-stops-a-version-1-node ==="

WEBHOOK_PATH="e2e-check-policy-deny-stops-a-version-1-node-workflow"
WANT_PREFIX="AxonFlow denied the request: explicit_constraint (decision "

CRED_ID=$(n8n_create_credential "AxonFlow E2E Deny v1" "http://axonflow-agent:8080" "e2e-n8n-test" "e2e-user-token")
WF_ID=$(n8n_import_workflow "$SCRIPT_DIR/workflow.json" "$CRED_ID")
n8n_activate_workflow "$WF_ID"
ACTIVE=$(curl -sf -b "$_N8N_COOKIE_JAR" "$N8N_URL/rest/workflows/$WF_ID" | jq -r '.data.active')
if [ "$ACTIVE" != "true" ]; then
  echo "FAIL: workflow did not activate (active=$ACTIVE)"
  exit 1
fi

n8n_trigger_webhook "$WEBHOOK_PATH" '{"test":true}'
sleep 3
EXEC_ID=$(n8n_latest_execution "$WF_ID")
if [ "$EXEC_ID" = "unknown" ] || [ -z "$EXEC_ID" ]; then
  echo "FAIL: no execution found for workflow $WF_ID"
  exit 1
fi
n8n_wait_execution "$EXEC_ID" 30
STATUS=$(n8n_execution_status "$EXEC_ID")
n8n_get_execution "$EXEC_ID" > "$WORK/deny-v1-execution.json"
ERROR_MSG=$(n8n_node_error "$EXEC_ID" "AxonFlow Check Policy")
echo "Execution $EXEC_ID status: $STATUS"
echo "Node error: ${ERROR_MSG:-(none)}"

FAILS=0
fail() { echo "FAIL: $*"; FAILS=$((FAILS + 1)); }
[ "$STATUS" = "error" ] || fail "a version-1 node must stop on a deny, got status $STATUS"
case "$ERROR_MSG" in
  "$WANT_PREFIX"*) echo "OK: the error names the reason and the decision" ;;
  *) fail "the node's error does not name the deny; want prefix '$WANT_PREFIX', got '${ERROR_MSG}'" ;;
esac
[ -z "$(n8n_node_item "$EXEC_ID" "Denied Branch")" ] || fail "the IF's false branch ran after a stopped node"
[ -z "$(n8n_node_item "$EXEC_ID" "Allowed Branch")" ] || fail "the IF's true branch ran after a stopped node"

n8n_delete_workflow "$WF_ID"
[ "$FAILS" -eq 0 ] || exit 1
echo "PASS: check-policy-deny-stops-a-version-1-node"
