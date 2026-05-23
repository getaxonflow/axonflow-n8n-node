# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
