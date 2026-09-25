# credential-test-bad-auth-per-edition

Drives one Check Policy workflow through n8n's runtime with three credentials
and asserts, per edition (read from the agent's `/health`):

1. **A valid credential.** The execution succeeds and the item is a decision
   (`allowed` is a boolean).
2. **A wrong credential.** Community admits any credential, so the execution
   succeeds with a decision item. Enterprise refuses it: the execution errors
   and the node's error starts `AxonFlow rejected the credential (HTTP 401): `.
3. **An endpoint that does not resolve**, under the default Failure Mode Open:
   the execution succeeds with the fallback item `_axonflow_unreachable: true`,
   `governance: "unavailable"`, `cause: "no_response"`, and no `allowed` key.

Before v11.1.0 this leg was named `credential-test-401s-on-bad-auth` and
accepted either a success or a failure in steps 2 and 3.
