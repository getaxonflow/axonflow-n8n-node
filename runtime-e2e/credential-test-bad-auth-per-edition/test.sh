#!/usr/bin/env bash
# Test: credential-test-bad-auth-per-edition
#
# Drives one Check Policy workflow through n8n's runtime with three
# credentials and asserts, per edition, what each produces:
#
#   1. A valid credential: the execution succeeds and the item is a decision
#      (`allowed` is a boolean).
#   2. A wrong credential:
#      Community admits any credential (the platform does not check the
#      secret), so the execution succeeds with a decision item.
#      Enterprise refuses it: the execution errors and the node's error names
#      the credential, `AxonFlow rejected the credential (HTTP 401): ...`.
#   3. An endpoint that does not resolve, under the default Failure Mode Open:
#      the execution succeeds with the fallback item, `_axonflow_unreachable`,
#      `governance: "unavailable"`, `cause: "no_response"`, and NO `allowed`.
#
# The edition is read from the agent's /health; one this leg cannot read
# fails. Before v11.1.0 this leg was named credential-test-401s-on-bad-auth
# and accepted success or failure in steps 2 and 3, so it asserted neither.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$SCRIPT_DIR/../_lib"
N8N_URL="${N8N_URL:-http://localhost:15678}"
AGENT_URL="${AGENT_URL:-http://localhost:18080}"
# A leg run on its own gets a private directory: /tmp is shared by every run.
export WORK="${WORK:-$(mktemp -d)}"

source "$LIB_DIR/n8n-api.sh"
n8n_setup_owner
n8n_install_axonflow_node

echo "=== credential-test-bad-auth-per-edition ==="

NODE_NAME="AxonFlow Cred Test"
WEBHOOK_PATH="e2e-credential-test-bad-auth-per-edition-workflow"
REJECTED_PREFIX="AxonFlow rejected the credential (HTTP 401): "

HEALTH=$(curl -sf --max-time 5 "$AGENT_URL/health" || echo '{}')
EDITION=$(jq -r '.edition // ""' <<<"$HEALTH")
echo "Agent edition: ${EDITION:-unknown} (from $AGENT_URL/health)"
case "$EDITION" in
  community|enterprise) ;;
  *) echo "FAIL: could not read the agent's edition from /health: $HEALTH"; exit 1 ;;
esac

FAILS=0
fail() { echo "FAIL: $*"; FAILS=$((FAILS + 1)); }

# run_with_credential <label> <endpoint> <client id> <secret>: import the
# workflow with a new credential, trigger it, and leave EXEC_ID and STATUS set.
# The workflow is deleted afterwards, since every run shares one webhook path.
run_with_credential() {
  local label="$1" endpoint="$2" client_id="$3" secret="$4" cred_id wf_id active
  cred_id=$(n8n_create_credential "AxonFlow $label" "$endpoint" "$client_id" "$secret")
  wf_id=$(n8n_import_workflow "$SCRIPT_DIR/workflow.json" "$cred_id")
  n8n_activate_workflow "$wf_id"
  active=$(curl -sf -b "$_N8N_COOKIE_JAR" "$N8N_URL/rest/workflows/$wf_id" | jq -r '.data.active')
  if [ "$active" != "true" ]; then
    echo "FAIL: $label workflow did not activate (active=$active)"
    exit 1
  fi
  n8n_trigger_webhook "$WEBHOOK_PATH" '{"test":true}'
  sleep 3
  EXEC_ID=$(n8n_latest_execution "$wf_id")
  if [ "$EXEC_ID" = "unknown" ] || [ -z "$EXEC_ID" ]; then
    echo "FAIL: no execution found for the $label workflow"
    exit 1
  fi
  n8n_wait_execution "$EXEC_ID" 30
  STATUS=$(n8n_execution_status "$EXEC_ID")
  n8n_get_execution "$EXEC_ID" > "$WORK/credential-leg-$label.json"
  echo "$label: execution $EXEC_ID status $STATUS"
  curl -s -b "$_N8N_COOKIE_JAR" -X POST "$N8N_URL/rest/workflows/$wf_id/deactivate" \
    -H "Content-Type: application/json" -d '{}' > /dev/null 2>&1 || true
  sleep 1
  n8n_delete_workflow "$wf_id"
  sleep 2
}

assert_decision_item() {
  local label="$1" item
  item=$(n8n_node_item "$EXEC_ID" "$NODE_NAME")
  echo "$label item: ${item:-(none)}"
  [ "$STATUS" = "success" ] || fail "$label: the execution should succeed, got $STATUS"
  [ "$(jq -r '.allowed | type' <<<"${item:-{\}}" 2>/dev/null)" = "boolean" ] \
    || fail "$label: the item is not a decision (no boolean allowed)"
}

# --- 1. A valid credential ---------------------------------------------------
run_with_credential good "http://axonflow-agent:8080" "e2e-n8n-test" "e2e-user-token"
assert_decision_item good

# --- 2. A wrong credential ---------------------------------------------------
run_with_credential wrong "http://axonflow-agent:8080" "bad-client" "wrong-token"
if [ "$EDITION" = "community" ]; then
  assert_decision_item "wrong (community admits any credential)"
else
  ERROR_MSG=$(n8n_node_error "$EXEC_ID" "$NODE_NAME")
  echo "wrong error: ${ERROR_MSG:-(none)}"
  [ "$STATUS" = "error" ] || fail "wrong: on Enterprise the execution should end in error, got $STATUS"
  case "$ERROR_MSG" in
    "$REJECTED_PREFIX"*) echo "OK: the node's error names the credential" ;;
    *) fail "wrong: the node's error does not name the credential; want prefix '$REJECTED_PREFIX', got '${ERROR_MSG}'" ;;
  esac
fi

# --- 3. An endpoint that does not resolve (Failure Mode Open) ------------------
run_with_credential unreachable "http://no-such-host:9999" "e2e-n8n-test" "e2e-user-token"
ITEM=$(n8n_node_item "$EXEC_ID" "$NODE_NAME")
echo "unreachable item: ${ITEM:-(none)}"
[ -n "$ITEM" ] || ITEM='{}'
[ "$STATUS" = "success" ] || fail "unreachable: Failure Mode Open should let the execution succeed, got $STATUS"
[ "$(jq -r '._axonflow_unreachable // "absent"' <<<"$ITEM")" = "true" ] || fail "unreachable: no _axonflow_unreachable: true"
[ "$(jq -r '.governance // "absent"' <<<"$ITEM")" = "unavailable" ] || fail "unreachable: no governance: \"unavailable\""
[ "$(jq -r '.cause // "absent"' <<<"$ITEM")" = "no_response" ] || fail "unreachable: cause is not no_response"
[ "$(jq -r 'has("allowed")' <<<"$ITEM")" = "false" ] || fail "unreachable: the fallback item carries an allowed key"

[ "$FAILS" -eq 0 ] || { echo "credential-test-bad-auth-per-edition: $FAILS failure(s)"; exit 1; }
echo ""
echo "PASS: credential-test-bad-auth-per-edition ($EDITION)"
