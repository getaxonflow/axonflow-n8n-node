import {
	IExecuteFunctions,
	IDataObject,
	INodeExecutionData,
	INode,
	INodeType,
	INodeTypeDescription,
	NodeOperationError,
	NodeApiError,
	IHttpRequestOptions,
	IN8nHttpFullResponse,
	JsonObject,
} from 'n8n-workflow';

import { PEP_HANDSHAKE_HEADER, buildPepHandshake } from './pep-handshake';

/**
 * AxonFlow node — calls AxonFlow API endpoints from an n8n workflow.
 *
 * Operations:
 *   - checkPolicy        → POST /api/v1/mcp/check-input
 *   - recordDecision     → POST /api/v1/audit/tool-call (success path)
 *   - auditLog           → POST /api/v1/audit/tool-call (error / generic path)
 *   - waitForApproval    → POST /api/v1/hitl/queue (Enterprise only), returning at once
 *
 * Every request asks n8n for the full response and for no exception on an HTTP
 * status, so the node sees the platform's status AND body and decides in one
 * place (`interpretResponse`) what they mean: a decision item, or an error that
 * names its cause and quotes the platform.
 *
 * Every operation sends an Idempotency-Key header by default so n8n's
 * `Retry on Fail` re-runs don't double-record. Left empty, the key is
 * `<execution id>-<item index>-<node name>`, computed at run time, and it is
 * overridable. It is not a declared expression default: `$node` is n8n's
 * lookup of ANOTHER node by name, so `{{ $node.name }}` asks for a node
 * called "name", and n8n 2.x fails every operation with "Referenced node
 * doesn't exist" before any request is sent.
 */

