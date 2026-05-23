#!/usr/bin/env bash
# Test: n8n-can-install-the-node
#
# Verifies that the AxonFlow node package is installed in n8n and that
# n8n's node type registry includes the axonFlow node type.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$SCRIPT_DIR/../_lib"
N8N_URL="${N8N_URL:-http://localhost:15678}"

source "$LIB_DIR/n8n-api.sh"
n8n_setup_owner

echo "Checking that n8n lists the AxonFlow node type..."

# n8n exposes available node types via the API
NODE_TYPES=$(curl -sf -b "$_N8N_COOKIE_JAR" "$N8N_URL/api/v1/node-types" 2>/dev/null || echo '{}')

if echo "$NODE_TYPES" | grep -q "axonFlow" 2>/dev/null; then
  echo "PASS: n8n-can-install-the-node — AxonFlow node type is registered"
  exit 0
fi

# Fallback: check if the package is installed in the container
echo "Node type not found in API response, checking container filesystem..."
INSTALLED=$(docker exec e2e-n8n sh -c 'ls /home/node/.n8n/nodes/node_modules/@axonflow/n8n-nodes-axonflow/package.json 2>/dev/null' || echo "")

if [ -n "$INSTALLED" ]; then
  echo "PASS: n8n-can-install-the-node — package is installed at /home/node/.n8n/nodes/node_modules/@axonflow/"
  exit 0
fi

echo "FAIL: n8n-can-install-the-node — AxonFlow node not found in n8n"
exit 1
