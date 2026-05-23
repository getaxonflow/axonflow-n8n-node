#!/usr/bin/env bash
# Test: n8n-can-install-the-node
#
# Verifies that the AxonFlow node package is installed in n8n and that
# n8n's node type registry includes the axonFlow node type.
#
# ASSERT: queries n8n REST API for node types, fails if axonFlow absent.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$SCRIPT_DIR/../_lib"
N8N_URL="${N8N_URL:-http://localhost:15678}"

source "$LIB_DIR/n8n-api.sh"
n8n_setup_owner

echo "Querying n8n node type registry via REST API..."

NODE_TYPES=$(curl -sf -b "$_N8N_COOKIE_JAR" "$N8N_URL/api/v1/node-types" 2>/dev/null)
if [ -z "$NODE_TYPES" ]; then
  echo "FAIL: n8n-can-install-the-node — GET /api/v1/node-types returned empty response"
  exit 1
fi

if echo "$NODE_TYPES" | grep -q "axonFlow" 2>/dev/null; then
  echo "OK: axonFlow node type found in n8n registry"
else
  echo "FAIL: n8n-can-install-the-node — axonFlow not found in node type registry"
  echo "Response (first 500 chars): $(echo "$NODE_TYPES" | head -c 500)"
  exit 1
fi

# Second assertion: verify the package is actually installed on disk inside the container
echo "Verifying package exists on container filesystem..."
INSTALLED=$(docker exec e2e-n8n sh -c 'ls /home/node/.n8n/nodes/node_modules/@axonflow/n8n-nodes-axonflow/package.json 2>/dev/null' || echo "")
if [ -z "$INSTALLED" ]; then
  echo "FAIL: n8n-can-install-the-node — package.json not found at expected container path"
  exit 1
fi
echo "OK: package.json exists at /home/node/.n8n/nodes/node_modules/@axonflow/"

echo "PASS: n8n-can-install-the-node"