export class AxonFlow implements INodeType {
	description: INodeTypeDescription = {
		displayName: 'AxonFlow',
		name: 'axonFlow',
		icon: 'file:axonflow.svg',
		group: ['transform'],
		version: 1,
		subtitle: '={{ $parameter["operation"] }}',
		description: 'AxonFlow API integration — call policy and HITL endpoints from your workflow.',
		defaults: {
			name: 'AxonFlow',
		},
		inputs: ['main'],
		outputs: ['main'],
		credentials: [
			{
				name: 'axonFlowApi',
				required: true,
			},
		],
		properties: [
			{
				displayName: 'Operation',
				name: 'operation',
				type: 'options',
				noDataExpression: true,
				options: [
					{
						name: 'Check Policy',
						value: 'checkPolicy',
						description: 'Submit a proposed action to AxonFlow and receive an allow/deny response',
						action: 'Check policy for a proposed action',
					},
					{
						name: 'Record Decision',
						value: 'recordDecision',
						description: 'Record the outcome of a downstream action in AxonFlow',
						action: 'Record a decision',
					},
					{
						name: 'Audit Log',
						value: 'auditLog',
						description: 'Record an event in AxonFlow (typically for error branches)',
						action: 'Record an event',
					},
					{
						name: 'Wait for Approval',
						value: 'waitForApproval',
						description:
							'Create a HITL approval request (AxonFlow Enterprise) and return at once; pair it with a Wait node to pause',
						action: 'Create a HITL approval request',
					},
				],
				default: 'checkPolicy',
			},

			// ─── Shared options ───────────────────────────────────────────────
			{
				displayName: 'Idempotency Key',
				name: 'idempotencyKey',
				type: 'string',
				default: '',
				description:
					'Sent as the Idempotency-Key header. Leave empty for the default: the execution ID, the item index and this node\'s name, joined by dashes, which is unique per execution-item-node so n8n retries do not double-record. Override only if you need a domain-specific key.',
			},
			{
				displayName: 'Failure Mode',
				name: 'failureMode',
				type: 'options',
				options: [
					{
						name: 'Open (Continue If AxonFlow Is Unreachable)',
						value: 'open',
					},
					{
						name: 'Closed (Fail If AxonFlow Is Unreachable)',
						value: 'closed',
					},
				],
				default: 'open',
				description:
					'On network errors / 5xx responses from AxonFlow. Open matches the AxonFlow ADK plugin default — the workflow proceeds with a structured fallback payload so the underlying action is not held hostage by an AxonFlow outage. Closed re-throws and stops the workflow; choose this for high-stakes flows where you would rather fail than skip the policy check.',
			},

			// ─── checkPolicy ────────────────────────────────────────────────
			{
				displayName: 'Connector Type',
				name: 'connectorType',
				type: 'string',
				default: 'n8n',
				displayOptions: { show: { operation: ['checkPolicy'] } },
				description:
					'AxonFlow connector type for this request. Use "n8n" unless you have a custom connector wired up.',
				required: true,
			},
			{
				displayName: 'Statement',
				name: 'statement',
				type: 'string',
				default: '',
				displayOptions: { show: { operation: ['checkPolicy'] } },
				description:
					'The proposed action as a string (e.g. SQL, prompt, API verb+path). AxonFlow evaluates this against policies.',
				required: true,
			},
			{
				displayName: 'Operation Type',
				name: 'mcpOperation',
				type: 'options',
				options: [
					{ name: 'Execute', value: 'execute' },
					{ name: 'Query', value: 'query' },
				],
				default: 'execute',
				displayOptions: { show: { operation: ['checkPolicy'] } },
			},
			{
				displayName: 'Parameters (JSON)',
				name: 'parameters',
				type: 'json',
				default: '{}',
				displayOptions: { show: { operation: ['checkPolicy'] } },
				description: 'Optional parameters passed alongside the statement',
			},

			// ─── recordDecision + auditLog (share ToolCallAuditEntry shape) ──
			{
				displayName: 'Tool Name',
				name: 'toolName',
				type: 'string',
				default: '',
				displayOptions: {
					show: { operation: ['recordDecision', 'auditLog'] },
				},
				description: 'Name of the tool / action being recorded (e.g. "approve_loan")',
				required: true,
			},
			{
				displayName: 'Workflow ID',
				name: 'workflowId',
				type: 'string',
				default: '={{ $workflow.id }}',
				displayOptions: {
					show: { operation: ['recordDecision', 'auditLog'] },
				},
				description: 'Defaults to the running n8n workflow ID so entries are searchable',
			},
			{
				displayName: 'Step ID',
				name: 'stepId',
				type: 'string',
				// Empty, not '={{ $node.name }}': see the Idempotency Key note above.
				// Left empty, the step id is this node's name, set at run time.
				default: '',
				displayOptions: {
					show: { operation: ['recordDecision', 'auditLog'] },
				},
				description: "Leave empty to use this node's name",
			},
			{
				displayName: 'Input (JSON)',
				name: 'auditInput',
				type: 'json',
				default: '={{ JSON.stringify($json) }}',
				displayOptions: {
					show: { operation: ['recordDecision', 'auditLog'] },
				},
				description: 'Inputs to record alongside the decision. Defaults to the current item.',
			},
			{
				displayName: 'Output (JSON)',
				name: 'auditOutput',
				type: 'json',
				default: '{}',
				displayOptions: {
					show: { operation: ['recordDecision', 'auditLog'] },
				},
			},
			{
				displayName: 'Success',
				name: 'auditSuccess',
				type: 'boolean',
				default: true,
				displayOptions: {
					show: { operation: ['recordDecision', 'auditLog'] },
				},
				description:
					'Whether the recorded action succeeded. Set false from error branches.',
			},
			{
				displayName: 'Error Message',
				name: 'auditErrorMessage',
				type: 'string',
				default: '',
				displayOptions: {
					show: { operation: ['recordDecision', 'auditLog'] },
				},
			},

			// ─── waitForApproval ─────────────────────────────────────────────
			{
				displayName: 'Request Type',
				name: 'requestType',
				type: 'string',
				default: 'workflow_step',
				displayOptions: { show: { operation: ['waitForApproval'] } },
				description: 'AxonFlow request_type for the approval entry',
			},
			{
				displayName: 'Original Query / Action',
				name: 'originalQuery',
				type: 'string',
				default: '',
				displayOptions: { show: { operation: ['waitForApproval'] } },
				description: 'Short description of what needs approval',
				required: true,
			},
			{
				displayName: 'Triggered Policy ID',
				name: 'triggeredPolicyId',
				type: 'string',
				default: 'n8n-manual',
				displayOptions: { show: { operation: ['waitForApproval'] } },
				description: 'AxonFlow static_policies.ID that triggered this approval. Use "n8n-manual" for workflow-initiated approvals not tied to a specific policy.',
			},
			{
				displayName: 'Triggered Policy Name',
				name: 'triggeredPolicyName',
				type: 'string',
				default: 'n8n manual approval',
				displayOptions: { show: { operation: ['waitForApproval'] } },
			},
			{
				displayName: 'Trigger Reason',
				name: 'triggerReason',
				type: 'string',
				default: 'Approval requested from n8n workflow',
				displayOptions: { show: { operation: ['waitForApproval'] } },
			},
			{
				displayName: 'Severity',
				name: 'severity',
				type: 'options',
				options: [
					{ name: 'Low', value: 'low' },
					{ name: 'Medium', value: 'medium' },
					{ name: 'High', value: 'high' },
					{ name: 'Critical', value: 'critical' },
				],
				default: 'medium',
				displayOptions: { show: { operation: ['waitForApproval'] } },
			},
			{
				displayName: 'Limit Wait Time (Seconds)',
				name: 'limitWaitTime',
				type: 'number',
				default: 86400,
				displayOptions: { show: { operation: ['waitForApproval'] } },
				description:
					'Maps to expires_in_seconds on the AxonFlow approval. Defaults to 24h.',
			},
			{
				displayName: 'Notify URL',
				name: 'notifyUrl',
				type: 'string',
				default: '',
				displayOptions: { show: { operation: ['waitForApproval'] } },
				description:
					'Webhook URL that AxonFlow POSTs to when the approval is decided (v8.1.0+). Point this at an n8n Wait node webhook URL to auto-resume the workflow on approval or rejection.',
			},
			{
				displayName: 'Request Context (JSON)',
				name: 'requestContext',
				type: 'json',
				default: '={{ JSON.stringify($json) }}',
				displayOptions: { show: { operation: ['waitForApproval'] } },
				description:
					'Arbitrary context surfaced in the AxonFlow portal. Defaults to the current item.',
			},
		],
	};

