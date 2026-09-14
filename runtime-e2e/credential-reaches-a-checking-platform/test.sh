#!/usr/bin/env bash
# Test: credential-reaches-a-checking-platform
#
# Drives the REAL n8n CLI (n8n 2.x) with this node installed, against an
# AxonFlow platform that CHECKS credentials (Community SaaS or Enterprise).
# Plain Community admits any credential, so it cannot show whether the node
# authenticates at all; this leg first proves the platform refuses a wrong
# secret, and skips otherwise.
#
# Two one-node workflows (a manual trigger into AxonFlow Check Policy):
#   - no Idempotency Key set: it must execute (the old expression default
#     `{{ $node.name }}` failed every operation on n8n 2.x);
#   - an explicit Idempotency Key: check-input must answer 200, not 401 (the
#     old credential built its header with Buffer, which n8n 2.x blanks).
# The third property, that the secret travels only in the Authorization
# header and never in a body, needs the wire: see README.md.
#
# No mocks or stubs: the real n8n executes the real node against a real stack.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
N8N_BIN="${N8N_BIN:-}"
N8N_NODE_BIN="${N8N_NODE_BIN:-}"                 # a Node.js bin dir for n8n (optional)
N8N_USER_FOLDER_IN="${N8N_USER_FOLDER:-}"        # a prepared n8n user folder with the node installed (optional)
NODE_PACKAGE="${NODE_PACKAGE:-}"                 # a tarball of this package (optional; default: pack this checkout)
ENDPOINT="${AXONFLOW_ENDPOINT:-http://localhost:8080}"
EVIDENCE="${E2E_EVIDENCE_DIR:-$(mktemp -d -t n8n-credential-leg.XXXXXX)}"

PASS=0
FAIL=0
pass() { echo "PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $*"; FAIL=$((FAIL + 1)); }

echo "=== credential-reaches-a-checking-platform ==="
echo "Endpoint: $ENDPOINT"
echo "Evidence: $EVIDENCE"
mkdir -p "$EVIDENCE" || exit 1
for tool in curl jq; do
  command -v "$tool" >/dev/null 2>&1 || { echo "SKIP: $tool not on PATH"; exit 0; }
done
if [ -z "$N8N_BIN" ] || [ ! -x "$N8N_BIN" ]; then
  echo "SKIP: set N8N_BIN to an n8n 2.x CLI"
  exit 0
fi
if ! curl -sSf -o /dev/null --max-time 5 "$ENDPOINT/health"; then
  echo "SKIP: AxonFlow stack not reachable at $ENDPOINT"
  exit 0
fi
[ -n "$N8N_NODE_BIN" ] && export PATH="$N8N_NODE_BIN:$PATH"

# The tenant: a fresh Community SaaS registration, or the given credential.
# The secret is a credential: it is never printed.
CLIENT_ID="${AXONFLOW_E2E_CLIENT_ID:-}"
SECRET="${AXONFLOW_E2E_CLIENT_SECRET:-}"
if [ -z "$CLIENT_ID" ] || [ -z "$SECRET" ]; then
  LABEL="n8n-credential-leg-$(date +%s)-$RANDOM"
  REG=$(curl -s -w '\n%{http_code}' -X POST "$ENDPOINT/api/v1/register" -H 'Content-Type: application/json' \
    -d "{\"label\":\"$LABEL\",\"email\":\"$LABEL@axonflow-test.invalid\"}")
  REG_CODE="${REG##*$'\n'}"
  REG_JSON="${REG%$'\n'*}"
  if [ "$REG_CODE" = "404" ]; then
    echo "SKIP: no credential given and /api/v1/register answered 404; this leg needs a platform that checks credentials"
    exit 0
  fi
  CLIENT_ID=$(printf '%s' "$REG_JSON" | jq -r '.tenant_id // empty')
  SECRET=$(printf '%s' "$REG_JSON" | jq -r '.secret // empty')
  unset REG REG_JSON
  [ -n "$CLIENT_ID" ] && [ -n "$SECRET" ] || { echo "FAIL: registration answered HTTP $REG_CODE without a tenant_id and secret"; exit 1; }
  echo "Registered tenant $CLIENT_ID (the secret is not printed)"
fi

# The platform must refuse a wrong secret, or this leg proves nothing.
WRONG=$(printf '%s:%s' "$CLIENT_ID" "not-the-secret" | base64 | tr -d '\n')
PROBE=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$ENDPOINT/api/v1/mcp/check-input" \
  -H "Authorization: Basic $WRONG" -H 'Content-Type: application/json' \
  -d '{"connector_type":"n8n_leg_probe","statement":"probe","operation":"execute"}')
if [ "$PROBE" != "401" ]; then
  echo "SKIP: this platform answered a wrong secret with HTTP $PROBE, not 401; it does not check credentials"
  exit 0
fi
echo "The platform refuses a wrong secret (HTTP 401)"

# An isolated n8n user folder with this node installed.
if [ -n "$N8N_USER_FOLDER_IN" ]; then
  USER_FOLDER="$N8N_USER_FOLDER_IN"
