# failure-mode-open-vs-closed

Verifies the node's fail-open and fail-closed behavior by executing real n8n
workflows against an AxonFlow agent that is stopped mid-test.

Uses two separate workflows: `workflow-open.json` (failureMode=open) and
`workflow-closed.json` (failureMode=closed).

The test:
1. Phase 1 (agent UP): both fail-open and fail-closed workflows succeed
2. Phase 2 (agent DOWN): fail-open workflow succeeds with `_axonflow_unreachable` fallback
3. Phase 3 (agent DOWN): fail-closed workflow errors (transport error rethrown)
4. Agent is restarted for subsequent tests