	async execute(this: IExecuteFunctions): Promise<INodeExecutionData[][]> {
		const items = this.getInputData();
		const credentials = await this.getCredentials('axonFlowApi');
		const endpoint = String(credentials.endpoint || '').replace(/\/+$/, '');
		const clientId = String(credentials.clientId || '');
		// ADR-065 capability handshake, rendered ONCE per execution rather than
		// per item. A malformed audience throws here, before any governed call is
		// made, rather than 400-ing every request in production.
		const pepHandshake = buildPepHandshake(
			String(credentials.pepAudience || '').trim() || undefined,
		);

		const returnData: INodeExecutionData[] = [];

		for (let i = 0; i < items.length; i++) {
			const operation = this.getNodeParameter('operation', i) as string;
			// The fallback applies to an EMPTY value too: the declared default is ''
			// (see the Idempotency Key note), and getNodeParameter's own fallback
			// covers only an undefined parameter.
			const idempotencyKey =
				(this.getNodeParameter('idempotencyKey', i, '') as string) ||
				defaultIdempotencyKey(this.getExecutionId(), i, this.getNode().name);
			const failureMode = this.getNodeParameter('failureMode', i, 'open') as
				| 'open'
				| 'closed';

			try {
				let result: IDataObject;

				switch (operation) {
					case 'checkPolicy':
						result = await callAxonFlow(
							this,
							operation,
							buildRequest({
								endpoint,
								method: 'POST',
								path: '/api/v1/mcp/check-input',
								idempotencyKey,
								pepHandshake,
								body: {
									client_id: clientId,
									// No user_token: the credential's "User Token" is the client
									// secret, and it travels only in the Authorization header.
									tenant_id: clientId,
									connector_type: this.getNodeParameter('connectorType', i) as string,
									statement: this.getNodeParameter('statement', i) as string,
									operation: this.getNodeParameter('mcpOperation', i) as string,
									parameters: parseJsonParam(
										this.getNodeParameter('parameters', i, '{}') as string | object,
									),
								},
							}),
						);
						break;

					case 'recordDecision':
					case 'auditLog':
						result = await callAxonFlow(
							this,
							operation,
							buildRequest({
								endpoint,
								method: 'POST',
								path: '/api/v1/audit/tool-call',
								idempotencyKey,
								body: {
									tool_name: this.getNodeParameter('toolName', i) as string,
									// Client identity. `caller_name` is the current field; `tool_type`
									// is the deprecated fallback the platform still honors (precedence:
									// caller_name > tool_type > default). Dual-send both during the
									// deprecation window so attribution is correct on platforms with
									// caller_name support (v9.11.0+) and unchanged on older ones.
									caller_name: operation === 'auditLog' ? 'n8n_audit' : 'n8n_decision',
									tool_type: operation === 'auditLog' ? 'n8n_audit' : 'n8n_decision',
									// No user_id: the credential secret is never a user id, and
									// n8n has no end-user identity to put there.
									workflow_id: this.getNodeParameter('workflowId', i) as string,
									step_id:
										(this.getNodeParameter('stepId', i, '') as string) ||
										this.getNode().name,
									input: parseJsonParam(
										this.getNodeParameter('auditInput', i, '{}') as string | object,
									),
									output: parseJsonParam(
										this.getNodeParameter('auditOutput', i, '{}') as string | object,
									),
									success: this.getNodeParameter('auditSuccess', i) as boolean,
									error_message: this.getNodeParameter('auditErrorMessage', i, '') as string,
								},
							}),
						);
						break;

					case 'waitForApproval': {
						const limitWaitTime = this.getNodeParameter('limitWaitTime', i) as number;
						const notifyUrl = this.getNodeParameter('notifyUrl', i, '') as string;
						const hitlBody: IDataObject = {
							client_id: clientId,
							// No user_id: the credential secret is never a user id.
							original_query: this.getNodeParameter('originalQuery', i) as string,
							request_type: this.getNodeParameter('requestType', i) as string,
							request_context: parseJsonParam(
								this.getNodeParameter('requestContext', i, '{}') as string | object,
							),
							triggered_policy_id: this.getNodeParameter('triggeredPolicyId', i) as string,
							triggered_policy_name: this.getNodeParameter(
								'triggeredPolicyName',
								i,
							) as string,
							trigger_reason: this.getNodeParameter('triggerReason', i) as string,
							severity: this.getNodeParameter('severity', i) as string,
							expires_in_seconds: limitWaitTime,
						};
						if (notifyUrl) {
							hitlBody.notify_url = notifyUrl;
						}
						const createResp = await callAxonFlow(
							this,
							operation,
							buildRequest({
								endpoint,
								method: 'POST',
								path: '/api/v1/hitl/queue',
								idempotencyKey,
								body: hitlBody,
							}),
						);

						const approvalData = extractApprovalData(createResp, this.getNode());

						// Surface the approval payload + a hint about how to resume.
						// As of v8.1.0+, the AxonFlow platform supports outbound
						// webhooks via notify_url. When create_hitl_request includes
						// a notify_url, the platform POSTs approval/rejection events
						// to that URL automatically. For n8n, point notify_url at a
						// Wait node webhook URL.
						result = {
							approval_id: approvalData.id,
							status: approvalData.status ?? 'pending',
							expires_at: approvalData.expires_at,
							resume_hint:
								'Use notify_url (v8.1.0+) to auto-POST approval events to a Wait node webhook, or poll GET /api/v1/hitl/queue/{id}. See https://docs.getaxonflow.com/docs/integration/n8n/#hitl.',
							raw: createResp,
						};
						break;
					}

					default:
						throw new NodeOperationError(
							this.getNode(),
							`Unknown operation: ${operation}`,
						);
				}

				returnData.push({
					json: result,
					pairedItem: { item: i },
				});
			} catch (error) {
				if (this.continueOnFail()) {
					returnData.push({
						json: { error: (error as Error).message },
						pairedItem: { item: i },
					});
					continue;
				}

				// Fail-open default mirrors the AxonFlow ADK plugin: when
				// AxonFlow itself is unhealthy (network unreachable, or 5xx
				// server-side fault), the workflow continues with a structured
				// fallback item so the underlying action isn't held hostage by
				// an AxonFlow outage.
				//
				// 4xx responses are NEVER swallowed under fail-open — they
				// represent caller-side problems (bad creds, malformed body,
				// tier mismatch, rate limit) that the user needs to see and
				// fix. Silently proceeding on a 401 would let a workflow run
				// without policy enforcement and never surface to the user.
				//
				// NodeOperationError is reserved for true programmer errors
				// (unknown operation, missing-envelope response) — always
				// rethrown regardless of failureMode.
				//
				// The fallback item is never silent: `governance: 'unavailable'` and
				// `cause` say that no decision was made and why. It deliberately has
				// NO `allowed` key. Workflows branch on `{{ $json.allowed }}`, which
				// is falsy on this item; adding `allowed: true` would send every
				// saved workflow down its TRUE branch during an outage.
				if (failureMode === 'open' && shouldFailOpen(error)) {
					returnData.push({
						json: {
							_axonflow_unreachable: true,
							governance: 'unavailable',
							cause: unreachableCause(error),
							error: (error as Error).message,
							operation,
						},
						pairedItem: { item: i },
					});
					continue;
				}
				throw error;
			}
		}

		return [returnData];
	}
}

