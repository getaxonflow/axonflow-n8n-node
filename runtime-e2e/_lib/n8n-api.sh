#!/usr/bin/env bash
# n8n-api.sh — Helper functions for interacting with n8n's REST API.
#
# Source this file from test scripts:
#   source "$LIB_DIR/n8n-api.sh"
#
# Requires: N8N_URL environment variable (default: http://localhost:15678)

N8N_URL="${N8N_URL:-http://localhost:15678}"

# n8n requires an owner account to be set up before the API can be used.
# This function creates the owner if not already set up, then obtains
# an API key (or cookie) for subsequent calls.

_N8N_PASSWORD="E2eTest123!"
_N8N_COOKIE_JAR="${WORK:-/tmp}/.n8n-cookies"

n8n_setup_owner() {
  if [ "${_N8N_SETUP_DONE:-}" = "true" ]; then
    return
  fi

  # Wait for REST API readiness.
  # n8n returns HTTP 200 with "n8n is starting up. Please wait" during init.
  # We must wait until the response is NOT that startup message.
  echo "  waiting for n8n REST API..."
  for i in $(seq 1 90); do
    local body
    body=$(curl -sf "$N8N_URL/rest/login" 2>/dev/null || echo "")
    if [ -n "$body" ] && ! echo "$body" | grep -q "starting up" 2>/dev/null; then
      echo "  n8n REST API ready (${i}s)"
      break
    fi
    if [ "$i" -eq 90 ]; then
      echo "  WARN: n8n REST API not ready after 90s"
    fi
    sleep 1
  done

  # Setup owner — log output so CI failures are diagnosable
  local setup_resp
  setup_resp=$(curl -s -c "$_N8N_COOKIE_JAR" -X POST "$N8N_URL/rest/owner/setup" \
    -H "Content-Type: application/json" \
    -d "{
      \"email\": \"e2e@axonflow.local\",
      \"firstName\": \"E2E\",
      \"lastName\": \"Test\",
      \"password\": \"$_N8N_PASSWORD\"
    }" 2>&1)
  echo "  owner setup: $(echo "$setup_resp" | head -c 200)"

  # Login — setup may also set the cookie but login explicitly
  local login_resp
  login_resp=$(curl -s -c "$_N8N_COOKIE_JAR" -X POST "$N8N_URL/rest/login" \
    -H "Content-Type: application/json" \
    -d "{
      \"emailOrLdapLoginId\": \"e2e@axonflow.local\",
      \"password\": \"$_N8N_PASSWORD\"
    }" 2>&1)
  echo "  login: $(echo "$login_resp" | head -c 200)"

  # Verify cookie was set
  if grep -q "n8n-auth" "$_N8N_COOKIE_JAR" 2>/dev/null; then
    echo "  n8n session established"
  else
    echo "  WARN: no n8n session cookie obtained"
  fi
}

# Create an AxonFlow credential in n8n.
# Args: <name> <endpoint> <client_id> <user_token>
# Returns: credential ID on stdout
n8n_create_credential() {
  local name="$1" endpoint="$2" client_id="$3" user_token="$4"
  local resp
  resp=$(curl -sf -b "$_N8N_COOKIE_JAR" -X POST "$N8N_URL/rest/credentials" \
    -H "Content-Type: application/json" \
    -d "$(cat <<CRED_EOF
{
  "name": "$name",
  "type": "axonFlowApi",
  "data": {
    "endpoint": "$endpoint",
    "clientId": "$client_id",
    "userToken": "$user_token"
  }
}
CRED_EOF
)")
  echo "$resp" | jq -r '.data.id // .id' 2>/dev/null || echo ""
}

