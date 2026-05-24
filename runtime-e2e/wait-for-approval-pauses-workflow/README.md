# wait-for-approval-pauses-workflow

Verifies that the Wait for Approval operation executes through n8n's workflow
runtime and correctly calls the AxonFlow HITL endpoint.

HITL endpoints are enterprise-only. In community mode (this test harness), the
agent returns 404 for `/api/v1/hitl/queue`. The node's fail-open mode does NOT
swallow 4xx errors (only transport/5xx), so the workflow finishes with an error.

The test:
1. Creates an AxonFlow credential in n8n
2. Imports the Wait for Approval workflow via n8n REST API
3. Executes the workflow via n8n's REST API
4. Asserts the workflow ran through the AxonFlow node (success in enterprise, error in community)
5. In error case: verifies the error references 404/HITL (not a programming bug)
