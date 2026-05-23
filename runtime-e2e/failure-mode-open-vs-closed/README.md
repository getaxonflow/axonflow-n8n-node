# failure-mode-open-vs-closed

Verifies the node's fail-open and fail-closed behavior by testing against
the real AxonFlow agent with various error conditions.

The test:
1. Normal request to reachable agent (should return 200)
2. Bad auth request (should return 401/403, which fail-open must NOT swallow)
3. Transport error to unreachable host (fail-open would emit fallback item)
4. Logic verification against the exhaustive unit test coverage
