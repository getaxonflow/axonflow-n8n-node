# check-policy-deny-stops-a-version-1-node

The workflow of `check-policy-deny-is-a-branchable-item`, with the AxonFlow node
at `typeVersion` 1 and On Deny not set: the shape of every workflow saved before
On Deny existed. A deny must still stop it, as a deny always did:

- the execution ends in error;
- the node's error is `AxonFlow denied the request: explicit_constraint (decision <id>)`;
- neither branch of the IF after the node ran.