interface BuildRequestArgs {
	endpoint: string;
	method: 'GET' | 'POST';
	path: string;
	idempotencyKey: string;
	body?: IDataObject;
	/**
	 * The ADR-065 capability declaration, or undefined.
	 *
	 * Passed per call site rather than read from a module-level value because
	 * only the GOVERNED routes carry it: the platform reads the declaration on
	 * the policy-evaluating routes and nowhere else, so presenting it on the
	 * audit and HITL calls would inflate the adoption denominator with routes
	 * that evaluate nothing.
	 */
	pepHandshake?: string;
}

function buildRequest(args: BuildRequestArgs): IHttpRequestOptions {
	const headers: IDataObject = {
		'Content-Type': 'application/json',
		Accept: 'application/json',
	};
	if (args.idempotencyKey) {
		headers['Idempotency-Key'] = args.idempotencyKey;
	}
	// ADR-065 capability handshake (axonflow-enterprise#3763). Omitted entirely
	// when unconfigured: a PRESENT-but-empty value is MALFORMED to the platform
	// and refuses the request, which an absent header does not.
	if (args.pepHandshake) {
		headers[PEP_HANDSHAKE_HEADER] = args.pepHandshake;
	}

	return {
		method: args.method,
		url: `${args.endpoint}${args.path}`,
		headers,
		body: args.body,
		json: true,
		// Without these n8n throws its own NodeApiError on any non-2xx before the
		// node sees the body, and a policy deny (HTTP 403 on check-input) reads
		// "Forbidden - perhaps check your credentials?".
		returnFullResponse: true,
		ignoreHttpStatusErrors: true,
	};
}

