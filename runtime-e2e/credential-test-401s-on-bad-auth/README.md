# credential-test-401s-on-bad-auth

Verifies the credential test endpoint behavior by exercising the same
`POST /api/v1/mcp/check-input` request that the `AxonFlowApi.credentials.ts`
test configuration uses.

The test:
1. Valid credentials should return HTTP 200
2. Invalid credentials should return HTTP 401 in enterprise mode (community
   mode returns 200 due to platform permissiveness — documented behavior)
3. Missing auth header behavior
