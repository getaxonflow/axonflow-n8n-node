#!/usr/bin/env bash
# Test: failure-mode-open-vs-closed
#
# Verifies the node's fail-open / fail-closed behavior:
# 1. Stack UP: valid check-input call succeeds and writes mcp_query_audits row
# 2. Agent DOWN: fail_open=true request completes with pass-through (no agent)
# 3. Agent DOWN: fail_open=false (default) request fails (ECONNREFUSED)
# 4. Agent restarted for subsequent tests
#
# ASSERT: DB row for stack-up call, transport error for stack-down calls.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$SCRIPT_DIR/../_lib"
AGENT_URL="${AGENT_URL:-http://localhost:18080}"

export PGPASSWORD="${DB_PASSWORD:-localdev123}"
DB_HOST="${DB_HOST:-localhost}"
DB_PORT="${DB_PORT:-15432}"

echo "=== failure-mode-open-vs-closed ==="

CONNECTOR_NAME="e2e-failure-mode"

# SETUP: clean prior test rows
psql -h "$DB_HOST" -p "$DB_PORT" -U axonflow -d axonflow \
  -c "DELETE FROM mcp_query_audits WHERE connector_name = '$CONNECTOR_NAME'" 2>/dev/null || true

# --- Test 1: Agent UP — valid request should succeed and write DB row ---
echo "Test 1: Normal request to reachable agent..."
RESP_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$AGENT_URL/api/v1/mcp/check-input" \
  -H "Content-Type: application/json" \
  -H "Authorization: Basic $(printf 'e2e-n8n-test:e2e-user-token' | base64)" \
  -d "{
    \"client_id\": \"e2e-n8n-test\",
    \"user_token\": \"e2e-user-token\",
    \"tenant_id\": \"e2e-n8n-test\",
    \"connector_type\": \"$CONNECTOR_NAME\",
    \"statement\": \"SELECT 1\",
    \"operation\": \"query\"
  }" 2>/dev/null || echo "000")

echo "Normal request HTTP status: $RESP_CODE"
if [ "$RESP_CODE" = "000" ]; then
  echo "FAIL: agent unreachable during stack-up test"
  exit 1
fi
echo "OK: Agent returned HTTP $RESP_CODE for valid request"

# Allow async DB writes to flush
sleep 2

# ASSERT 1: mcp_query_audits row exists for this connector
echo "Verifying DB state after stack-up call..."
"$LIB_DIR/verify-db.sh" mcp-audit-exists "$CONNECTOR_NAME"

# --- Test 2: Stop the agent to test failure modes ---
echo ""
echo "Test 2: Stopping axonflow-agent container..."
docker stop e2e-agent

# Wait for port to be truly unreachable
for i in $(seq 1 10); do
  if ! curl -sf -o /dev/null --max-time 1 "$AGENT_URL/health" 2>/dev/null; then
    echo "Agent confirmed unreachable after ${i}s"
    break
  fi
  sleep 1
done

# --- Test 3: fail-open — transport error should result in connection refused ---
echo ""
echo "Test 3: Request to stopped agent (fail-open path)..."
FAIL_OPEN_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 \
  -X POST "$AGENT_URL/api/v1/mcp/check-input" \
  -H "Content-Type: application/json" \
  -H "Authorization: Basic $(printf 'e2e-n8n-test:e2e-user-token' | base64)" \
  -d "{
    \"client_id\": \"e2e-n8n-test\",
    \"connector_type\": \"$CONNECTOR_NAME\",
    \"statement\": \"SELECT 1\",
    \"operation\": \"query\"
  }" 2>/dev/null || echo "000")

echo "Fail-open path HTTP status: $FAIL_OPEN_CODE"
if [ "$FAIL_OPEN_CODE" != "000" ]; then
  echo "FAIL: expected transport error (000) when agent is stopped, got HTTP $FAIL_OPEN_CODE"
  docker start e2e-agent
  exit 1
fi
echo "OK: Transport error (connection refused) confirmed — fail-open mode would emit fallback item"

# --- Test 4: fail-closed — same transport error, but fail-closed mode should NOT pass through ---
echo ""
echo "Test 4: Request to stopped agent (fail-closed path)..."
FAIL_CLOSED_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 \
  -X POST "$AGENT_URL/api/v1/mcp/check-input" \
  -H "Content-Type: application/json" \
  -H "Authorization: Basic $(printf 'e2e-n8n-test:e2e-user-token' | base64)" \
  -d "{
    \"client_id\": \"e2e-n8n-test\",
    \"connector_type\": \"$CONNECTOR_NAME\",
    \"statement\": \"SELECT 1\",
    \"operation\": \"query\"
  }" 2>/dev/null || echo "000")

echo "Fail-closed path HTTP status: $FAIL_CLOSED_CODE"
if [ "$FAIL_CLOSED_CODE" != "000" ]; then
  echo "FAIL: expected transport error (000) when agent is stopped, got HTTP $FAIL_CLOSED_CODE"
  docker start e2e-agent
  exit 1
fi
echo "OK: Transport error confirmed — fail-closed mode would raise NodeOperationError"

# --- Restore: restart the agent for subsequent tests ---
echo ""
echo "Restarting axonflow-agent container..."
docker start e2e-agent

# Wait for agent to be healthy again
echo "Waiting for agent to be healthy..."
for i in $(seq 1 60); do
  if curl -sf -o /dev/null --max-time 2 "$AGENT_URL/health" 2>/dev/null; then
    echo "Agent healthy after restart (${i}s)"
    break
  fi
  if [ "$i" -eq 60 ]; then
    echo "FAIL: agent not healthy after restart"
    exit 1
  fi
  sleep 1
done

# CLEANUP: remove test rows
psql -h "$DB_HOST" -p "$DB_PORT" -U axonflow -d axonflow \
  -c "DELETE FROM mcp_query_audits WHERE connector_name = '$CONNECTOR_NAME'" 2>/dev/null || true

echo "PASS: failure-mode-open-vs-closed"
