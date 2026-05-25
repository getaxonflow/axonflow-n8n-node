#!/usr/bin/env bash
# run-all.sh — n8n community node runtime E2E orchestrator.
#
# Brings up stack, installs the node, runs all probes, tears down.
# Exit non-zero on any failure.
#
# Usage:
#   cd runtime-e2e
#   ./run-all.sh              # full lifecycle (up -> test -> down)
#   ./run-all.sh --no-down    # leave stack running for debugging
#   ./run-all.sh --skip-up    # assume stack is already running

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

LIB_DIR="$SCRIPT_DIR/_lib"

# --- Configuration ---
AGENT_URL="http://localhost:18080"
N8N_URL="http://localhost:15678"
DB_HOST="localhost"
DB_PORT="15432"
DB_NAME="axonflow"
DB_USER="axonflow"
DB_PASSWORD="localdev123"

TEAR_DOWN=true
SKIP_UP=false

for arg in "$@"; do
  case "$arg" in
    --no-down) TEAR_DOWN=false ;;
    --skip-up) SKIP_UP=true ;;
    *) echo "Unknown arg: $arg"; exit 2 ;;
  esac
done

export AGENT_URL N8N_URL DB_HOST DB_PORT DB_NAME DB_USER DB_PASSWORD
export PGPASSWORD="$DB_PASSWORD"

WORK="/tmp/n8n-node-e2e-$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "$WORK"
export WORK

# --- Results tracking ---
PASS=0
FAIL=0
RESULTS=()

record() {
  local probe="$1" status="$2" detail="${3:-}"
  RESULTS+=("$status $probe $detail")
  case "$status" in
    PASS) PASS=$((PASS + 1)) ;;
    FAIL) FAIL=$((FAIL + 1)) ;;
  esac
}

# --- Helpers ---
log() { echo "$(date -u +%H:%M:%S) [run-all] $*"; }

wait_for_health() {
  local url="$1" name="$2" timeout="${3:-90}"
  log "Waiting for $name at $url (timeout ${timeout}s)..."
  for i in $(seq 1 "$timeout"); do
    if curl -sf -o /dev/null --max-time 2 "$url" 2>/dev/null; then
      log "$name healthy after ${i}s"
      return 0
    fi
    sleep 1
  done
  log "FATAL: $name not healthy after ${timeout}s"
  return 1
}

# --- Stack lifecycle ---
stack_up() {
  log "=== Starting E2E stack ==="
  docker compose -f docker-compose.yml up -d 2>&1 | tee "$WORK/stack-up.log"

  wait_for_health "$AGENT_URL/health" "axonflow-agent" 90
  wait_for_health "$N8N_URL/healthz" "n8n" 90

  log "Setting up n8n owner + installing AxonFlow node..."
  source "$LIB_DIR/n8n-api.sh"
  n8n_setup_owner
  n8n_install_axonflow_node
  export _N8N_SETUP_DONE=true
  export _N8N_COOKIE_JAR

  log "Stack ready"
}

stack_down() {
  if [ "$TEAR_DOWN" = "true" ]; then
    log "=== Tearing down E2E stack ==="
    docker compose -f docker-compose.yml down -v 2>&1 | tee "$WORK/stack-down.log"
  else
    log "=== Leaving stack up (--no-down) ==="
  fi
}

# --- Probe runner ---
run_probe() {
  local probe_name="$1"
  local probe_dir="$SCRIPT_DIR/$probe_name"

  log "--- Probe: $probe_name ---"

  if [ ! -d "$probe_dir" ]; then
    log "FAIL: $probe_dir not found — all probes must exist"
    record "$probe_name" FAIL "probe directory missing"
    return 0
  fi

  local test_script="$probe_dir/test.sh"
  if [ ! -f "$test_script" ]; then
    log "FAIL: no test.sh in $probe_dir — all probes must have a test script"
    record "$probe_name" FAIL "test.sh missing"
    return 0
  fi

  chmod +x "$test_script"
  local probe_log="$WORK/${probe_name}.log"
  local probe_exit=0
  bash "$test_script" > "$probe_log" 2>&1 || probe_exit=$?
  cat "$probe_log"
  if [ "$probe_exit" -eq 0 ]; then
    record "$probe_name" PASS
  else
    record "$probe_name" FAIL "exit=$probe_exit see $probe_log"
  fi
}

# --- Main ---
main() {
  log "============================================"
  log "n8n Community Node — Runtime E2E Harness"
  log "============================================"
  log "Workspace: $WORK"
  log ""

  if [ "$SKIP_UP" = "false" ]; then
    trap stack_down EXIT
    stack_up
  else
    # Even with --skip-up, setup owner + install node
    log "Setting up n8n owner + installing AxonFlow node (skip-up mode)..."
    source "$LIB_DIR/n8n-api.sh"
    n8n_setup_owner
    n8n_install_axonflow_node
    # Restart n8n after installing community node so webhook handlers load
    log "Restarting n8n to load installed node..."
    docker restart e2e-n8n > /dev/null 2>&1 || true
    for i in $(seq 1 60); do
      if curl -sf -o /dev/null --max-time 2 "$N8N_URL/healthz" 2>/dev/null; then
        log "n8n restarted (${i}s)"
        break
      fi
      sleep 1
    done
    # Re-login after restart (session cookie invalidated)
    n8n_setup_owner
    export _N8N_SETUP_DONE=true
    export _N8N_COOKIE_JAR
  fi

  run_probe "n8n-can-install-the-node"
  run_probe "check-policy-operation-hits-axonflow"
  run_probe "record-decision-writes-audit-row"
  run_probe "wait-for-approval-pauses-workflow"
  run_probe "idempotency-retry-does-not-double-record"
  run_probe "failure-mode-open-vs-closed"
  run_probe "credential-test-401s-on-bad-auth"

  # --- Summary ---
  log ""
  log "============================================"
  log "RESULTS SUMMARY"
  log "============================================"
  for r in "${RESULTS[@]}"; do
    local status="${r%% *}"
    local rest="${r#* }"
    case "$status" in
      PASS) echo "  [PASS] $rest" ;;
      FAIL) echo "  [FAIL] $rest" ;;
    esac
  done
  log ""
  log "PASS=$PASS FAIL=$FAIL"
  log "Artifacts: $WORK"

  if [ "$FAIL" -gt 0 ]; then
    log "EXIT 1 — $FAIL probe(s) failed"
    exit 1
  fi

  log "EXIT 0 — all probes passed"
  exit 0
}

main
