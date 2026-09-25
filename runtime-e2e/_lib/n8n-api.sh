#!/usr/bin/env bash
# n8n-api.sh — Helper functions for interacting with n8n's REST API.
#
# Source this file from test scripts:
#   source "$LIB_DIR/n8n-api.sh"
#
# Requires: N8N_URL environment variable (default: http://localhost:15678)

N8N_URL="${N8N_URL:-http://localhost:15678}"
_N8N_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

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
  # Ready means the REST routes answer: a 2xx, or a 401 (once an owner exists,
  # /rest/login answers 401 to a request with no session, which `curl -f` read
  # as "not ready" for all 90 seconds). A 404 "Cannot GET /rest/login" is n8n's
  # web server up before its routes are registered, and is NOT ready.
  for i in $(seq 1 90); do
    local body code
    body=$(curl -s -w '\n%{http_code}' "$N8N_URL/rest/login" 2>/dev/null || echo "")
    code="${body##*$'\n'}"
    body="${body%$'\n'*}"
    if { [ "${code:0:1}" = "2" ] || [ "$code" = "401" ]; } && ! grep -q "starting up" <<<"$body"; then
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

# One node's first output item as compact JSON, or its error message; empty
# when the node has none. The run data's shape is read in one place,
# execution-node-data.js. Args: <execution_id> <node name>
n8n_node_item() {
  local f="${WORK:-/tmp}/.execution-$1.json"
  n8n_get_execution "$1" > "$f"
  node "$_N8N_LIB_DIR/execution-node-data.js" "$f" "$2" item
}
n8n_node_error() {
  local f="${WORK:-/tmp}/.execution-$1.json"
  n8n_get_execution "$1" > "$f"
  node "$_N8N_LIB_DIR/execution-node-data.js" "$f" "$2" error
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


# Delete a workflow.
# Args: <workflow_id>
n8n_delete_workflow() {
  # n8n 2.x deletes only an archived workflow, and archives only an inactive
  # one; a bare DELETE answers 400 and left every leg's workflow active, so a
  # second run on the same stack collided on its webhook path. Deactivate,
  # archive, delete, and fail if the workflow is still there.
  local workflow_id="$1" code
  curl -s -o /dev/null -b "$_N8N_COOKIE_JAR" -X POST "$N8N_URL/rest/workflows/$workflow_id/deactivate" \
    -H "Content-Type: application/json" -d '{}' 2>/dev/null || true
  curl -s -o /dev/null -b "$_N8N_COOKIE_JAR" -X POST "$N8N_URL/rest/workflows/$workflow_id/archive" \
    -H "Content-Type: application/json" -d '{}' 2>/dev/null || true
  curl -s -o /dev/null -b "$_N8N_COOKIE_JAR" -X DELETE "$N8N_URL/rest/workflows/$workflow_id" 2>/dev/null || true
  code=$(curl -s -o /dev/null -w '%{http_code}' -b "$_N8N_COOKIE_JAR" "$N8N_URL/rest/workflows/$workflow_id" 2>/dev/null || echo 000)
  if [ "$code" != "404" ]; then
    echo "  FAIL: workflow $workflow_id was not deleted (GET answered $code)" >&2
    return 1
  fi
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
  for i in $(seq 1 10); do
    local resp
    resp=$(curl -sf -b "$_N8N_COOKIE_JAR" \
      "$N8N_URL/rest/executions?workflowId=$workflow_id&limit=1" 2>/dev/null || echo '{}')
    local exec_id
    exec_id=$(echo "$resp" | jq -r '.data.results[0].id // .data[0].id // ""' 2>/dev/null || echo "")
    if [ -n "$exec_id" ] && [ "$exec_id" != "null" ]; then
      echo "$exec_id"
      return
    fi
    sleep 1
  done
  echo "unknown"
}

# Install the node under test into the n8n service, then prove that the node
# n8n holds is this checkout's build.
#
# N8N_NODE_SOURCE=checkout (the default) packs THIS repository and installs the
# tarball where a Community Nodes install puts it (install-node-into-n8n.sh).
# N8N_NODE_SOURCE=npm asks n8n to install the PUBLISHED package by name: a
# post-publish smoke. The assertion compares either one with this checkout's
# build, so the npm source passes only at the commit that was published.
#
# This function used to install from npm unconditionally and only warn when
# that failed, so no leg ever exercised an unpublished tree
# (axonflow-n8n-node#9). An install that did not happen, or that installed
# something other than this checkout, now fails the run.
n8n_install_axonflow_node() {
  if [ "${_N8N_SETUP_DONE:-}" = "true" ]; then
    return 0
  fi
  case "${N8N_NODE_SOURCE:-checkout}" in
    checkout)
      bash "$_N8N_LIB_DIR/install-node-into-n8n.sh" || { echo "  FATAL: could not install this checkout into n8n"; return 1; }
      # The install restarts n8n, which ends the session n8n_setup_owner
      # opened; log in again so the caller's next REST call is authenticated.
      n8n_setup_owner
      ;;
    npm)
      _n8n_install_from_registry || return 1
      ;;
    *)
      echo "  FATAL: N8N_NODE_SOURCE must be checkout or npm, got '${N8N_NODE_SOURCE}'"
      return 1
      ;;
  esac
  n8n_assert_installed_node_is_the_checkout
}