/**
 * The platform's Idempotency-Key alphabet and length
 * (platform/shared/idempotency/store.go). A key outside either is refused with
 * HTTP 400, so every call of the node would fail.
 */
const IDEMPOTENCY_KEY_INVALID = /[^A-Za-z0-9_.:\-/]/g;
const MAX_IDEMPOTENCY_KEY_LENGTH = 256;

/**
 * `<execution id>-<item index>-<node name>`, made a key the platform accepts.
 *
 * A node name is free text ("AxonFlow Check Policy"), so each character
 * outside the platform's alphabet becomes `_`. When anything was replaced or
 * cut to fit 256 characters, a hash of the original name is appended, so two
 * names that differ only there still get different keys. A valid name that
 * fits is used unchanged, which keeps every existing default key as it was.
 */
function defaultIdempotencyKey(executionId: string, itemIndex: number, nodeName: string): string {
	const prefix = `${String(executionId).replace(IDEMPOTENCY_KEY_INVALID, '_')}-${itemIndex}-`;
	const safe = nodeName.replace(IDEMPOTENCY_KEY_INVALID, '_');
	const room = MAX_IDEMPOTENCY_KEY_LENGTH - prefix.length;
	if (safe === nodeName && safe.length <= room) {
		return prefix + safe;
	}
	const suffix = `-${fnv1a32(nodeName)}`;
	return prefix + safe.slice(0, Math.max(0, room - suffix.length)) + suffix;
}