# Import a workflow from a JSON file.
# Args: <workflow_json_file> [credential_id]
# Returns: workflow ID on stdout
n8n_import_workflow() {
  local workflow_file="$1"
  local cred_id="${2:-}"

  local workflow_json
  workflow_json=$(cat "$workflow_file")

  # If a credential ID is provided, patch it into the workflow
  if [ -n "$cred_id" ]; then
    workflow_json=$(echo "$workflow_json" | jq --arg cid "$cred_id" '
      .nodes |= map(
        if .credentials?.axonFlowApi then
          .credentials.axonFlowApi.id = $cid
        else . end
      )
    ')
  fi

  local resp
  resp=$(curl -sf -b "$_N8N_COOKIE_JAR" -X POST "$N8N_URL/rest/workflows" \
    -H "Content-Type: application/json" \
    -d "$workflow_json")
  echo "$resp" | jq -r '.data.id // .id' 2>/dev/null || echo ""
}

# Activate a workflow.
# n8n v2.x requires POST /rest/workflows/{id}/activate with versionId.
# Args: <workflow_id>
n8n_activate_workflow() {
  local workflow_id="$1"
  local version_id
  version_id=$(curl -sf -b "$_N8N_COOKIE_JAR" "$N8N_URL/rest/workflows/$workflow_id" 2>/dev/null | jq -r '.data.versionId // ""' 2>/dev/null || echo "" 2>/dev/null || echo "")
  if [ -n "$version_id" ]; then
    curl -s -b "$_N8N_COOKIE_JAR" -X POST "$N8N_URL/rest/workflows/$workflow_id/activate" \
      -H "Content-Type: application/json" \
      -d "{\"versionId\":\"$version_id\"}" > /dev/null 2>&1 || true
  else
    curl -s -b "$_N8N_COOKIE_JAR" -X PATCH "$N8N_URL/rest/workflows/$workflow_id" \
      -H "Content-Type: application/json" \
      -d '{"active": true}' > /dev/null 2>&1 || true
  fi
}

# Execute a workflow via n8n's REST API.
# Args: <workflow_id>
# Returns: execution ID on stdout
n8n_execute_workflow() {
  local workflow_id="$1"
  local resp
  resp=$(curl -sf -X POST \
    "$N8N_URL/rest/workflows/$workflow_id/run" \
    -H "Content-Type: application/json" \
    -d '{}' 2>/dev/null || echo '{}')
  echo "$resp" | jq -r '.data?.executionId // .executionId // "unknown"' 2>/dev/null || echo ""
}

# Trigger a webhook-based workflow.
# Args: <webhook_path> [body_json]
n8n_trigger_webhook() {
  local webhook_path="$1"
  local body="${2:-'{\"test\": true}'}"
  curl -sf -X POST "$N8N_URL/webhook/$webhook_path" \
    -H "Content-Type: application/json" \
    -d "$body"
}

# Get execution result.
# Args: <execution_id>
n8n_get_execution() {
  local execution_id="$1"
  curl -sf -b "$_N8N_COOKIE_JAR" "$N8N_URL/rest/executions/$execution_id" 2>/dev/null || echo '{}'
}

# Get the terminal status of an execution: "success", "error", or "unknown".
# n8n REST API returns .finished=true for completed runs (both success and error),
# and .status="success"|"error"|"waiting"|"running" in newer versions.
# Args: <execution_id>
n8n_execution_status() {
  local execution_id="$1"
  local result
  result=$(n8n_get_execution "$execution_id")

  local status finished stoppedAt
  status=$(echo "$result" | jq -r '.data.status // .status // "unknown"' 2>/dev/null || echo "")
  finished=$(echo "$result" | jq -r '.data.finished // .finished // false' 2>/dev/null || echo "")
  stoppedAt=$(echo "$result" | jq -r '.data.stoppedAt // .stoppedAt // empty' 2>/dev/null || echo "")

  # Prefer .status field (n8n 1.x+)
  if [ "$status" = "success" ] || [ "$status" = "error" ] || [ "$status" = "waiting" ] || [ "$status" = "crashed" ]; then
    echo "$status"
    return
  fi

  # Fallback: .finished + presence of .stoppedAt
  if [ "$finished" = "true" ] && [ -n "$stoppedAt" ]; then
    echo "success"
    return
  fi

  echo "unknown"
}

# Wait for an execution to reach a terminal state (success or error).
# Args: <execution_id> [timeout_seconds]
# Returns 0 if terminal state reached, 1 on timeout.
n8n_wait_execution() {
  local execution_id="$1"
  local timeout="${2:-30}"
  for i in $(seq 1 "$timeout"); do
    local status
    status=$(n8n_execution_status "$execution_id")
    if [ "$status" = "success" ] || [ "$status" = "error" ] || [ "$status" = "crashed" ]; then
      return 0
    fi
    sleep 1
  done
  echo "TIMEOUT: execution $execution_id did not finish in ${timeout}s" >&2
  return 1
}

# Extract the output JSON of a named node from an execution.
# Args: <execution_id> <node_name>
# Returns: the output data JSON on stdout (first item of first output)
n8n_node_output() {
  local execution_id="$1"
  local node_name="$2"
  local result
  result=$(n8n_get_execution "$execution_id")
  echo "$result" | jq -r --arg nn "$node_name" '
    .data.resultData.runData[$nn]
      // [] | .[0].data.main
      // [[]] | .[0]
      // [] | .[0].json
      // {}
  '
}

# Delete a workflow.
# Args: <workflow_id>
n8n_delete_workflow() {
  local workflow_id="$1"
  curl -sf -b "$_N8N_COOKIE_JAR" -X DELETE "$N8N_URL/rest/workflows/$workflow_id" \
    > /dev/null 2>&1 || true
}

# Activate a workflow and trigger it via webhook.
# Args: <workflow_id> <webhook_path> [body_json]
# Returns: nothing (execution happens async; check executions after)
n8n_activate_and_trigger() {
  local workflow_id="$1"
  local webhook_path="$2"
  local body="${3:-'{}'}"

  n8n_activate_workflow "$workflow_id"
  sleep 1
  curl -sf -X POST "$N8N_URL/webhook/$webhook_path" \
    -H "Content-Type: application/json" \
    -d "$body" > /dev/null 2>&1 || true
}

# Get the most recent execution for a workflow.
# Args: <workflow_id>
# Returns: execution ID on stdout
n8n_latest_execution() {
  local workflow_id="$1"
  local resp
  resp=$(curl -sf \
    "$N8N_URL/rest/executions?workflowId=$workflow_id&limit=1" 2>/dev/null || echo '{}')
  echo "$resp" | jq -r '.data.results[0].id // .data[0].id // "unknown"' 2>/dev/null || echo ""
}

# Install the AxonFlow community node from npm (v1.0.0).
# Required because n8n only recognizes community nodes installed
# via the community-packages API, not from tarball file installs.
n8n_install_axonflow_node() {
  if [ "${_N8N_SETUP_DONE:-}" = "true" ]; then
    return
  fi
  # Install from npm with retry (the endpoint may not be ready immediately).
  for i in 1 2 3; do
    local resp
    resp=$(curl -sf -b "$_N8N_COOKIE_JAR" -X POST "$N8N_URL/rest/community-packages" \
      -H "Content-Type: application/json" \
      -d '{"name":"@axonflow/n8n-nodes-axonflow"}' 2>/dev/null || echo "")
    if echo "$resp" | jq -e '.data.installedVersion' > /dev/null 2>&1; then
      local ver
      ver=$(echo "$resp" | jq -r '.data.installedVersion')
      echo "  installed @axonflow/n8n-nodes-axonflow@$ver"
      return 0
    fi
    # Check if already installed (duplicate install returns error)
    local check
    check=$(curl -sf -b "$_N8N_COOKIE_JAR" "$N8N_URL/rest/community-packages" 2>/dev/null || echo "")
    if echo "$check" | jq -e '.data[] | select(.packageName == "@axonflow/n8n-nodes-axonflow")' > /dev/null 2>&1; then
      echo "  @axonflow/n8n-nodes-axonflow already installed"
      return 0
    fi
    sleep 3
  done
  echo "  WARN: could not install @axonflow/n8n-nodes-axonflow after 3 attempts"
}
