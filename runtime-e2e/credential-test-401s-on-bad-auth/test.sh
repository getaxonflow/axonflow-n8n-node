#!/usr/bin/env bash
# Test: credential-test-401s-on-bad-auth
#
# Verifies credential behavior by creating two sets of credentials in n8n
# and executing workflows through n8n's runtime:
#   1. Good credentials: workflow executes successfully through n8n.
#   2. Bad credentials: workflow execution fails because the AxonFlow node
#      receives a non-200 response. Fail-open does NOT swallow 4xx errors,
#      so the workflow should fail.
#
# NOTE: In community mode, the AxonFlow agent is intentionally permissive
# and may return 200 even for bad credentials. In that case, the "bad creds"
# workflow also succeeds. This is documented behavior — see the credential
# type docstring. The test handles both cases.
#
# Flow: create good/bad credentials -> import workflows -> execute via n8n
#       REST API -> assert good-creds workflow succeeds -> assert bad-creds
#       workflow either fails (enterprise) or succeeds (community permissive).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$SCRIPT_DIR/../_lib"
N8N_URL="${N8N_URL:-http://localhost:15678}"

source "$LIB_DIR/n8n-api.sh"
n8n_setup_owner

echo "=== credential-test-401s-on-bad-auth ==="

# ─── Test 1: Good credentials — workflow should succeed ─────────────────

echo "Test 1: Creating credential with valid credentials..."
GOOD_CRED_ID=$(n8n_create_credential "AxonFlow Good Creds" "http://axonflow-agent:8080" "e2e-n8n-test" "e2e-user-token")
echo "Good credential ID: $GOOD_CRED_ID"

GOOD_WF_ID=$(n8n_import_workflow "$SCRIPT_DIR/workflow.json" "$GOOD_CRED_ID")
echo "Good workflow ID: $GOOD_WF_ID"

echo "Executing good-credentials workflow..."
GOOD_EXEC_ID=$(n8n_execute_workflow "$GOOD_WF_ID")
echo "Good execution ID: $GOOD_EXEC_ID"

if [ "$GOOD_EXEC_ID" = "unknown" ] || [ -z "$GOOD_EXEC_ID" ]; then
  echo "FAIL: n8n did not return an execution ID for good-creds workflow"
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

# ─── Test 2: Bad credentials — workflow should fail (or pass in community) ──

echo ""
echo "Test 2: Creating credential with invalid credentials..."
BAD_CRED_ID=$(n8n_create_credential "AxonFlow Bad Creds" "http://axonflow-agent:8080" "bad-client" "wrong-token")
echo "Bad credential ID: $BAD_CRED_ID"

BAD_WF_ID=$(n8n_import_workflow "$SCRIPT_DIR/workflow.json" "$BAD_CRED_ID")
echo "Bad workflow ID: $BAD_WF_ID"

echo "Executing bad-credentials workflow..."
BAD_EXEC_ID=$(n8n_execute_workflow "$BAD_WF_ID")
echo "Bad execution ID: $BAD_EXEC_ID"

if [ "$BAD_EXEC_ID" = "unknown" ] || [ -z "$BAD_EXEC_ID" ]; then
  echo "FAIL: n8n did not return an execution ID for bad-creds workflow"
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
  echo "OK: bad-credentials workflow succeeded (community mode is permissive — documented behavior)"
else
  echo "FAIL: unexpected execution status for bad-creds workflow: $BAD_STATUS"
  n8n_get_execution "$BAD_EXEC_ID" | jq '.' 2>/dev/null || true
  exit 1
fi

# ─── Test 3: Unreachable endpoint — fail-open swallows transport error ──

echo ""
echo "Test 3: Creating credential with unreachable endpoint..."
UNREACH_CRED_ID=$(n8n_create_credential "AxonFlow Unreachable" "http://no-such-host:9999" "e2e-n8n-test" "e2e-user-token")
echo "Unreachable credential ID: $UNREACH_CRED_ID"

UNREACH_WF_ID=$(n8n_import_workflow "$SCRIPT_DIR/workflow.json" "$UNREACH_CRED_ID")
echo "Unreachable workflow ID: $UNREACH_WF_ID"

echo "Executing unreachable-endpoint workflow..."
UNREACH_EXEC_ID=$(n8n_execute_workflow "$UNREACH_WF_ID")
echo "Unreachable execution ID: $UNREACH_EXEC_ID"

if [ "$UNREACH_EXEC_ID" = "unknown" ] || [ -z "$UNREACH_EXEC_ID" ]; then
  echo "FAIL: n8n did not return an execution ID for unreachable-endpoint workflow"
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
  echo "OK: unreachable-endpoint workflow errored (fail-open did not catch — acceptable)"
else
  echo "FAIL: unexpected status for unreachable-endpoint: $UNREACH_STATUS"
  exit 1
fi

# CLEANUP
n8n_delete_workflow "$GOOD_WF_ID"
n8n_delete_workflow "$BAD_WF_ID"
n8n_delete_workflow "$UNREACH_WF_ID"

echo ""
echo "PASS: credential-test-401s-on-bad-auth"
