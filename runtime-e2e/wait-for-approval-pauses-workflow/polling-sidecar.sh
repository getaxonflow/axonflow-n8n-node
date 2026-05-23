#!/usr/bin/env bash
# polling-sidecar.sh — Polls a HITL approval request and approves it.
#
# Usage: ./polling-sidecar.sh <approval_id> [timeout_seconds]
#
# This simulates an external reviewer approving a HITL request.
# In production, the AxonFlow portal or notify_url webhook handles this.

set -euo pipefail

AGENT_URL="${AGENT_URL:-http://localhost:18080}"
APPROVAL_ID="${1:?usage: polling-sidecar.sh <approval_id>}"
TIMEOUT="${2:-30}"
USER_TOKEN="${USER_TOKEN:-e2e-user-token}"

log() { echo "$(date -u +%H:%M:%S) [sidecar] $*"; }

AUTH="Basic $(printf 'e2e-n8n-test:%s' "$USER_TOKEN" | base64)"

log "Polling HITL request $APPROVAL_ID (timeout ${TIMEOUT}s)..."

for i in $(seq 1 "$TIMEOUT"); do
  STATUS=$(curl -sf "$AGENT_URL/api/v1/hitl/queue/$APPROVAL_ID" \
    -H "Authorization: $AUTH" 2>/dev/null | jq -r '.data.status // .status // "unknown"')

  if [ "$STATUS" = "pending" ]; then
    log "Status is pending — approving..."
    curl -sf -X POST "$AGENT_URL/api/v1/hitl/queue/$APPROVAL_ID/approve" \
      -H "Content-Type: application/json" \
      -H "Authorization: $AUTH" \
      -d '{"reviewer_email": "e2e@axonflow.local", "review_comment": "Auto-approved by E2E sidecar"}' \
      > /dev/null 2>&1
    log "Approved."
    exit 0
  fi

  sleep 1
done

log "TIMEOUT: HITL request $APPROVAL_ID never reached pending status"
exit 1
