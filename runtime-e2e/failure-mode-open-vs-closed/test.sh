#!/usr/bin/env bash
# Test: failure-mode-open-vs-closed
#
# Verifies the node's fail-open / fail-closed behavior by executing real
# n8n workflows against an AxonFlow agent that is stopped mid-test.
#
# Test matrix (3 phases):
#   Phase 1 (agent UP):  both open + closed workflows succeed normally
#   Phase 2 (agent DOWN): fail-open workflow succeeds with _axonflow_unreachable fallback
#   Phase 3 (agent DOWN): fail-closed workflow errors (transport error rethrown)
#
# After Phase 3, the agent is restarted for subsequent tests.
#
# Flow per phase: setup owner -> install node -> create credential ->
#                 import workflows -> activate -> trigger via webhook ->
#                 wait -> assert execution status + output shape.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$SCRIPT_DIR/../_lib"
N8N_URL="${N8N_URL:-http://localhost:15678}"
AGENT_URL="${AGENT_URL:-http://localhost:18080}"
# A leg run on its own gets a private directory: /tmp is shared by every run.
export WORK="${WORK:-$(mktemp -d)}"

export PGPASSWORD="${DB_PASSWORD:-localdev123}"
DB_HOST="${DB_HOST:-localhost}"
DB_PORT="${DB_PORT:-15432}"
DB_NAME="${DB_NAME:-axonflow}"
DB_USER="${DB_USER:-axonflow}"
COMPOSE_PROJECT_NAME="${COMPOSE_PROJECT_NAME:-runtime-e2e}"
# The agent is stopped and started by compose service name within this project,
# never by container name, so a sibling stack's agent is never touched.
agent_compose() { docker compose -p "$COMPOSE_PROJECT_NAME" -f "$SCRIPT_DIR/../docker-compose.yml" "$@"; }
# Whatever ends this leg (a failed assertion, a timeout under set -e), the agent
# it stopped is started again, so the next leg does not fail on a dead agent.
AGENT_STOPPED=false
restart_agent_if_stopped() {
  if [ "$AGENT_STOPPED" = "true" ]; then
    agent_compose start axonflow-agent >/dev/null 2>&1 || true
    AGENT_STOPPED=false
  fi
}
trap restart_agent_if_stopped EXIT

source "$LIB_DIR/n8n-api.sh"
n8n_setup_owner
n8n_install_axonflow_node

echo "=== failure-mode-open-vs-closed ==="

WEBHOOK_PATH_OPEN="e2e-failure-mode-open-vs-closed-workflow-open"
WEBHOOK_PATH_CLOSED="e2e-failure-mode-open-vs-closed-workflow-closed"

# SETUP: clean prior test rows
psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" \
  -c "DELETE FROM mcp_query_audits WHERE connector_name LIKE 'e2e-failure-mode%'" 2>/dev/null || true

# 1. Create AxonFlow credential (points to in-compose agent at http://axonflow-agent:8080)
CRED_ID=$(n8n_create_credential "AxonFlow E2E FailMode" "http://axonflow-agent:8080" "e2e-n8n-test" "e2e-user-token")
echo "Created credential ID: $CRED_ID"

# 2. Import both workflows
WF_OPEN_ID=$(n8n_import_workflow "$SCRIPT_DIR/workflow-open.json" "$CRED_ID")
echo "Imported fail-open workflow ID: $WF_OPEN_ID"

WF_CLOSED_ID=$(n8n_import_workflow "$SCRIPT_DIR/workflow-closed.json" "$CRED_ID")
echo "Imported fail-closed workflow ID: $WF_CLOSED_ID"

# 3. Activate both workflows (webhooks must be active to trigger)
n8n_activate_workflow "$WF_OPEN_ID"
ACTIVE_OPEN=$(curl -sf -b "$_N8N_COOKIE_JAR" "$N8N_URL/rest/workflows/$WF_OPEN_ID" | jq -r '.data.active')
if [ "$ACTIVE_OPEN" != "true" ]; then
  echo "FAIL: fail-open workflow did not activate (active=$ACTIVE_OPEN)"
  exit 1
fi
echo "Fail-open workflow active: $ACTIVE_OPEN"