/** FNV-1a over UTF-16 code units, as 8 hex digits. Not a security hash. */
function fnv1a32(text: string): string {
	let hash = 0x811c9dc5;
	for (let i = 0; i < text.length; i++) {
		hash ^= text.charCodeAt(i);
		hash = Math.imul(hash, 0x01000193) >>> 0;
	}
	return hash.toString(16).padStart(8, '0');
}

/** The longest platform text quoted into an error message. */
const MAX_PLATFORM_TEXT = 500;

async function callAxonFlow(
	ctx: IExecuteFunctions,
	operation: string,
	request: IHttpRequestOptions,
): Promise<IDataObject> {
	const response = (await ctx.helpers.httpRequestWithAuthentication.call(
		ctx,
		'axonFlowApi',
		request,
	)) as unknown;
	return interpretResponse(ctx.getNode(), operation, response);
}

/**
 * The ONE place a status and a body become a result or an error.
 *
 * - 2xx: the body, verbatim.
 * - Check Policy, 403 carrying `allowed: false`: a policy deny (the spec's
 *   "Input blocked by policy", body MCPCheckInputResponse). Returned as the
 *   item, verbatim, so a downstream IF branches on `allowed` and reads
 *   `block_reason`, which carries an `unknown_constraint` or
 *   `approval_required` refusal in full. A 403 WITHOUT `allowed: false` is not
 *   a decision: a tier-feature limit answers 403 with the rate-limit envelope.
 * - Every other status is an error that names its cause and quotes the
 *   platform: 401 the credential, 402 a tier limit, 429 a rate limit (with
 *   `limit_type` and `resets_at` when the envelope carries them), 404 on the
 *   approval queue the edition, 5xx a platform fault. Only a 5xx is swallowable
 *   by `shouldFailOpen`; every 4xx is rethrown under either failure mode.
 */
function interpretResponse(node: INode, operation: string, response: unknown): IDataObject {
	if (!isObject(response) || typeof response.statusCode !== 'number') {
		throw new NodeOperationError(
			node,
			'AxonFlow request returned no HTTP status, so the node cannot tell a decision from an error and refuses to continue.',
		);
	}
	const full = response as unknown as IN8nHttpFullResponse;
	const status = full.statusCode;
	const body = full.body;

	if (status >= 200 && status < 300) {
		if (!isObject(body)) {
			throw new NodeOperationError(
				node,
				`AxonFlow answered HTTP ${status} without a JSON object body, so the node cannot read a result from it.`,
			);
		}
		return body as IDataObject;
	}
	if (operation === 'checkPolicy' && status === 403 && isObject(body) && body.allowed === false) {
		return body as IDataObject;
	}
	throw platformError(node, operation, status, body, full.headers ?? {});
}

