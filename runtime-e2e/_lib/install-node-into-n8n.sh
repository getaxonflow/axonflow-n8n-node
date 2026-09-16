#!/usr/bin/env bash
# install-node-into-n8n.sh — Pack the node, copy into the n8n container,
# install it, and restart n8n so it picks up the new node type.
#
# Expects: the docker compose stack is running as project $COMPOSE_PROJECT_NAME
# (default runtime-e2e), with n8n reachable at $N8N_URL.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
E2E_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
COMPOSE_PROJECT_NAME="${COMPOSE_PROJECT_NAME:-runtime-e2e}"
N8N_URL="${N8N_URL:-http://localhost:15678}"
compose() { docker compose -p "$COMPOSE_PROJECT_NAME" -f "$E2E_DIR/docker-compose.yml" "$@"; }

log() { echo "$(date -u +%H:%M:%S) [install-node] $*"; }

# 1. Build + pack
log "Building and packing node in $REPO_ROOT ..."
cd "$REPO_ROOT"
npm run build
# Packed into this run's own directory: a shared /tmp name is the same for
# every checkout at one version, so two trees packed at once would clobber.
PACK_DIR="${WORK:-$(mktemp -d)}"
mkdir -p "$PACK_DIR"
TARBALL=$(npm pack --pack-destination "$PACK_DIR" 2>/dev/null | tail -1)
TARBALL_PATH="$PACK_DIR/$TARBALL"

if [ ! -f "$TARBALL_PATH" ]; then
  log "FATAL: npm pack did not produce $TARBALL_PATH"
  exit 1
fi
log "Tarball: $TARBALL_PATH ($(wc -c < "$TARBALL_PATH") bytes)"

# 2. Copy into n8n container
log "Copying tarball into the n8n service of $COMPOSE_PROJECT_NAME..."
compose cp "$TARBALL_PATH" n8n:/tmp/axonflow-node.tgz

# 3. Install into n8n's custom nodes directory
# n8n loads community nodes from ~/.n8n/nodes/node_modules/
log "Installing node package inside n8n container..."
compose exec -T n8n sh -c '
  mkdir -p /home/node/.n8n/nodes
  cd /home/node/.n8n/nodes
  npm init -y 2>/dev/null || true
  # Removed first: at an unchanged version npm can report "up to date" and
  # keep the previous files, which would install an older build of this tree.
  rm -rf node_modules/@axonflow/n8n-nodes-axonflow
  npm install /tmp/axonflow-node.tgz --save --ignore-scripts --omit=peer --no-audit --no-fund 2>&1
'

# 4. Restart n8n to pick up the new node
log "Restarting n8n to load the new node..."
compose restart n8n

# 5. Wait for n8n to be healthy
log "Waiting for n8n to be healthy after restart..."
for i in $(seq 1 60); do
  if curl -sf -o /dev/null --max-time 2 "$N8N_URL/healthz" 2>/dev/null; then
    log "n8n healthy after restart (${i}s)"
    exit 0
  fi
  sleep 1
done

log "FATAL: n8n not healthy after restart"
exit 1
