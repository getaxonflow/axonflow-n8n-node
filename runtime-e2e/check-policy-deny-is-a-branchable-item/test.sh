#!/usr/bin/env bash
# Test: check-policy-deny-is-a-branchable-item
#
# A statement a shipped control refuses (`rm -rf / --no-preserve-root`, the
# Destructive Filesystem Operations control) goes through Check Policy inside
# n8n, under Failure Mode Closed, into an IF node on {{ $json.allowed }}.
# The AxonFlow node is typeVersion 2, whose On Deny default outputs the deny
# as an item (a version-1 node stops instead: check-policy-deny-stops-a-version-1-node).
#
# AxonFlow answers that deny with HTTP 403. Before this change the node threw
# n8n's "Forbidden - perhaps check your credentials?" on every platform since
# AxonFlow v8, and the workflow stopped. This leg asserts the deny is an ITEM:
#   - the execution succeeds;
#   - the Check Policy item carries allowed: false, block_reason
#     "explicit_constraint" and a decision_id;
#   - the IF node took its FALSE branch: "Denied Branch" ran and
#     "Allowed Branch" did not;
#   - the platform recorded exactly one mcp_query_audits row for the call.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$SCRIPT_DIR/../_lib"
N8N_URL="${N8N_URL:-http://localhost:15678}"
# A leg run on its own gets a private directory: /tmp is shared by every run.
export WORK="${WORK:-$(mktemp -d)}"
export PGPASSWORD="${DB_PASSWORD:-localdev123}"
DB_HOST="${DB_HOST:-localhost}"
DB_PORT="${DB_PORT:-15432}"
DB_NAME="${DB_NAME:-axonflow}"
DB_USER="${DB_USER:-axonflow}"

source "$LIB_DIR/n8n-api.sh"
n8n_setup_owner
n8n_install_axonflow_node

echo "=== check-policy-deny-is-a-branchable-item ==="

CONNECTOR="e2e-deny-branch"
WEBHOOK_PATH="e2e-check-policy-deny-is-a-branchable-item-workflow"

psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" \
  -c "DELETE FROM mcp_query_audits WHERE connector_name = '$CONNECTOR'" 2>/dev/null || true

CRED_ID=$(n8n_create_credential "AxonFlow E2E Deny Branch" "http://axonflow-agent:8080" "e2e-n8n-test" "e2e-user-token")
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
n8n_get_execution "$EXEC_ID" > "$WORK/deny-branch-execution.json"
echo "Execution $EXEC_ID status: $STATUS"

FAILS=0
fail() { echo "FAIL: $*"; FAILS=$((FAILS + 1)); }

[ "$STATUS" = "success" ] || fail "the execution should succeed (a deny is a decision, not an error), got $STATUS; node error: $(n8n_node_error "$EXEC_ID" "AxonFlow Check Policy")"

ITEM=$(n8n_node_item "$EXEC_ID" "AxonFlow Check Policy")
echo "Check Policy item: ${ITEM:-(none)}"
[ -n "$ITEM" ] || ITEM='{}'
[ "$(jq -r '.allowed | tostring' <<<"$ITEM")" = "false" ] || fail "the item's allowed is not false"
[ "$(jq -r '.block_reason // "absent"' <<<"$ITEM")" = "explicit_constraint" ] || fail "the item's block_reason is not explicit_constraint"
[ -n "$(jq -r '.decision_id // empty' <<<"$ITEM")" ] || fail "the item has no decision_id"

DENIED=$(n8n_node_item "$EXEC_ID" "Denied Branch")
ALLOWED=$(n8n_node_item "$EXEC_ID" "Allowed Branch")
[ -n "$DENIED" ] || fail "the IF node did not take its false branch (Denied Branch has no output)"
[ -z "$ALLOWED" ] || fail "the IF node took its true branch (Allowed Branch ran: $ALLOWED)"

"$LIB_DIR/verify-db.sh" mcp-audit-count "$CONNECTOR" 1 || FAILS=$((FAILS + 1))

n8n_delete_workflow "$WF_ID"
[ "$FAILS" -eq 0 ] || exit 1
echo "PASS: check-policy-deny-is-a-branchable-item"
