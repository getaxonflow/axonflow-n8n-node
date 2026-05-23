# idempotency-retry-does-not-double-record

Verifies that sending the same `Idempotency-Key` header twice does not create
a duplicate audit row in the database.

This validates the safety of n8n's built-in "Retry on Fail" feature: when a
workflow step fails and n8n retries, the AxonFlow node sends the same
idempotency key, and the platform deduplicates the request.

The test:
1. POSTs an audit/tool-call with a unique Idempotency-Key
2. POSTs the same request again with the same key (simulating a retry)
3. Verifies exactly 1 audit row was created (not 2)
