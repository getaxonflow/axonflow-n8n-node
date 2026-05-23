#!/usr/bin/env bash
# verify-db.sh — Assertion queries against the AxonFlow platform DB.
#
# Usage:
#   ./verify-db.sh audit-row-exists <tool_name>
#   ./verify-db.sh audit-row-has-user-id <tool_name> <expected_user_id>
#   ./verify-db.sh audit-row-count <tool_name> <expected>
#   ./verify-db.sh hitl-row <approval_id>
#   ./verify-db.sh hitl-count <expected_minimum>
#   ./verify-db.sh hitl-field <approval_id> <field> <expected>
#   ./verify-db.sh idempotency-row <key>
#   ./verify-db.sh idempotency-count <key> <expected>
#   ./verify-db.sh mcp-audit-exists <connector_name>
#   ./verify-db.sh audit-log-exists <client_id>
#
# Environment:
#   DB_HOST (default: localhost)
#   DB_PORT (default: 15432)
#   DB_NAME (default: axonflow)
#   DB_USER (default: axonflow)
#   DB_PASSWORD (default: localdev123)

set -euo pipefail

DB_HOST="${DB_HOST:-localhost}"
DB_PORT="${DB_PORT:-15432}"
DB_NAME="${DB_NAME:-axonflow}"
DB_USER="${DB_USER:-axonflow}"
DB_PASSWORD="${DB_PASSWORD:-localdev123}"

export PGPASSWORD="$DB_PASSWORD"

psql_q() {
  psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -t -A "$@"
}

