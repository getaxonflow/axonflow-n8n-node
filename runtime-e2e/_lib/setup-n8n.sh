#!/usr/bin/env bash
# setup-n8n.sh — Bring up the docker compose stack and wait for health.
#
# Usage: source this or call directly before running tests.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
E2E_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

log() { echo "$(date -u +%H:%M:%S) [setup-n8n] $*"; }

log "Starting docker compose stack..."
cd "$E2E_DIR"
docker compose up -d 2>&1

log "Waiting for axonflow-agent health..."
for i in $(seq 1 90); do
  if curl -sf -o /dev/null --max-time 2 "http://localhost:18080/health" 2>/dev/null; then
    log "axonflow-agent healthy (${i}s)"
    break
  fi
  if [ "$i" -eq 90 ]; then
    log "FATAL: axonflow-agent not healthy after 90s"
    exit 1
  fi
  sleep 1
done

log "Waiting for n8n health..."
for i in $(seq 1 90); do
  if curl -sf -o /dev/null --max-time 2 "http://localhost:15678/healthz" 2>/dev/null; then
    log "n8n healthy (${i}s)"
    break
  fi
  if [ "$i" -eq 90 ]; then
    log "FATAL: n8n not healthy after 90s"
    exit 1
  fi
  sleep 1
done

log "Stack is up and healthy"
