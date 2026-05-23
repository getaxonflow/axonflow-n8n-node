# wait-for-approval-pauses-workflow

Verifies that the Wait for Approval operation creates a HITL queue row with
the correct fields including `user_id` (regression for v1.0.0 bug) and
optional `notify_url` (new in v1.0.1).

The test:
1. Creates a HITL queue entry with user_id via the agent API
2. Verifies the HITL row exists in the database with correct severity and user_id
3. Creates a second entry with notify_url and verifies it persists
4. Approves the first request to verify the full lifecycle

In community mode, HITL endpoints may not be available. The test gracefully
handles this case and still passes since the node code paths are verified
by unit tests.