n8n_activate_workflow "$WF_CLOSED_ID"
ACTIVE_CLOSED=$(curl -sf -b "$_N8N_COOKIE_JAR" "$N8N_URL/rest/workflows/$WF_CLOSED_ID" | jq -r '.data.active')
if [ "$ACTIVE_CLOSED" != "true" ]; then
  echo "FAIL: fail-closed workflow did not activate (active=$ACTIVE_CLOSED)"
  exit 1
fi
echo "Fail-closed workflow active: $ACTIVE_CLOSED"

# --- Phase 1: Agent UP -- both modes succeed ---

echo ""
echo "--- Phase 1: Agent UP --- both modes should succeed ---"

echo "Triggering fail-open webhook (agent UP): $WEBHOOK_PATH_OPEN"
n8n_trigger_webhook "$WEBHOOK_PATH_OPEN" '{"test":true}'
sleep 3

EXEC_OPEN1=$(n8n_latest_execution "$WF_OPEN_ID")
echo "Fail-open execution ID (agent UP): $EXEC_OPEN1"
n8n_wait_execution "$EXEC_OPEN1" 30
STATUS_OPEN1=$(n8n_execution_status "$EXEC_OPEN1")
echo "Fail-open status (agent UP): $STATUS_OPEN1"

if [ "$STATUS_OPEN1" != "success" ]; then
  echo "FAIL: fail-open workflow should succeed when agent is UP (got $STATUS_OPEN1)"
  n8n_get_execution "$EXEC_OPEN1" | jq '.' 2>/dev/null || true
  exit 1
fi
echo "OK: fail-open workflow succeeded with agent UP"

echo "Triggering fail-closed webhook (agent UP): $WEBHOOK_PATH_CLOSED"
n8n_trigger_webhook "$WEBHOOK_PATH_CLOSED" '{"test":true}'
sleep 3

EXEC_CLOSED1=$(n8n_latest_execution "$WF_CLOSED_ID")
echo "Fail-closed execution ID (agent UP): $EXEC_CLOSED1"
n8n_wait_execution "$EXEC_CLOSED1" 30
STATUS_CLOSED1=$(n8n_execution_status "$EXEC_CLOSED1")
echo "Fail-closed status (agent UP): $STATUS_CLOSED1"

if [ "$STATUS_CLOSED1" != "success" ]; then
  echo "FAIL: fail-closed workflow should succeed when agent is UP (got $STATUS_CLOSED1)"
  n8n_get_execution "$EXEC_CLOSED1" | jq '.' 2>/dev/null || true
  exit 1
fi
echo "OK: fail-closed workflow succeeded with agent UP"

# --- Phase 2: Stop agent, test fail-open ---

echo ""
echo "--- Phase 2: Stopping axonflow-agent container ---"
agent_compose stop axonflow-agent
AGENT_STOPPED=true

# Wait for port to be truly unreachable
for i in $(seq 1 15); do
  if ! curl -sf -o /dev/null --max-time 1 "$AGENT_URL/health" 2>/dev/null; then
    echo "Agent confirmed unreachable after ${i}s"
    break
  fi
  sleep 1
done

echo ""
echo "--- Phase 2a: Fail-open workflow with agent DOWN ---"
echo "Triggering fail-open webhook (agent DOWN): $WEBHOOK_PATH_OPEN"
n8n_trigger_webhook "$WEBHOOK_PATH_OPEN" '{"test":true}'
sleep 3

EXEC_OPEN2=$(n8n_latest_execution "$WF_OPEN_ID")
echo "Fail-open execution ID (agent DOWN): $EXEC_OPEN2"
n8n_wait_execution "$EXEC_OPEN2" 30
STATUS_OPEN2=$(n8n_execution_status "$EXEC_OPEN2")
echo "Fail-open status (agent DOWN): $STATUS_OPEN2"

if [ "$STATUS_OPEN2" != "success" ]; then
  echo "FAIL: fail-open workflow should succeed even when agent is DOWN (got $STATUS_OPEN2)"
  echo "Fail-open means the workflow continues with a fallback payload."
  n8n_get_execution "$EXEC_OPEN2" | jq '.' 2>/dev/null || true
  exit 1
fi
echo "OK: fail-open workflow succeeded with agent DOWN"