else
  USER_FOLDER="$EVIDENCE/n8n-home"
  mkdir -p "$USER_FOLDER/.n8n/custom" || exit 1
  if [ -z "$NODE_PACKAGE" ]; then
    (cd "$PLUGIN_DIR" && npm run build >"$EVIDENCE/build.log" 2>&1 && npm pack --pack-destination "$EVIDENCE" >"$EVIDENCE/pack.log" 2>&1) \
      || { echo "FAIL: could not build and pack this checkout (see $EVIDENCE)"; exit 1; }
    NODE_PACKAGE=$(ls "$EVIDENCE"/*.tgz | head -1)
  fi
  (cd "$USER_FOLDER/.n8n/custom" && npm init -y >/dev/null && npm install --no-audit --no-fund --omit=peer "$NODE_PACKAGE" >"$EVIDENCE/install.log" 2>&1) \
    || { echo "FAIL: could not install $NODE_PACKAGE into n8n (see $EVIDENCE/install.log)"; exit 1; }
fi
echo "n8n user folder: $USER_FOLDER"

n8n() {
  env HOME="$USER_FOLDER" N8N_USER_FOLDER="$USER_FOLDER" N8N_DIAGNOSTICS_ENABLED=false \
    N8N_VERSION_NOTIFICATIONS_ENABLED=false N8N_RUNNERS_ENABLED=false N8N_LOG_LEVEL=info \
    "$N8N_BIN" "$@"
}

# The credential: n8n's import reads a file, so the secret is written 0600 for
# the import and removed straight after; n8n stores it encrypted.
TAG="w3y$RANDOM$RANDOM"
CRED_ID="cred$TAG"
CRED_FILE="$EVIDENCE/.credential.json"
( umask 077; jq -n --arg id "$CRED_ID" --arg ep "$ENDPOINT" --arg cid "$CLIENT_ID" --arg sec "$SECRET" \
    '[{id: $id, name: "AxonFlow leg", type: "axonFlowApi", data: {endpoint: $ep, clientId: $cid, userToken: $sec, pepAudience: ""}}]' > "$CRED_FILE" )
unset SECRET
n8n import:credentials --input="$CRED_FILE" > "$EVIDENCE/import-credentials.log" 2>&1
IMPORT_RC=$?
rm -f "$CRED_FILE"
[ "$IMPORT_RC" = 0 ] || { echo "FAIL: n8n import:credentials exited $IMPORT_RC (see $EVIDENCE/import-credentials.log)"; exit 1; }

# run_workflow <label> <extra parameters as JSON>: import and execute a manual
# trigger into one AxonFlow Check Policy node; keeps rc, stdout and stderr.
run_workflow() {
  local label="$1" extra="$2" id="wf$TAG$1"
  jq -n --arg id "$id" --arg cred "$CRED_ID" --argjson extra "$extra" '[{
    id: $id, name: ("leg " + $id), active: false, settings: {},
    connections: {Start: {main: [[{node: "AxonFlow", type: "main", index: 0}]]}},
    nodes: [
      {id: "n-start", name: "Start", type: "n8n-nodes-base.manualTrigger", typeVersion: 1, position: [0, 0], parameters: {}},
      {id: "n-axon", name: "AxonFlow", type: "@axonflow/n8n-nodes-axonflow.axonFlow", typeVersion: 1, position: [220, 0],
       parameters: ({operation: "checkPolicy", connectorType: "postgres", statement: "SELECT name FROM customers LIMIT 5",
                     mcpOperation: "query", failureMode: "closed"} + $extra),
       credentials: {axonFlowApi: {id: $cred, name: "AxonFlow leg"}}}
    ]}]' > "$EVIDENCE/workflow-$label.json"
  n8n import:workflow --input="$EVIDENCE/workflow-$label.json" > "$EVIDENCE/import-$label.log" 2>&1
  n8n execute --id="$id" --rawOutput > "$EVIDENCE/execute-$label.out" 2> "$EVIDENCE/execute-$label.err"
  echo "$?" > "$EVIDENCE/execute-$label.rc"
}

run_workflow default-key '{}'
run_workflow explicit-key '{"idempotencyKey": "n8n-leg-explicit-key"}'

both() { cat "$EVIDENCE/execute-$1.out" "$EVIDENCE/execute-$1.err" 2>/dev/null; }
echo ""
echo "OBSERVED: no Idempotency Key set: exit $(cat "$EVIDENCE/execute-default-key.rc"): $(both default-key | grep -m1 -oE 'ExpressionError[^"]{0,120}|Referenced node[^"]{0,80}|"allowed": ?(true|false)|Authorization failed[^"]{0,80}|Forbidden[^"]{0,60}' || echo '(no marker)')"
echo "OBSERVED: an explicit Idempotency Key: exit $(cat "$EVIDENCE/execute-explicit-key.rc"): $(both explicit-key | grep -m1 -oE '"allowed": ?(true|false)|Authorization failed[^"]{0,80}|401[^"]{0,60}|Forbidden[^"]{0,60}' || echo '(no marker)')"

if [ "$(cat "$EVIDENCE/execute-default-key.rc")" = 0 ] && ! both default-key | grep -q "Referenced node doesn't exist"; then
  pass "a workflow with no Idempotency Key set executes"
else
  fail "a workflow with no Idempotency Key set executes"
fi
if [ "$(cat "$EVIDENCE/execute-explicit-key.rc")" = 0 ] && both explicit-key | grep -qE '"allowed": ?(true|false)' && ! both explicit-key | grep -qE 'Authorization failed|\[401\]'; then
  pass "the credential is accepted: check-input answered with a decision, not a 401"
else
  fail "the credential is accepted: check-input answered with a decision, not a 401"
fi

echo ""
echo "=== credential-reaches-a-checking-platform: $PASS passed, $FAIL failed ==="
echo "Evidence: $EVIDENCE"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
