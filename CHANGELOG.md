# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed

- Audit/decision calls now dual-send `caller_name` (the current client-identity
  field) alongside the deprecated `tool_type` on `POST /api/v1/audit/tool-call`.
  The literal values are unchanged (`n8n_audit` for `auditLog`, `n8n_decision`
  for `recordDecision`). Platforms with `caller_name` support (v9.11.0+) attribute
  from `caller_name`; older platforms continue to read `tool_type` (precedence:
  `caller_name` > `tool_type` > default), so attribution is correct on both.

## [1.0.2] - 2026-05-24

### Fixed (caught by runtime E2E)

- Default `idempotencyKey` template uses `{{ $node.name }}` which fails in
  webhook execution context (`ExpressionError: Referenced node doesn't exist`).
  Workflow examples now use static keys.
- `verify-db.sh` referenced non-existent `tool_name` column in `audit_logs`.
  Fixed to use `mcp_query_audits.connector_name`.

### Added

- Runtime E2E tests rewritten to exercise the real n8n customer entry point:
  workflow import via REST API → activate → webhook trigger → execution status.
  All 7 tests go through n8n's workflow execution. Zero direct curl to AxonFlow.
- `n8n-api.sh` helpers fully wired: `n8n_setup_owner`, `n8n_install_axonflow_node`,
  `n8n_activate_workflow` (POST /activate with versionId for n8n v2.x),
  `n8n_latest_execution`, `n8n_execution_status` (`.data.status` parsing).
- `failure-mode-open-vs-closed`: real `docker stop/start` of AxonFlow agent
  with n8n workflow behavior observed (not just curl transport codes).
- `credential-test-401s-on-bad-auth`: good/bad/unreachable credentials tested
  through real n8n workflow execution.

## [1.0.1] - 2026-05-24

### Fixed (caught by runtime E2E)

- **Record Decision / Audit Log missing `user_id`** — the `recordDecision` and `auditLog` operations did not include `user_id` in the request body sent to `/api/v1/audit/tool-call`. Audit rows were not attributed to the authenticated user. Now sends `user_id` derived from the credential's User Token.
- **Wait for Approval missing `user_id`** — the `waitForApproval` operation did not include `user_id` in the HITL queue creation body. Approval rows lacked user attribution. Now sends `user_id` derived from the credential's User Token.
- **Wait for Approval missing `notify_url` parameter** — the node created HITL approval requests but had no way to set `notify_url`, so the platform could not POST approval decisions back to n8n automatically. Added an optional Notify URL parameter that accepts an n8n Wait node webhook URL for auto-resume on approval or rejection (requires platform >= 8.1.0).

### Added

- **Runtime E2E test suite** (`runtime-e2e/`) — real-framework tests that install the built node package into a live n8n instance backed by a real AxonFlow Agent, then exercise all four operations end-to-end. Six test scenarios: node installation, check-policy, record-decision + audit-row verification, wait-for-approval + HITL queue verification, idempotency-key deduplication, and failure-mode open-vs-closed behavior.
- **Release workflow runtime-e2e gate** — the `release.yml` workflow now runs the runtime E2E suite after build and before npm publish. Releases are blocked if any E2E test fails.

## [1.0.0] - 2026-05-23

First standalone release. Previously shipped as an example inside the AxonFlow platform repository.

### Added

- **Check Policy** operation — `POST /api/v1/mcp/check-input` with branch-on-allowed pattern.
- **Record Decision** operation — `POST /api/v1/audit/tool-call` for success-path recording.
- **Audit Log** operation — same endpoint for error-branch recording with `success: false`.
- **Wait for Approval** operation — `POST /api/v1/hitl/queue` with approval-envelope unwrapping. Pairs with n8n's built-in Wait node for webhook-based resume.
- `AxonFlow API` credential type using Header Auth pattern (not Bearer Auth, which is affected by [n8n#15261](https://github.com/n8n-io/n8n/issues/15261)).
- `Idempotency-Key` header on every operation (default: `executionId-itemIndex-nodeName`) for safe retries.
- Fail-open / fail-closed mode per node instance. Open swallows transport errors and 5xx; 4xx errors (401, 403, 404, 422, 429) always surface.
- Example workflow: `examples/governed-loan-workflow.json` — importable loan-approval flow exercising all four operations.

### Platform compatibility

Requires AxonFlow platform >= 8.1.0 for `notify_url` webhook delivery and `Idempotency-Key` request deduplication. All four operations work on platform >= 7.0.0; HITL resume on older versions requires a polling sidecar or manual webhook trigger.
