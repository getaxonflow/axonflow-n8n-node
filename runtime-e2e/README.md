# Runtime E2E Tests

Real-framework end-to-end tests for `@axonflow/n8n-nodes-axonflow`. These tests install the built node package into a live n8n instance backed by a real AxonFlow Agent, then exercise all four operations end-to-end.

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
| `check-policy-operation-hits-axonflow` | Check Policy calls `/api/v1/mcp/check-input` |
| `record-decision-writes-audit-row` | Record Decision + Audit Log write audit rows with `user_id` |
| `wait-for-approval-pauses-workflow` | Wait for Approval creates HITL queue row with `user_id` + `notify_url` |
| `idempotency-retry-does-not-double-record` | Same Idempotency-Key does not create duplicate rows |
| `failure-mode-open-vs-closed` | Fail-open swallows transport/5xx, rethrows 4xx |
| `credential-test-401s-on-bad-auth` | Credential test endpoint accepts good creds, rejects bad |

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
  n8n-api.sh                n8n REST API helpers
  verify-db.sh              psql assertion helpers
  setup-n8n.sh              stack startup
  teardown-n8n.sh           stack teardown
```

## CI Integration

The release workflow (`.github/workflows/release.yml`) runs these tests as a gate before publishing to npm. The `runtime-e2e` job:
1. Brings up the docker compose stack
2. Builds and installs the node
3. Runs all probes
4. Blocks publish if any probe fails