function platformError(
	node: INode,
	operation: string,
	status: number,
	body: unknown,
	headers: IDataObject,
): NodeApiError {
	const said = platformText(body);
	const limit = limitDetails(body, headers);
	let message: string;
	if (status === 401) {
		message = `AxonFlow rejected the credential (HTTP 401): ${said}. Check the Client ID and User Token of the AxonFlow API credential.`;
	} else if (status === 402) {
		// Not in the published spec for check-input (axonflow-enterprise#4249,
		// comment 5682255301); answered when a tier limit refuses the principal.
		message = `AxonFlow refused the request: a tier limit of this deployment was reached (HTTP 402${limit}): ${said}`;
	} else if (status === 429) {
		message = `AxonFlow refused the request: a rate limit was reached (HTTP 429${limit}): ${said}`;
	} else if (status === 404 && operation === 'waitForApproval') {
		message = `AxonFlow has no approval queue at this endpoint (HTTP 404): /api/v1/hitl/queue is served by AxonFlow Enterprise only, so a Community deployment cannot create an approval request: ${said}`;
	} else if (status === 403 && operation === 'checkPolicy' && isObject(body) && body.allowed === true) {
		message = `AxonFlow answered HTTP 403 with allowed: true, which is not a decision the node can act on, so the request is treated as refused: ${said}`;
	} else if (status >= 400 && status < 500 && isObject(body) && typeof body.limit_type === 'string') {
		message = `AxonFlow refused the request: a tier limit was reached (HTTP ${status}${limit}): ${said}`;
	} else if (status >= 500 && status < 600) {
		message = `AxonFlow failed to process the request (HTTP ${status}): ${said}`;
	} else {
		message = `AxonFlow refused the request (HTTP ${status}): ${said}`;
	}
	const error = new NodeApiError(node, { httpCode: String(status) } as JsonObject, {
		message,
		httpCode: String(status),
	});
	// NodeApiError replaces a message that merely CONTAINS a Node error code
	// (ECONNREFUSED, ENOENT, ...) with n8n's canned text, and the platform's
	// quoted text can contain one. The message is the point of this error.
	error.message = message;
	return error;
}

/**
 * The platform's own words from an error body, cleaned for a one-line message:
 * a string `error` (with its `error_description` when there is one), an
 * `error.message` (the middleware envelope, with its `code`), a `message`, a
 * `block_reason`, or the body itself. ASCII control
 * characters become spaces and the text is capped.
 */
function platformText(body: unknown): string {
	let text = '';
	if (typeof body === 'string') {
		text = body;
	} else if (isObject(body)) {
		const err = body.error;
		if (typeof err === 'string') {
			text = typeof body.error_description === 'string' ? `${err}: ${body.error_description}` : err;
		} else if (isObject(err) && typeof err.message === 'string') {
			text = err.code !== undefined ? `${String(err.code)}: ${err.message}` : err.message;
		} else if (typeof body.message === 'string') {
			text = body.message;
		} else if (typeof body.block_reason === 'string') {
			text = body.block_reason;
		} else {
			text = JSON.stringify(body);
		}
	} else if (body !== undefined && body !== null) {
		text = JSON.stringify(body);
	}
	return cleanText(text) || '(the response carried no error text)';
}

/**
 * `, limit_type "daily_quota", resets at <time>, retry after 30 s`, from the
 * rate-limit envelope and the Retry-After header, each part only when present.
 * A `resets_at` that is not a date is quoted as given and marked.
 */
function limitDetails(body: unknown, headers: IDataObject): string {
	const parts: string[] = [];
	if (isObject(body)) {
		const limitType = typeof body.limit_type === 'string' ? cleanText(body.limit_type) : '';
		if (limitType) {
			parts.push(`limit_type "${limitType}"`);
		}
		const resets = typeof body.resets_at === 'string' ? cleanText(body.resets_at) : '';
		if (resets) {
			parts.push(
				Number.isNaN(Date.parse(resets)) ? `resets_at "${resets}" (not a date)` : `resets at ${resets}`,
			);
		}
	}
	const retryAfter = headers['retry-after'] ?? headers['Retry-After'];
	if (typeof retryAfter === 'string' && /^\d+$/.test(retryAfter.trim())) {
		parts.push(`retry after ${retryAfter.trim()} s`);
	}
	return parts.length ? `, ${parts.join(', ')}` : '';
}

function cleanText(text: string): string {
	// eslint-disable-next-line no-control-regex
	const cleaned = text.replace(/[\u0000-\u001f\u007f]+/g, ' ').replace(/ {2,}/g, ' ').trim();
	return cleaned.length > MAX_PLATFORM_TEXT ? `${cleaned.slice(0, MAX_PLATFORM_TEXT)}…` : cleaned;
}

