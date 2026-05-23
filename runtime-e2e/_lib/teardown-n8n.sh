#!/usr/bin/env bash
# teardown-n8n.sh — Tear down the docker compose stack and clean up volumes.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
E2E_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

log() { echo "$(date -u +%H:%M:%S) [teardown] $*"; }

log "Tearing down docker compose stack..."
cd "$E2E_DIR"
docker compose down -v 2>&1

log "Stack torn down"
