# credential-test-401s-on-bad-auth

Verifies credential behavior by creating workflows with different credentials
in n8n and executing them through n8n's runtime.

The test:
1. Good credentials: workflow executes and succeeds through n8n
2. Bad credentials: workflow either fails (enterprise: 401) or succeeds
   (community: permissive mode returns 200 for any creds)
3. Unreachable endpoint: workflow succeeds via fail-open fallback (transport
   error swallowed) with `_axonflow_unreachable` in output