# The published package, by name, through n8n's community-packages API.
_n8n_install_from_registry() {
  for i in 1 2 3; do
    local resp
    resp=$(curl -sf -b "$_N8N_COOKIE_JAR" -X POST "$N8N_URL/rest/community-packages" \
      -H "Content-Type: application/json" \
      -d '{"name":"@axonflow/n8n-nodes-axonflow"}' 2>/dev/null || echo "")
    if jq -e '.data.installedVersion' > /dev/null 2>&1 <<<"$resp"; then
      echo "  installed @axonflow/n8n-nodes-axonflow@$(jq -r '.data.installedVersion' <<<"$resp") from the npm registry"
      return 0
    fi
    local check
    check=$(curl -sf -b "$_N8N_COOKIE_JAR" "$N8N_URL/rest/community-packages" 2>/dev/null || echo "")
    if jq -e '.data[] | select(.packageName == "@axonflow/n8n-nodes-axonflow")' > /dev/null 2>&1 <<<"$check"; then
      echo "  @axonflow/n8n-nodes-axonflow already installed"
      return 0
    fi
    sleep 3
  done
  echo "  FATAL: could not install @axonflow/n8n-nodes-axonflow from the npm registry after 3 attempts"
  return 1
}

# Fails unless the package inside the n8n service carries this checkout's
# package.json version AND a byte-identical built node file. The version alone
# would pass a registry copy of the same version built from other code.
n8n_assert_installed_node_is_the_checkout() {
  local root built want_version want_sha got
  root="$(cd "$_N8N_LIB_DIR/../.." && pwd)"
  built="$root/dist/nodes/AxonFlow/AxonFlow.node.js"
  # Always built: a dist left from another commit would compare the installed
  # node with a build that is not this checkout.
  (cd "$root" && npm run build) > "${WORK:-/tmp}/node-build-for-assertion.log" 2>&1 \
    || { echo "  FATAL: could not build this checkout to compare with the installed node"; return 1; }
  want_version=$(jq -r '.version' "$root/package.json")
  want_sha=$(node -e 'process.stdout.write(require("crypto").createHash("sha256").update(require("fs").readFileSync(process.argv[1])).digest("hex"))' "$built")
  got=$(docker compose -p "${COMPOSE_PROJECT_NAME:-runtime-e2e}" -f "$_N8N_LIB_DIR/../docker-compose.yml" exec -T n8n sh -c '
    d=/home/node/.n8n/nodes/node_modules/@axonflow/n8n-nodes-axonflow
    [ -f "$d/package.json" ] && [ -f "$d/dist/nodes/AxonFlow/AxonFlow.node.js" ] || exit 3
    node -e "process.stdout.write(require(process.argv[1]).version)" "$d/package.json"
    printf " "
    sha256sum "$d/dist/nodes/AxonFlow/AxonFlow.node.js" | cut -d" " -f1
  ' 2>&1) || { echo "  FATAL: the n8n service holds no installed @axonflow/n8n-nodes-axonflow ($got)"; return 1; }
  local got_version="${got%% *}" got_sha="${got##* }"
  if [ "$got_version" != "$want_version" ] || [ "$got_sha" != "$want_sha" ]; then
    echo "  FATAL: the node installed in n8n is not this checkout"
    echo "    installed: version $got_version, dist/nodes/AxonFlow/AxonFlow.node.js sha256 $got_sha"
    echo "    checkout:  version $want_version, dist/nodes/AxonFlow/AxonFlow.node.js sha256 $want_sha"
    return 1
  fi
  echo "  installed node is this checkout: version $got_version, dist/nodes/AxonFlow/AxonFlow.node.js sha256 $got_sha"
}
