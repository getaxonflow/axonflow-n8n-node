# record-decision-writes-audit-row

Verifies that the Record Decision and Audit Log operations write audit rows
with correct `user_id` through n8n's workflow runtime.

The test:
1. Creates an AxonFlow credential in n8n
2. Imports and executes the Record Decision workflow (success=true, tool_type=n8n_decision)
3. Imports and executes the Audit Log workflow (success=false, tool_type=n8n_audit)
4. Asserts both workflow executions succeeded
5. Verifies both audit rows exist in the database
6. Verifies user_id attribution is correct
