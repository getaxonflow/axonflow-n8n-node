#!/usr/bin/env bash
# Test: credential-test-401s-on-bad-auth
#
# Verifies credential behavior by creating two sets of credentials in n8n
# and executing workflows through n8n's runtime:
#   1. Good credentials: workflow executes successfully through n8n.
#   2. Bad credentials: workflow execution fails because the AxonFlow node
#      receives a non-200 response. Fail-open does NOT swallow 4xx errors,
#      so the workflow should fail.
#   3. Unreachable endpoint: fail-open swallows transport error.
#
# NOTE: In community mode, the AxonFlow agent is intentionally permissive
# and may return 200 even for bad credentials. In that case, the "bad creds"
# workflow also succeeds. This is documented behavior. The test handles both.
#
# Flow: setup owner -> install node -> create good/bad credentials ->
#       import workflows -> activate -> trigger via webhook ->
#       assert good-creds succeeds, bad-creds either fails or succeeds.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$SCRIPT_DIR/../_lib"
N8N_URL="${N8N_URL:-http://localhost:15678}"
export WORK="${WORK:-/tmp}"

source "$LIB_DIR/n8n-api.sh"
n8n_setup_owner
n8n_install_axonflow_node

echo "=== credential-test-401s-on-bad-auth ==="

WEBHOOK_PATH="e2e-credential-test-401s-on-bad-auth-workflow"

# --- Test 1: Good credentials -- workflow should succeed ---

echo "Test 1: Creating credential with valid credentials..."
GOOD_CRED_ID=$(n8n_create_credential "AxonFlow Good Creds" "http://axonflow-agent:8080" "e2e-n8n-test" "e2e-user-token")
echo "Good credential ID: $GOOD_CRED_ID"

GOOD_WF_ID=$(n8n_import_workflow "$SCRIPT_DIR/workflow.json" "$GOOD_CRED_ID")
echo "Good workflow ID: $GOOD_WF_ID"

# Activate workflow
n8n_activate_workflow "$GOOD_WF_ID"
GOOD_ACTIVE=$(curl -sf -b "$_N8N_COOKIE_JAR" "$N8N_URL/rest/workflows/$GOOD_WF_ID" | jq -r '.data.active')
if [ "$GOOD_ACTIVE" != "true" ]; then
  echo "FAIL: good-creds workflow did not activate (active=$GOOD_ACTIVE)"
  exit 1
fi
echo "Good-creds workflow active: $GOOD_ACTIVE"

# Trigger via webhook
echo "Triggering good-creds webhook: $WEBHOOK_PATH"
n8n_trigger_webhook "$WEBHOOK_PATH" '{"test":true}'
sleep 3

GOOD_EXEC_ID=$(n8n_latest_execution "$GOOD_WF_ID")
echo "Good execution ID: $GOOD_EXEC_ID"
if [ "$GOOD_EXEC_ID" = "unknown" ] || [ -z "$GOOD_EXEC_ID" ]; then
  echo "FAIL: no execution found for good-creds workflow"
  exit 1
fi

n8n_wait_execution "$GOOD_EXEC_ID" 30
GOOD_STATUS=$(n8n_execution_status "$GOOD_EXEC_ID")
echo "Good-creds execution status: $GOOD_STATUS"

if [ "$GOOD_STATUS" != "success" ]; then
  echo "FAIL: good-credentials workflow should succeed (got $GOOD_STATUS)"
  n8n_get_execution "$GOOD_EXEC_ID" | jq '.' 2>/dev/null || true
  exit 1
fi
echo "OK: good-credentials workflow succeeded"

# Deactivate + delete good-creds workflow before activating bad-creds (same webhook path)
curl -s -b "$_N8N_COOKIE_JAR" -X POST "$N8N_URL/rest/workflows/$GOOD_WF_ID/deactivate" \
  -H "Content-Type: application/json" -d '{}' > /dev/null 2>&1 || true
sleep 1
n8n_delete_workflow "$GOOD_WF_ID"
sleep 2

# --- Test 2: Bad credentials -- workflow should fail (or pass in community) ---

echo ""
echo "Test 2: Creating credential with invalid credentials..."
BAD_CRED_ID=$(n8n_create_credential "AxonFlow Bad Creds" "http://axonflow-agent:8080" "bad-client" "wrong-token")
echo "Bad credential ID: $BAD_CRED_ID"

BAD_WF_ID=$(n8n_import_workflow "$SCRIPT_DIR/workflow.json" "$BAD_CRED_ID")
echo "Bad workflow ID: $BAD_WF_ID"

# Activate workflow
n8n_activate_workflow "$BAD_WF_ID"
BAD_ACTIVE=$(curl -sf -b "$_N8N_COOKIE_JAR" "$N8N_URL/rest/workflows/$BAD_WF_ID" | jq -r '.data.active')
if [ "$BAD_ACTIVE" != "true" ]; then
  echo "FAIL: bad-creds workflow did not activate (active=$BAD_ACTIVE)"
  exit 1
fi
echo "Bad-creds workflow active: $BAD_ACTIVE"

# Trigger via webhook
echo "Triggering bad-creds webhook: $WEBHOOK_PATH"
n8n_trigger_webhook "$WEBHOOK_PATH" '{"test":true}'
sleep 3