validate_safe_string() {
  local val="$1" label="$2"
  if [[ "$val" =~ [\'] ]] || [[ "$val" =~ \; ]] || [[ "$val" =~ -- ]]; then
    echo "ABORT: invalid $label — contains disallowed characters" >&2
    exit 2
  fi
}

case "${1:-}" in
  audit-row-exists)
    tool_name="${2:?usage: verify-db.sh audit-row-exists <tool_name>}"
    validate_safe_string "$tool_name" "tool_name"
    count=$(psql_q -c "SELECT COUNT(*) FROM audit_tool_calls WHERE tool_name = '$tool_name'")
    if [ "$count" -lt 1 ]; then
      echo "FAIL: no audit row found for tool_name=$tool_name"
      exit 1
    fi
    echo "OK: $count audit row(s) for tool_name=$tool_name"
    exit 0
    ;;

  audit-row-has-user-id)
    tool_name="${2:?usage: verify-db.sh audit-row-has-user-id <tool_name> <expected_user_id>}"
    expected_user_id="${3:?}"
    validate_safe_string "$tool_name" "tool_name"
    validate_safe_string "$expected_user_id" "expected_user_id"
    actual=$(psql_q -c "SELECT user_id FROM audit_tool_calls WHERE tool_name = '$tool_name' LIMIT 1")
    if [ "$actual" != "$expected_user_id" ]; then
      echo "FAIL: user_id='$actual' (expected '$expected_user_id') for tool_name=$tool_name"
      exit 1
    fi
    echo "OK: user_id='$actual' matches expected for tool_name=$tool_name"
    exit 0
    ;;

  audit-row-count)
    tool_name="${2:?usage: verify-db.sh audit-row-count <tool_name> <expected>}"
    expected="${3:?}"
    validate_safe_string "$tool_name" "tool_name"
    count=$(psql_q -c "SELECT COUNT(*) FROM audit_tool_calls WHERE tool_name = '$tool_name'")
    if [ "$count" -ne "$expected" ]; then
      echo "FAIL: audit_tool_calls has $count rows for tool_name=$tool_name (expected $expected)"
      exit 1
    fi
    echo "OK: audit_tool_calls has $count row(s) for tool_name=$tool_name"
    exit 0
    ;;

  hitl-row)
    approval_id="${2:?usage: verify-db.sh hitl-row <approval_id>}"
    validate_safe_string "$approval_id" "approval_id"
    row=$(psql_q -c "SELECT row_to_json(t) FROM (
      SELECT request_id, client_id, user_id, original_query, request_type,
             status, severity
      FROM hitl_approval_queue WHERE request_id = '$approval_id'
    ) t")
    if [ -z "$row" ]; then
      echo "FAIL: no row found for request_id=$approval_id"
      exit 1
    fi
    echo "$row"
    exit 0
    ;;

  hitl-count)
    expected="${2:?usage: verify-db.sh hitl-count <expected_minimum>}"
    if ! [[ "$expected" =~ ^[0-9]+$ ]]; then
      echo "ABORT: expected must be a number" >&2
      exit 2
    fi
    count=$(psql_q -c "SELECT COUNT(*) FROM hitl_approval_queue")
    if [ "$count" -lt "$expected" ]; then
      echo "FAIL: hitl_approval_queue has $count rows (expected >= $expected)"
      exit 1
    fi
    echo "OK: hitl_approval_queue has $count rows (>= $expected)"
    exit 0
    ;;

  hitl-field)
    approval_id="${2:?usage: verify-db.sh hitl-field <approval_id> <field> <expected>}"
    field="${3:?}"
    expected="${4:?}"
    validate_safe_string "$approval_id" "approval_id"
    validate_safe_string "$field" "field"
    actual=$(psql_q -c "SELECT $field FROM hitl_approval_queue WHERE request_id = '$approval_id'")
    if [ "$actual" != "$expected" ]; then
      echo "FAIL: $field='$actual' (expected '$expected') for request_id=$approval_id"
      exit 1
    fi
    echo "OK: $field='$actual' matches expected"
    exit 0
    ;;

  idempotency-row)
    key="${2:?usage: verify-db.sh idempotency-row <key>}"
    validate_safe_string "$key" "key"
    row=$(psql_q -c "SELECT row_to_json(t) FROM (
      SELECT key, tenant_id, endpoint, status_code, created_at
      FROM idempotency_keys WHERE key = '$key'
    ) t")
    if [ -z "$row" ]; then
      echo "FAIL: no idempotency row for key=$key"
      exit 1
    fi
    echo "$row"
    exit 0
    ;;

  idempotency-count)
    key="${2:?usage: verify-db.sh idempotency-count <key> <expected>}"
    expected="${3:?}"
    validate_safe_string "$key" "key"
    count=$(psql_q -c "SELECT COUNT(*) FROM idempotency_keys WHERE key = '$key'")
    if [ "$count" -ne "$expected" ]; then
      echo "FAIL: idempotency_keys has $count rows for key=$key (expected $expected)"
      exit 1
    fi
    echo "OK: idempotency_keys has $count row(s) for key=$key"
    exit 0
    ;;

  mcp-audit-exists)
    connector_name="${2:?usage: verify-db.sh mcp-audit-exists <connector_name>}"
    validate_safe_string "$connector_name" "connector_name"
    count=$(psql_q -c "SELECT COUNT(*) FROM mcp_query_audits WHERE connector_name = '$connector_name'")
    if [ "$count" -eq 0 ]; then
      echo "FAIL: no mcp_query_audits row for connector=$connector_name"
      exit 1
    fi
    echo "OK: mcp_query_audits has $count row(s) for connector=$connector_name"
    exit 0
    ;;

  audit-log-exists)
    client_id="${2:?usage: verify-db.sh audit-log-exists <client_id>}"
    validate_safe_string "$client_id" "client_id"
    count=$(psql_q -c "SELECT COUNT(*) FROM audit_logs WHERE client_id = '$client_id'")
    if [ "$count" -eq 0 ]; then
      echo "FAIL: no audit_logs row for client=$client_id"
      exit 1
    fi
    echo "OK: audit_logs has $count row(s) for client=$client_id"
    exit 0
    ;;

  *)
    echo "Usage: $0 {audit-row-exists|audit-row-has-user-id|audit-row-count|hitl-row|hitl-count|hitl-field|idempotency-row|idempotency-count|mcp-audit-exists|audit-log-exists} ..."
    exit 2
    ;;
esac
