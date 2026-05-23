# check-policy-operation-hits-axonflow

Verifies the Check Policy operation sends a well-formed request to the AxonFlow
agent's `/api/v1/mcp/check-input` endpoint and receives an allow/deny response.

The test:
1. Creates an AxonFlow credential in n8n pointing to the in-compose agent
2. Imports a workflow that uses the Check Policy operation
3. Verifies the agent is reachable and responds to check-input requests
4. Executes the workflow and checks the execution result
