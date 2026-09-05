# n8n-nodes-axonflow

AxonFlow API integration for [n8n](https://n8n.io). Call the AxonFlow policy and HITL endpoints directly from your n8n workflows.

[![npm version](https://img.shields.io/npm/v/@axonflow/n8n-nodes-axonflow)](https://www.npmjs.com/package/@axonflow/n8n-nodes-axonflow)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

## What it does

This package contributes a single `AxonFlow` node with four operations against an AxonFlow Agent:

| Operation | Endpoint | When to use |
|---|---|---|
| **Check Policy** | `POST /api/v1/mcp/check-input` | Before a workflow takes a sensitive action — receive `{allowed, block_reason?}` and branch on it. On a redact-not-block allow it also returns the masked text; see **Redaction: your workflow must use the masked text** below. |
| **Record Decision** | `POST /api/v1/audit/tool-call` | After a successful action — capture inputs, outputs, policies applied. |
| **Audit Log** | `POST /api/v1/audit/tool-call` | From error branches — record the failed action with `success: false` and `error_message`. |
| **Wait for Approval** | `POST /api/v1/hitl/queue` | When the workflow needs a human in the loop — creates an approval entry and pairs with an n8n Wait node for webhook resume. |

Plus a single `AxonFlow API` credential type holding the endpoint + Basic-auth (`clientId` + `userToken`).

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
   - **Wait for Approval** — create a HITL request and pair with a Wait node for webhook resume.
5. Run the workflow.

## Three things to know

1. **Bearer Auth > Header Auth.** This credential uses the Header Auth pattern (Authorization built inline) rather than n8n's built-in Bearer Auth class, which silently drops the header in some n8n versions ([n8n#15261](https://github.com/n8n-io/n8n/issues/15261)).
2. **Idempotency by default.** Every operation sends `Idempotency-Key: {executionId}-{itemIndex}-{nodeName}` so n8n's `Retry on Fail` doesn't double-record. Override at the node parameter level if you need a domain-specific key.
3. **HITL pairs with the Wait node.** `Wait for Approval` creates the AxonFlow approval entry; pair it with a downstream Wait node configured for **On Webhook Call** mode. As of platform v8.1.0+, pass the Wait node's webhook URL as `notify_url` in the HITL queue request and AxonFlow will POST to it automatically on approval/rejection — no polling sidecar needed. For self-hosted deployments on v8.0.x, two manual paths work: (a) run a small **polling sidecar** that watches `GET /api/v1/hitl/queue/{id}` and POSTs to the Wait node's webhook URL when status changes, or (b) have a reviewer trigger the resume URL manually from the portal. See the [n8n integration docs](https://docs.getaxonflow.com/docs/integration/n8n/#hitl) for details.

## Client identification

Every call this node makes to AxonFlow carries `X-Axonflow-Client: n8n-plugin/<version>`, set once on the credential so it rides every operation. The version is read from this package's own metadata.

**What this is and is not.** It is attribution on a request the platform already receives — no additional request is made, and **this node sends no heartbeat or telemetry ping of its own**. It is never used for authentication: the platform authenticates on the `Authorization` header, so a missing or mangled value cannot fail a call. Nothing about your workflow data, statements, parameters, or identity is added by it.

## Example workflow

[`examples/governed-loan-workflow.json`](./examples/governed-loan-workflow.json) — an importable workflow that:

1. Receives a loan request via HTTP trigger,
2. Calls **Check Policy** on the amount,
3. If `allowed=false`, branches to **Wait for Approval** (workflow pauses),
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
npm test            # node --test (25 tests)
```

## Documentation

- [n8n + AxonFlow Integration Guide](https://docs.getaxonflow.com/docs/integration/n8n/) — full walkthrough including the stock-HTTP-node recipe, HITL polling sidecar, and idempotency details.
- [AxonFlow](https://getaxonflow.com) — main project site.
- [AxonFlow on GitHub](https://github.com/getaxonflow/axonflow) — community edition.

## License

MIT