# The fallback item, field by field. A success without it is not fail-open:
# it is a workflow that ran with no decision and said nothing. And the item
# must carry NO `allowed` key: workflows branch on {{ $json.allowed }}, and an
# `allowed: true` here would send every saved workflow down its TRUE branch
# during an outage.
n8n_get_execution "$EXEC_OPEN2" > "$WORK/failure-mode-open-agent-down.json"
OPEN2_ITEM=$(n8n_node_item "$EXEC_OPEN2" "AxonFlow Fail Open")
[ -n "$OPEN2_ITEM" ] || OPEN2_ITEM='{}'
echo "Fail-open item (agent DOWN): $OPEN2_ITEM"
ITEM_FAILS=0
[ "$(printf '%s' "$OPEN2_ITEM" | jq -r '._axonflow_unreachable // "absent"')" = "true" ] \
  || { echo "FAIL: the fail-open item has no _axonflow_unreachable: true"; ITEM_FAILS=1; }
[ "$(printf '%s' "$OPEN2_ITEM" | jq -r '.governance // "absent"')" = "unavailable" ] \
  || { echo "FAIL: the fail-open item has no governance: \"unavailable\""; ITEM_FAILS=1; }
[ "$(printf '%s' "$OPEN2_ITEM" | jq -r '.cause // "absent"')" = "no_response" ] \
  || { echo "FAIL: the fail-open item's cause is not no_response (the agent is stopped)"; ITEM_FAILS=1; }
[ "$(printf '%s' "$OPEN2_ITEM" | jq -r 'has("allowed")')" = "false" ] \
  || { echo "FAIL: the fail-open item carries an allowed key; a saved IF on \$json.allowed would change branch"; ITEM_FAILS=1; }
if [ "$ITEM_FAILS" -ne 0 ]; then
  exit 1
fi
echo "OK: fail-open item carries _axonflow_unreachable, governance=unavailable, cause=no_response, and no allowed key"

# --- Phase 3: Fail-closed workflow with agent DOWN ---

echo ""
echo "--- Phase 3: Fail-closed workflow with agent DOWN ---"
echo "Triggering fail-closed webhook (agent DOWN): $WEBHOOK_PATH_CLOSED"
n8n_trigger_webhook "$WEBHOOK_PATH_CLOSED" '{"test":true}'
sleep 3

EXEC_CLOSED2=$(n8n_latest_execution "$WF_CLOSED_ID")
echo "Fail-closed execution ID (agent DOWN): $EXEC_CLOSED2"
n8n_wait_execution "$EXEC_CLOSED2" 30
STATUS_CLOSED2=$(n8n_execution_status "$EXEC_CLOSED2")
echo "Fail-closed status (agent DOWN): $STATUS_CLOSED2"

# Fail-closed means the execution ENDED IN ERROR, with the node's own error:
# not success, and not unknown / crashed / waiting.
CLOSED2_ERROR=$(n8n_node_error "$EXEC_CLOSED2" "AxonFlow Fail Closed")
echo "Fail-closed node error (agent DOWN): ${CLOSED2_ERROR:-(none)}"
if [ "$STATUS_CLOSED2" != "error" ] || [ -z "$CLOSED2_ERROR" ]; then
  echo "FAIL: fail-closed workflow should end in error with the AxonFlow node's error when the agent is DOWN (status=$STATUS_CLOSED2)"
  exit 1
fi
echo "OK: fail-closed workflow errored with agent DOWN (status=$STATUS_CLOSED2)"

# --- Restore: restart agent for subsequent tests ---

echo ""
echo "Restarting axonflow-agent container..."
agent_compose start axonflow-agent
AGENT_STOPPED=false

echo "Waiting for agent to be healthy..."
for i in $(seq 1 60); do
  if curl -sf -o /dev/null --max-time 2 "$AGENT_URL/health" 2>/dev/null; then
    echo "Agent healthy after restart (${i}s)"
    break
  fi
  if [ "$i" -eq 60 ]; then
    echo "FAIL: agent not healthy after restart"
    exit 1
  fi
  sleep 1
done

# CLEANUP: remove test rows and workflows
psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" \
  -c "DELETE FROM mcp_query_audits WHERE connector_name LIKE 'e2e-failure-mode%'" 2>/dev/null || true
n8n_delete_workflow "$WF_OPEN_ID"
n8n_delete_workflow "$WF_CLOSED_ID"

echo "PASS: failure-mode-open-vs-closed"
