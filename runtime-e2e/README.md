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
1. Start the docker compose stack (Postgres + Redis + AxonFlow Agent + AxonFlow Orchestrator + n8n)
2. Build, pack and install THIS checkout into n8n, then assert the installed package's version and the sha256 of its built node file equal the local build (`N8N_NODE_SOURCE=npm` installs the published package instead, for a post-publish smoke; the same assertion then passes only at the published commit)
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
| `check-policy-deny-stops-a-version-1-node` | The same deny through a `typeVersion` 1 node with On Deny unset (every workflow saved before On Deny): the execution ends in error with `AxonFlow denied the request: explicit_constraint (decision <id>)`, and neither IF branch runs |
| `check-policy-deny-is-a-branchable-item` | Through a `typeVersion` 2 node: a statement a shipped control refuses returns HTTP 403, and Check Policy emits `allowed: false` with `block_reason` and `decision_id` as an item; an IF node on `allowed` takes its false branch; exactly one `mcp_query_audits` row |
| `record-decision-writes-audit-row` | Record Decision + Audit Log workflows write audit rows (the credential secret is never sent as their `user_id`) |
| `wait-for-approval-creates-queue-row` | Wait for Approval through n8n, asserted per edition: on Community the error names the edition; on Enterprise the item carries an `approval_id` and the queue holds that row. The operation does not pause a workflow, and this leg does not claim it does |
| `idempotency-retry-does-not-double-record` | Same workflow executed twice with fixed idempotency key creates only 1 row |
| `failure-mode-open-vs-closed` | Fail-open continues with fallback, fail-closed errors on agent down |
| `credential-test-bad-auth-per-edition` | A valid credential yields a decision item; a wrong one is admitted on Community and named as rejected (HTTP 401) on Enterprise; an unresolvable endpoint yields the never-silent Open fallback item with no `allowed` key |
| `credential-reaches-a-checking-platform` | The real n8n 2.x CLI authenticates against a platform that checks credentials, and a workflow with no Idempotency Key executes (runs outside `run-all.sh`: it needs `N8N_BIN` and a credential-checking platform) |

## Architecture

```
docker-compose.yml
  postgres:15-alpine    (port ${POSTGRES_HOST_PORT:-15432})
  redis:7-alpine        (port ${REDIS_HOST_PORT:-16379})
  axonflow-agent        (port ${AGENT_HOST_PORT:-18080}, community mode, image ${AXONFLOW_AGENT_IMAGE})
  axonflow-orchestrator (port ${ORCHESTRATOR_HOST_PORT:-18081}, image ${AXONFLOW_ORCHESTRATOR_IMAGE}; serves /api/v1/audit/tool-call)
  n8n                   (port ${N8N_HOST_PORT:-15678}, n8nio/n8n:2.38.7)

run-all.sh              orchestrator
_lib/
  install-node-into-n8n.sh  npm pack + docker compose cp + install + restart
  execution-node-data.js    one node's item or error from an n8n execution (both data shapes)
  n8n-api.sh                n8n REST API helpers (used by ALL tests)
  verify-db.sh              psql assertion helpers
  setup-n8n.sh              stack startup
  teardown-n8n.sh           stack teardown
```

## Running beside another stack

No service has a `container_name`; the compose project is the stack's identity,
and every script addresses a service through `docker compose -p
"$COMPOSE_PROJECT_NAME"`. The defaults (project `runtime-e2e`, ports 18080,
18081, 15678, 15432, 16379) are what CI uses. On a machine that already runs a stack
on those ports, pick free ports and export everything together, because the
database-asserting legs `psql` whatever `DB_HOST:DB_PORT` names, and a default
left in place reads the other stack's postgres:

```bash
export COMPOSE_PROJECT_NAME=my-n8n-e2e
export AGENT_HOST_PORT=28080 ORCHESTRATOR_HOST_PORT=28081 N8N_HOST_PORT=25678 POSTGRES_HOST_PORT=25432 REDIS_HOST_PORT=26379
export AGENT_URL=http://localhost:28080 N8N_URL=http://localhost:25678
export DB_HOST=localhost DB_PORT=25432 DB_NAME=axonflow DB_USER=axonflow DB_PASSWORD=localdev123
docker compose -p "$COMPOSE_PROJECT_NAME" up -d
./run-all.sh --skip-up
```

Run the legs through `run-all.sh`, or with all of the above exported: a leg run
on its own defaults to the harness ports. The two images are variables too:
`AXONFLOW_AGENT_IMAGE` and `AXONFLOW_ORCHESTRATOR_IMAGE` (defaults
`ghcr.io/getaxonflow/axonflow-agent:latest` and `...-orchestrator:latest`, the
tags `release.yml` builds from the public tree).

**n8n is pinned to `n8nio/n8n:2.38.7`**, the release axonflow-n8n-node#9 was
measured on, so a leg's result does not change with whatever `latest` is on
the day. Move the pin deliberately, and re-run every leg when you do.

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
- `n8n_node_item` / `n8n_node_error` — A named node's first output item, or its error message, from an execution (both of n8n's data shapes; `execution-node-data.js`)
- `n8n_delete_workflow` — Clean up a workflow

## CI Integration

The release workflow (`.github/workflows/release.yml`) runs these tests as a gate before publishing to npm. The `runtime-e2e` job:
1. Brings up the docker compose stack
2. Builds and installs the node
3. Runs all probes
4. Blocks publish if any probe fails
