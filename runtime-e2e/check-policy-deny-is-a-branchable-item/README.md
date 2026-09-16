# check-policy-deny-is-a-branchable-item

A statement a shipped control refuses (`rm -rf / --no-preserve-root`) goes
through Check Policy inside n8n, under Failure Mode Closed, into an IF node on
`{{ $json.allowed }}`. The AxonFlow node is `typeVersion` 2, whose On Deny
default outputs the deny as an item. AxonFlow answers the deny with HTTP 403. The leg asserts
that the deny is an item a workflow branches on:

- the execution succeeds;
- the Check Policy item carries `allowed: false`, `block_reason:
  "explicit_constraint"` and a `decision_id`;
- the IF node took its false branch (`Denied Branch` ran, `Allowed Branch`
  did not);
- the platform recorded exactly one `mcp_query_audits` row for the call.

Before this change the node threw "Forbidden - perhaps check your credentials?"
on this 403 and the workflow stopped (axonflow-n8n-node#9). A version-1 node
still stops, now with the reason named: `check-policy-deny-stops-a-version-1-node`.
