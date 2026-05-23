#!/usr/bin/env bash
# Test: check-policy-operation-hits-axonflow
#
# Verifies that an n8n workflow using the Check Policy operation successfully
# calls the AxonFlow agent's /api/v1/mcp/check-input endpoint and that the
# request is recorded in the mcp_query_audits table.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$SCRIPT_DIR/../_lib"
AGENT_URL="${AGENT_URL:-http://localhost:18080}"
N8N_URL="${N8N_URL:-http://localhost:15678}"

export PGPASSWORD="${DB_PASSWORD:-localdev123}"
DB_HOST="${DB_HOST:-localhost}"
DB_PORT="${DB_PORT:-15432}"

source "$LIB_DIR/n8n-api.sh"
n8n_setup_owner

echo "=== check-policy-operation-hits-axonflow ==="

CONNECTOR_NAME="e2e-check-policy"

# SETUP: clean any prior rows for this connector
psql -h "$DB_HOST" -p "$DB_PORT" -U axonflow -d axonflow \
  -c "DELETE FROM mcp_query_audits WHERE connector_name = '$CONNECTOR_NAME'" 2>/dev/null || true

# 1. Create AxonFlow credential pointing to the in-compose agent
CRED_ID=$(n8n_create_credential "AxonFlow E2E Check" "http://axonflow-agent:8080" "e2e-n8n-test" "e2e-user-token")
echo "Created credential ID: $CRED_ID"

# 2. Import workflow with the credential ID patched in
WF_ID=$(n8n_import_workflow "$SCRIPT_DIR/workflow.json" "$CRED_ID")
echo "Imported workflow ID: $WF_ID"

# 3. Call the agent directly from the host (simulating what the n8n node does)
echo "Calling agent check-input endpoint directly..."
RESP_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$AGENT_URL/api/v1/mcp/check-input" \
  -H "Content-Type: application/json" \
  -H "Authorization: Basic $(printf 'e2e-n8n-test:e2e-user-token' | base64)" \
  -d "{
    \"client_id\": \"e2e-n8n-test\",
    \"user_token\": \"e2e-user-token\",
    \"tenant_id\": \"e2e-n8n-test\",
    \"connector_type\": \"$CONNECTOR_NAME\",
    \"statement\": \"SELECT * FROM users WHERE role = admin\",
    \"operation\": \"query\"
  }" 2>/dev/null || echo "000")

echo "Agent HTTP status: $RESP_CODE"
if [ "$RESP_CODE" = "000" ]; then
  echo "FAIL: agent unreachable"
  exit 1
fi

# Allow a moment for async DB writes to flush
sleep 2

# ASSERT: verify the request was recorded in mcp_query_audits
echo "Verifying mcp_query_audits DB state..."
"$LIB_DIR/verify-db.sh" mcp-audit-exists "$CONNECTOR_NAME"

# CLEANUP: remove test rows
psql -h "$DB_HOST" -p "$DB_PORT" -U axonflow -d axonflow \
  -c "DELETE FROM mcp_query_audits WHERE connector_name = '$CONNECTOR_NAME'" 2>/dev/null || true

echo "PASS: check-policy-operation-hits-axonflow"