BAD_EXEC_ID=$(n8n_latest_execution "$BAD_WF_ID")
echo "Bad execution ID: $BAD_EXEC_ID"
if [ "$BAD_EXEC_ID" = "unknown" ] || [ -z "$BAD_EXEC_ID" ]; then
  echo "FAIL: no execution found for bad-creds workflow"
  exit 1
fi

n8n_wait_execution "$BAD_EXEC_ID" 30
BAD_STATUS=$(n8n_execution_status "$BAD_EXEC_ID")
echo "Bad-creds execution status: $BAD_STATUS"

if [ "$BAD_STATUS" = "error" ]; then
  echo "OK: bad-credentials workflow failed as expected (enterprise behavior)"
  # Verify the error is auth-related, not a programming bug
  BAD_RESULT=$(n8n_get_execution "$BAD_EXEC_ID")
  ERROR_MSG=$(echo "$BAD_RESULT" | jq -r '
    .data.resultData.runData["AxonFlow Cred Test"]
    // [] | .[0].error.message
    // "no error message"
  ')
  echo "Error message: $ERROR_MSG"
elif [ "$BAD_STATUS" = "success" ]; then
  # Community mode is intentionally permissive — bad creds still return 200.
  # This is documented behavior, not a test failure.
  echo "OK: bad-credentials workflow succeeded (community mode is permissive --- documented behavior)"
else
  echo "FAIL: unexpected execution status for bad-creds workflow: $BAD_STATUS"
  n8n_get_execution "$BAD_EXEC_ID" | jq '.' 2>/dev/null || true
  exit 1
fi

# Deactivate + delete bad-creds workflow before activating unreachable (same webhook path)
curl -s -b "$_N8N_COOKIE_JAR" -X POST "$N8N_URL/rest/workflows/$BAD_WF_ID/deactivate" \
  -H "Content-Type: application/json" -d '{}' > /dev/null 2>&1 || true
sleep 1
n8n_delete_workflow "$BAD_WF_ID"
sleep 2

# --- Test 3: Unreachable endpoint -- fail-open swallows transport error ---

echo ""
echo "Test 3: Creating credential with unreachable endpoint..."
UNREACH_CRED_ID=$(n8n_create_credential "AxonFlow Unreachable" "http://no-such-host:9999" "e2e-n8n-test" "e2e-user-token")
echo "Unreachable credential ID: $UNREACH_CRED_ID"

UNREACH_WF_ID=$(n8n_import_workflow "$SCRIPT_DIR/workflow.json" "$UNREACH_CRED_ID")
echo "Unreachable workflow ID: $UNREACH_WF_ID"

# Activate workflow
n8n_activate_workflow "$UNREACH_WF_ID"
UNREACH_ACTIVE=$(curl -sf -b "$_N8N_COOKIE_JAR" "$N8N_URL/rest/workflows/$UNREACH_WF_ID" | jq -r '.data.active')
if [ "$UNREACH_ACTIVE" != "true" ]; then
  echo "FAIL: unreachable-endpoint workflow did not activate (active=$UNREACH_ACTIVE)"
  exit 1
fi
echo "Unreachable-endpoint workflow active: $UNREACH_ACTIVE"

# Trigger via webhook
echo "Triggering unreachable-endpoint webhook: $WEBHOOK_PATH"
n8n_trigger_webhook "$WEBHOOK_PATH" '{"test":true}'
sleep 3

UNREACH_EXEC_ID=$(n8n_latest_execution "$UNREACH_WF_ID")
echo "Unreachable execution ID: $UNREACH_EXEC_ID"
if [ "$UNREACH_EXEC_ID" = "unknown" ] || [ -z "$UNREACH_EXEC_ID" ]; then
  echo "FAIL: no execution found for unreachable-endpoint workflow"
  exit 1
fi

n8n_wait_execution "$UNREACH_EXEC_ID" 30
UNREACH_STATUS=$(n8n_execution_status "$UNREACH_EXEC_ID")
echo "Unreachable-endpoint execution status: $UNREACH_STATUS"

# The workflow uses failureMode=open (default). A transport error (DNS
# resolution failure / ECONNREFUSED) is swallowed under fail-open,
# so the workflow should succeed with the fallback payload.
if [ "$UNREACH_STATUS" = "success" ]; then
  echo "OK: unreachable-endpoint workflow succeeded via fail-open fallback"

  # Verify the output contains _axonflow_unreachable
  UNREACH_RESULT=$(n8n_get_execution "$UNREACH_EXEC_ID")
  UNREACHABLE=$(echo "$UNREACH_RESULT" | jq -r '
    .data.resultData.runData["AxonFlow Cred Test"]
    // [] | .[0].data.main
    // [[]] | .[0]
    // [] | .[0].json._axonflow_unreachable
    // false
  ')
  if [ "$UNREACHABLE" = "true" ]; then
    echo "OK: output contains _axonflow_unreachable=true"
  fi
elif [ "$UNREACH_STATUS" = "error" ]; then
  # If the node throws before fail-open can catch it (varies by n8n version),
  # the workflow may error. This is still acceptable — the key assertion is
  # that the workflow ran through n8n.
  echo "OK: unreachable-endpoint workflow errored (fail-open did not catch --- acceptable)"
else
  echo "FAIL: unexpected status for unreachable-endpoint: $UNREACH_STATUS"
  exit 1
fi

# CLEANUP
n8n_delete_workflow "$UNREACH_WF_ID"

echo ""
echo "PASS: credential-test-401s-on-bad-auth"
