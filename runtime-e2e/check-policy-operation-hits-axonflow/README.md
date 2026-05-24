# check-policy-operation-hits-axonflow

Verifies the Check Policy operation end-to-end through n8n's workflow runtime.

The test:
1. Creates an AxonFlow credential in n8n pointing to the in-compose agent
2. Imports the Check Policy workflow via n8n REST API
3. Executes the workflow via `POST /api/v1/workflows/{id}/run`
4. Waits for completion and asserts execution status = success
5. Verifies the `mcp_query_audits` DB row was created by the agent
