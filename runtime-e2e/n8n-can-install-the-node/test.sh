#!/usr/bin/env bash
# Test: n8n-can-install-the-node
#
# Verifies that the AxonFlow node package is installed in n8n and that
# n8n recognizes the node type by successfully activating a workflow
# that uses the axonFlow node.
#
# Flow: setup owner -> install node -> create credential -> import workflow
#       -> activate workflow -> if activation succeeds, node is recognized.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$SCRIPT_DIR/../_lib"
N8N_URL="${N8N_URL:-http://localhost:15678}"
export WORK="${WORK:-/tmp}"

source "$LIB_DIR/n8n-api.sh"
n8n_setup_owner
n8n_install_axonflow_node

echo "=== n8n-can-install-the-node ==="

# 1. Create credential
CRED_ID=$(n8n_create_credential "AxonFlow E2E Install" "http://axonflow-agent:8080" "e2e-n8n-test" "e2e-user-token")
echo "Credential ID: $CRED_ID"

# 2. Import workflow that uses the AxonFlow node
WF_ID=$(n8n_import_workflow "$SCRIPT_DIR/workflow.json" "$CRED_ID")
echo "Workflow ID: $WF_ID"

# 3. Activate workflow — this proves n8n recognizes the axonFlow node type.
#    If the node type were missing, activation would fail.
n8n_activate_workflow "$WF_ID"
ACTIVE=$(curl -sf -b "$_N8N_COOKIE_JAR" "$N8N_URL/rest/workflows/$WF_ID" | jq -r '.data.active')
if [ "$ACTIVE" != "true" ]; then
  echo "FAIL: workflow did not activate (active=$ACTIVE) — node type not recognized"
  exit 1
fi
echo "OK: workflow activated — n8n recognizes the axonFlow node type"

# CLEANUP
n8n_delete_workflow "$WF_ID"

echo "PASS: n8n-can-install-the-node"
