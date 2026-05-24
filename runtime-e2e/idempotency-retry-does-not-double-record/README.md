# idempotency-retry-does-not-double-record

Verifies that executing the same workflow twice with a fixed Idempotency-Key
does not create duplicate audit rows in the database.

This validates the safety of n8n's built-in "Retry on Fail" feature: when a
workflow step fails and n8n retries, the AxonFlow node sends the same
idempotency key, and the platform deduplicates the request.

The test:
1. Imports a workflow with a fixed idempotency key ("e2e-fixed-idem-key")
2. Executes the workflow twice via n8n REST API (simulating a retry)
3. Verifies exactly 1 audit row was created (not 2)
4. Verifies the idempotency key row exists in the DB
