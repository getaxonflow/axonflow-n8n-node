#!/usr/bin/env bash
# install-node-into-n8n.sh — Pack the node, copy into the n8n container,
# install it, and restart n8n so it picks up the new node type.
#
# Expects: docker compose stack is running with container named e2e-n8n.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

log() { echo "$(date -u +%H:%M:%S) [install-node] $*"; }

# 1. Build + pack
log "Building and packing node in $REPO_ROOT ..."
cd "$REPO_ROOT"
npm run build
TARBALL=$(npm pack --pack-destination /tmp 2>/dev/null | tail -1)
TARBALL_PATH="/tmp/$TARBALL"

if [ ! -f "$TARBALL_PATH" ]; then
  log "FATAL: npm pack did not produce $TARBALL_PATH"
  exit 1
fi
log "Tarball: $TARBALL_PATH ($(wc -c < "$TARBALL_PATH") bytes)"

# 2. Copy into n8n container
log "Copying tarball into e2e-n8n container..."
docker cp "$TARBALL_PATH" e2e-n8n:/tmp/axonflow-node.tgz

# 3. Install into n8n's custom nodes directory
# n8n loads community nodes from ~/.n8n/nodes/node_modules/
log "Installing node package inside n8n container..."
docker exec e2e-n8n sh -c '
  mkdir -p /home/node/.n8n/nodes
  cd /home/node/.n8n/nodes
  npm init -y 2>/dev/null || true
  npm install /tmp/axonflow-node.tgz --save --ignore-scripts 2>&1
'

# 4. Restart n8n to pick up the new node
log "Restarting n8n to load the new node..."
docker restart e2e-n8n

# 5. Wait for n8n to be healthy
log "Waiting for n8n to be healthy after restart..."
for i in $(seq 1 60); do
  if curl -sf -o /dev/null --max-time 2 "http://localhost:15678/healthz" 2>/dev/null; then
    log "n8n healthy after restart (${i}s)"
    exit 0
  fi
  sleep 1
done

log "FATAL: n8n not healthy after restart"
exit 1
