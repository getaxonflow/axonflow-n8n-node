# record-decision-writes-audit-row

Verifies that the Record Decision and Audit Log operations send the correct
body to `/api/v1/audit/tool-call` including `user_id` (regression test for
the v1.0.0 bug where `user_id` was missing from these operations).

The test:
1. POSTs a Record Decision (success=true, tool_type=n8n_decision) with user_id
2. POSTs an Audit Log (success=false, tool_type=n8n_audit) with user_id
3. Verifies both audit rows exist in the database
