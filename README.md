# n8n-nodes-axonflow

AxonFlow API integration for [n8n](https://n8n.io). Call the AxonFlow policy and HITL endpoints directly from your n8n workflows.

[![npm version](https://img.shields.io/npm/v/@axonflow/n8n-nodes-axonflow)](https://www.npmjs.com/package/@axonflow/n8n-nodes-axonflow)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

## What it does

This package contributes a single `AxonFlow` node with four operations against an AxonFlow Agent:

| Operation | Endpoint | When to use |
|---|---|---|
| **Check Policy** | `POST /api/v1/mcp/check-input` | Before a workflow takes a sensitive action — receive `{allowed, block_reason?}` and branch on it. A deny is an item with `allowed: false`, not an error; see **What the node emits** below. On a redact-not-block allow it also returns the masked text; see **Redaction: your workflow must use the masked text** below. |
| **Record Decision** | `POST /api/v1/audit/tool-call` | After a successful action — capture inputs, outputs, policies applied. |
| **Audit Log** | `POST /api/v1/audit/tool-call` | From error branches — record the failed action with `success: false` and `error_message`. |
| **Wait for Approval** | `POST /api/v1/hitl/queue` | AxonFlow Enterprise only. Creates an approval request and returns at once with its `approval_id`; it does not pause the workflow. Pair it with an n8n Wait node to pause. |

Plus a single `AxonFlow API` credential type holding the endpoint + Basic-auth (`clientId` + `userToken`).

## What the node emits

The node reads the platform's HTTP status **and** its response body, and decides in one place what they mean.

| AxonFlow answers | Check Policy emits | Any other operation |
|---|---|---|
| 2xx | the response body as the item, unchanged | the response body (Wait for Approval: `approval_id`, `status`, `expires_at`) |
| 403 with `allowed: false` (a policy deny) | the response body as the item: `allowed: false`, `block_reason`, `decision_id`, `policy_matches` | an error quoting the platform |
| 401 | an error: `AxonFlow rejected the credential (HTTP 401): <platform text>. Check the Client ID and User Token ...` | the same |
| 402 | an error: `AxonFlow refused the request: a tier limit of this deployment was reached (HTTP 402): <platform text>` | the same |
| 429 | an error: `AxonFlow refused the request: a rate limit was reached (HTTP 429, limit_type "...", resets at ..., retry after N s): <platform text>`, with each detail only when the platform sends it | the same |
| 404 | an error quoting the platform | Wait for Approval: `AxonFlow has no approval queue at this endpoint (HTTP 404): /api/v1/hitl/queue is served by AxonFlow Enterprise only ...` |
| any other 4xx, including a 403 without `allowed: false` | an error: `AxonFlow refused the request (HTTP <status>): <platform text>` | the same |
| 5xx, or no answer | **Failure Mode: Open** (the default): an item `{_axonflow_unreachable: true, governance: "unavailable", cause: "http_503" or "no_response", error, operation}`. **Closed**: an error. | the same |

Every error is rethrown under both failure modes; only a 5xx or no answer is swallowed by **Open**. So n8n's **Retry On Fail** sees a 429, and **Continue On Fail** turns an error into an item with `error`.

**Branch on `allowed`.** A deny, including one whose `block_reason` starts `unknown_constraint;` (a policy needs an attribute the request did not carry, and the rest of the text names the policy and the attribute) or `approval_required:`, arrives as an item with `allowed: false`, so an IF node on `{{ $json.allowed }}` takes its false branch and can read `block_reason`.

**The Open fallback item has no `allowed` key, on purpose.** An IF on `{{ $json.allowed }} is true` does not take its true branch during an outage; check `{{ $json.governance }}` if the workflow should treat "AxonFlow did not decide" differently from a deny.

**Approvals on AxonFlow v11.** On the planes this node calls, a policy that requires approval does not hold the request: Check Policy answers a deny whose `block_reason` starts `approval_required`. Holding for a reviewer happens on AxonFlow's workflow and multi-agent planes, not here. Wait for Approval creates an approval request on AxonFlow Enterprise and returns immediately; on Community the route does not exist and the node says so.

## Redaction: your workflow must use the masked text

**Check Policy can allow an action and still require that you change it.** When
the statement you submitted carried sensitive data under a redact-not-block
policy, AxonFlow allows the call and returns the masked version alongside it:

```json
{
  "allowed": true,
  "redacted": true,
  "redaction_evaluated": true,
  "redacted_statement": "transfer to [REDACTED]"
}
```

**This node passes those fields through to your workflow unchanged, and does
nothing else with them.** It does not rewrite the action, and it cannot: the
node has no way to know which of your downstream parameters the statement came
from. Applying the redaction is your workflow's job.

**So when `redacted_statement` is present, use it in place of the original.** A
workflow that branches only on `allowed` will proceed with the unmasked text,
and the platform's audit record will show a redaction that your workflow did not
apply.

Two rules worth building in:

- **Treat `redaction_evaluated` as the trust signal.** When it is absent or
  false the redaction detector did not run, so "no masked text" means "nothing
  looked", not "nothing found". Fail closed there rather than proceeding.
- **AxonFlow will not redact for you.** Substituting the masked text it returns
  is the sanctioned way to satisfy a redaction policy; masking the text yourself
  is not, because your patterns and the platform's will disagree.

This applies on every AxonFlow edition. On Community the call is allowed and
recorded either way, so **this paragraph is the control** - nothing downstream
will stop an unmasked value for you. On Enterprise the platform can additionally
refuse a call whose enforcement point has declared it cannot apply a redaction;
this node declares exactly that, honestly, because it performs no substitution
of its own.

## Install

### n8n GUI (self-hosted)

1. **Settings > Community Nodes > Install.**
2. npm package name: `@axonflow/n8n-nodes-axonflow`.
3. Restart n8n.

### Manual (self-hosted)

```bash
cd ~/.n8n/custom
npm install @axonflow/n8n-nodes-axonflow
# restart n8n
```

A node installed under `~/.n8n/custom` registers as `CUSTOM.axonFlow`, not `@axonflow/n8n-nodes-axonflow.axonFlow`, so the shipped example workflow (which names the GUI install's type) cannot find it. Import a copy with the type rewritten:

```bash
sed 's/"@axonflow\/n8n-nodes-axonflow\.axonFlow"/"CUSTOM.axonFlow"/' examples/governed-loan-workflow.json > governed-loan-workflow.custom.json
```

Installing into `~/.n8n/nodes` (`cd ~/.n8n/nodes && npm install @axonflow/n8n-nodes-axonflow`) keeps the package type, like the GUI install.

> n8n Cloud does not currently allow unverified community nodes. Use the [stock-HTTP-node recipe](https://docs.getaxonflow.com/docs/integration/n8n/) on n8n Cloud until this package is verified.

## Configure the credential

**Credentials > New > AxonFlow API.**

| Field | Description |
|---|---|
| Endpoint | Base URL of your AxonFlow Agent. SaaS: `https://try.getaxonflow.com`. Self-hosted: typically port 8080. |
| Client ID | Your tenant identifier. |
| User Token | Sent as the password half of HTTP Basic auth. Stored encrypted in n8n. |

## Quickstart

1. Install the community node (see above).
2. Create an **AxonFlow API** credential with your endpoint + Client ID + User Token.
3. Add an **AxonFlow** node to your workflow.
4. Pick an operation:
   - **Check Policy** — submit a proposed action and branch on `allowed: true/false`.
   - **Record Decision** — log the outcome of a downstream action.
   - **Audit Log** — log a failed action from an error branch.
   - **Wait for Approval** — create a HITL request (AxonFlow Enterprise); it returns at once, so pair it with a Wait node to pause.
5. Run the workflow.

## Three things to know

1. **Bearer Auth > Header Auth.** This credential uses the Header Auth pattern (Authorization built inline) rather than n8n's built-in Bearer Auth class, which silently drops the header in some n8n versions ([n8n#15261](https://github.com/n8n-io/n8n/issues/15261)).
2. **Idempotency by default.** Every operation sends `Idempotency-Key: {executionId}-{itemIndex}-{nodeName}` so n8n's `Retry on Fail` doesn't double-record. AxonFlow accepts only the characters `A-Z a-z 0-9 _ . : - /` in a key, up to 256 of them, so in the default key each other character of the node name becomes `_` and a short hash of the original name is appended (a name already inside that set is used as it is). Override at the node parameter level if you need a domain-specific key; a key you set is sent exactly as you wrote it, so keeping it inside that set is up to you, and AxonFlow refuses one outside it with HTTP 400, which the node quotes.
3. **HITL pairs with the Wait node.** `Wait for Approval` creates the AxonFlow approval entry (Enterprise) and returns immediately; it does not pause anything itself. Pair it with a downstream Wait node configured for **On Webhook Call** mode, which is what pauses the workflow. As of platform v8.1.0+, pass the Wait node's webhook URL as `notify_url` in the HITL queue request and AxonFlow will POST to it automatically on approval/rejection — no polling sidecar needed. For self-hosted deployments on v8.0.x, two manual paths work: (a) run a small **polling sidecar** that watches `GET /api/v1/hitl/queue/{id}` and POSTs to the Wait node's webhook URL when status changes, or (b) have a reviewer trigger the resume URL manually from the portal. See the [n8n integration docs](https://docs.getaxonflow.com/docs/integration/n8n/#hitl) for details.

## Client identification

Every call this node makes to AxonFlow carries `X-Axonflow-Client: n8n-plugin/<version>`, set once on the credential so it rides every operation. The version is read from this package's own metadata.

**What this is and is not.** It is attribution on a request the platform already receives — no additional request is made, and **this node sends no heartbeat or telemetry ping of its own**. It is never used for authentication: the platform authenticates on the `Authorization` header, so a missing or mangled value cannot fail a call. Nothing about your workflow data, statements, parameters, or identity is added by it.

## Example workflow

[`examples/governed-loan-workflow.json`](./examples/governed-loan-workflow.json) — an importable workflow that:

1. Receives a loan request via HTTP trigger,
2. Calls **Check Policy** on the amount,
3. If `allowed=false`, branches to **Wait for Approval**, which creates the approval request and returns, then to a **Wait** node, which pauses the workflow until the reviewer's decision arrives at its webhook,
4. On approval, calls the downstream loan-issuance HTTP endpoint,
5. Records the outcome with **Record Decision**, with an error branch to **Audit Log**.

Import in n8n: **Workflows > Import from File >** `governed-loan-workflow.json`.

## Build from source

```bash
git clone https://github.com/getaxonflow/axonflow-n8n-node.git
cd axonflow-n8n-node
npm install
npm run build       # tsc > dist/
npm run lint
npm test            # node --test (102 tests)
```

`n8n-workflow` is pinned to exactly `2.11.1` on purpose. From 2.12.0 the package depends on `isolated-vm`, a native module whose Node floor (22, then 24) is above this package's CI matrix (Node 18, 20 and 22), so a routine bump breaks `npm ci` there. Compatibility with the n8n release this node targets (2.38.7) is proven by the runtime legs, which run the pinned `n8nio/n8n:2.38.7` image and CLI, not by these unit types.

## Documentation

- [n8n + AxonFlow Integration Guide](https://docs.getaxonflow.com/docs/integration/n8n/) — full walkthrough including the stock-HTTP-node recipe, HITL polling sidecar, and idempotency details.
- [AxonFlow](https://getaxonflow.com) — main project site.
- [AxonFlow on GitHub](https://github.com/getaxonflow/axonflow) — community edition.

## License

MIT
