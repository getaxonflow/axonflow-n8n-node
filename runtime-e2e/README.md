# Runtime E2E Tests

Real-framework end-to-end tests for `@axonflow/n8n-nodes-axonflow`. These tests install the built node package into a live n8n instance backed by a real AxonFlow Agent, then exercise all four operations end-to-end **through n8n's workflow execution runtime** (not direct curl against AxonFlow).

Every test follows the same pattern:
1. Create an AxonFlow credential in n8n via REST API
2. Import a workflow JSON via `POST /api/v1/workflows`
3. Execute the workflow via `POST /api/v1/workflows/{id}/run`
4. Wait for completion via `GET /api/v1/executions/{id}`
5. Assert execution status and verify DB state

## Prerequisites

- Docker and Docker Compose
- Node.js >= 18
- `npm`, `curl`, `jq`, `psql` (for DB verification)

## Quick Start

```bash
cd runtime-e2e
./run-all.sh
```

This will:
1. Start the docker compose stack (Postgres + Redis + AxonFlow Agent + n8n)
2. Build and install the node package into n8n
3. Run all test probes
4. Tear down the stack
5. Print a summary

Use `--no-down` to leave the stack running for debugging:
```bash
./run-all.sh --no-down
```

## Test Probes

| Probe | What it tests |
|-------|--------------|
| `n8n-can-install-the-node` | Package installs into n8n and node type is registered |
| `check-policy-operation-hits-axonflow` | Check Policy workflow executes through n8n, writes `mcp_query_audits` row |
| `record-decision-writes-audit-row` | Record Decision + Audit Log workflows write audit rows with `user_id` |
| `wait-for-approval-pauses-workflow` | Wait for Approval workflow calls HITL endpoint through n8n |
| `idempotency-retry-does-not-double-record` | Same workflow executed twice with fixed idempotency key creates only 1 row |
| `failure-mode-open-vs-closed` | Fail-open continues with fallback, fail-closed errors on agent down |
| `credential-test-401s-on-bad-auth` | Good/bad/unreachable credentials behave correctly through n8n |

## Architecture

```
docker-compose.yml
  postgres:15-alpine    (port 15432)
  redis:7-alpine        (port 16379)
  axonflow-agent        (port 18080, community mode)
  n8n                   (port 15678)

run-all.sh              orchestrator
_lib/
  install-node-into-n8n.sh  npm pack + docker cp + install + restart
  n8n-api.sh                n8n REST API helpers (used by ALL tests)
  verify-db.sh              psql assertion helpers
  setup-n8n.sh              stack startup
  teardown-n8n.sh           stack teardown
```

## n8n API Helpers

`_lib/n8n-api.sh` provides helpers that every test uses:

- `n8n_setup_owner` — Create/login the n8n owner account
- `n8n_create_credential` — Create an AxonFlow credential via REST API
- `n8n_import_workflow` — Import a workflow JSON, patching the credential ID
- `n8n_activate_workflow` — Activate a workflow
- `n8n_execute_workflow` — Execute a workflow and return the execution ID
- `n8n_wait_execution` — Poll until execution reaches a terminal state
- `n8n_execution_status` — Get the terminal status (success/error/unknown)
- `n8n_get_execution` — Get full execution details
- `n8n_node_output` — Extract a named node's output from an execution
- `n8n_delete_workflow` — Clean up a workflow

## CI Integration

The release workflow (`.github/workflows/release.yml`) runs these tests as a gate before publishing to npm. The `runtime-e2e` job:
1. Brings up the docker compose stack
2. Builds and installs the node
3. Runs all probes
4. Blocks publish if any probe fails
