# credential-reaches-a-checking-platform

**Asserts**, by driving the real n8n 2.x CLI with this node installed against an AxonFlow platform that checks credentials (Community SaaS or Enterprise):

1. **A workflow with no Idempotency Key set executes.** The old declared default, `{{ $node.name }}`, asked n8n for another node called "name", and n8n 2.x failed every operation with "Referenced node doesn't exist" before any request was sent.
2. **The credential is accepted: check-input answers with a decision, not a 401.** The old credential built its `Authorization` header with `Buffer.from(...)` inside an expression, and n8n 2.x replaces `Buffer` with an empty object there, so the header was the bare word `Basic`.

Plain Community admits any credential, so it cannot show the second property. The leg first sends a wrong secret and skips unless the platform answers 401.

The third property this fix carries, that the credential secret travels only in the `Authorization` header and never in a request body, needs the wire: run the leg behind a pass-through logger in front of the agent, and check that the header is `Basic` with a real length and that no body contains the secret.

## Run

    N8N_BIN=/path/to/node_modules/.bin/n8n AXONFLOW_ENDPOINT=http://localhost:8080 ./test.sh

- `N8N_BIN` (required): an n8n 2.x CLI. `N8N_NODE_BIN`: a Node.js bin directory for it.
- `AXONFLOW_E2E_CLIENT_ID` and `AXONFLOW_E2E_CLIENT_SECRET`: a credential on the platform; without them the leg registers a Community SaaS tenant.
- `NODE_PACKAGE`: a tarball of this package; without it the leg builds and packs this checkout. `N8N_USER_FOLDER`: an n8n user folder that already has the node installed.
- `E2E_EVIDENCE_DIR` keeps every execution's output.

n8n's import reads a file, so the secret is written with mode 0600 for the import and removed straight after; n8n stores it encrypted.