function isObject(value: unknown): value is Record<string, unknown> {
	return typeof value === 'object' && value !== null && !Array.isArray(value);
}

/** `http_503` for a platform fault, `no_response` when nothing answered. */
function unreachableCause(error: unknown): string {
	const code = httpCodeOf(error);
	return code === undefined ? 'no_response' : `http_${code}`;
}

/**
 * Decides whether a thrown error should be swallowed under `failureMode: open`.
 *
 * Swallowed:
 *   - Transport-level failures (no httpCode — fetch threw before getting a
 *     response, e.g. ECONNREFUSED / ETIMEDOUT / ENOTFOUND / ENETUNREACH /
 *     ECONNRESET / network-down).
 *   - HTTP 5xx responses (server-side AxonFlow fault).
 *
 * Rethrown:
 *   - NodeOperationError — programmer errors (always surface).
 *   - HTTP 4xx — caller-side errors. 401 (bad creds), 403 (forbidden), 404
 *     (missing endpoint / wrong tier), 422 (malformed body), 429 (rate limit)
 *     are problems the user needs to see and fix. Swallowing them would let a
 *     workflow run un-governed and never surface to the user.
 *
 * An HTTP status reaches here as the `NodeApiError` that `interpretResponse`
 * built, with the code on `error.httpCode` (string). A transport failure is
 * n8n's own error, with no code. `error.context?.statusCode` (number) is probed
 * too, the shape n8n's own status errors have carried.
 */
function shouldFailOpen(error: unknown): boolean {
	if (error instanceof NodeOperationError) return false;

	const httpCode = httpCodeOf(error);

	if (httpCode !== undefined) {
		// 5xx → AxonFlow itself is faulting → swallow.
		// 4xx → caller error → rethrow so the user sees it.
		return httpCode >= 500 && httpCode < 600;
	}

	// No httpCode → transport-level failure → swallow.
	return true;
}

function httpCodeOf(error: unknown): number | undefined {
	const err = error as { httpCode?: string | number | null; context?: { statusCode?: number } };
	const raw = typeof err.httpCode === 'string' ? parseInt(err.httpCode, 10) : err.httpCode;
	const code = typeof raw === 'number' ? raw : err.context?.statusCode;
	return typeof code === 'number' && !Number.isNaN(code) ? code : undefined;
}

function parseJsonParam(value: string | object): IDataObject {
	if (value === null || value === undefined) return {};
	if (typeof value === 'object') return value as IDataObject;
	if (typeof value === 'string') {
		const trimmed = value.trim();
		if (!trimmed) return {};
		try {
			const parsed = JSON.parse(trimmed);
			return (typeof parsed === 'object' && parsed !== null
				? parsed
				: { value: parsed }) as IDataObject;
		} catch {
			return { raw: value };
		}
	}
	return {};
}

/**
 * AxonFlow's CreateRequest handler returns the canonical APIResponse envelope:
 *   { success: true, data: { id, status, expires_at, ... } }
 * Pull approval_id + status off the inner data object. If the envelope is
 * missing — e.g. a misconfigured reverse proxy stripped it — surface a clear
 * NodeOperationError rather than silently emitting an empty approval payload
 * downstream.
 */
function extractApprovalData(
	resp: IDataObject,
	node: INode,
): { id?: string; status?: string; expires_at?: string } {
	const inner = resp.data as IDataObject | undefined;
	if (!inner || typeof inner !== 'object') {
		throw new NodeOperationError(
			node,
			'AxonFlow returned an unexpected response shape from /api/v1/hitl/queue — missing `data` envelope. ' +
				'Check that the request is hitting the AxonFlow Agent directly (not a proxy that strips the wrapping object).',
		);
	}
	return {
		id: (inner.id as string | undefined) ?? (inner.approval_id as string | undefined),
		status: inner.status as string | undefined,
		expires_at: inner.expires_at as string | undefined,
	};
}
