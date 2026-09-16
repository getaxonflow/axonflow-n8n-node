/**
 * What AxonFlow puts on the wire, and what n8n hands the node, as fixtures.
 *
 * PROVENANCE. Each body below names where it came from: MEASURED on a v11.0.0
 * agent (the runtime-e2e stack, public getaxonflow/axonflow main), or
 * SPEC-DERIVED from `docs/api/agent-api.yaml` at axonflow-enterprise 76fb9d376
 * where a community stack cannot produce the status. A fixture that differs
 * from the wire is a test that cannot fail, so change a body here only from a
 * new measurement or a new spec line, and say which.
 */

export interface WireResponse {
	statusCode: number;
	body?: unknown;
	headers?: Record<string, string>;
}

export function wire(statusCode: number, body?: unknown, headers?: Record<string, string>): WireResponse {
	return { statusCode, body, headers };
}

/**
 * The stub's model of n8n-core's `httpRequestWithAuthentication` (read at
 * n8n-core 2.38.2 and @n8n/backend-network `http/axios/request.js`): a non-2xx
 * THROWS unless `ignoreHttpStatusErrors` is set, and the body alone is returned
 * unless `returnFullResponse` is set. A transport failure (no response) throws
 * whatever the options. Modelled, not assumed away, so that a node that stops
 * asking for either option reds the suite instead of reading a fixture it
 * would never receive.
 */
export function n8nHelperAnswer(
	next: WireResponse | Error,
	opts: { returnFullResponse?: boolean; ignoreHttpStatusErrors?: unknown },
): unknown {
	if (next instanceof Error) throw next;
	const ok = next.statusCode >= 200 && next.statusCode < 300;
	if (!ok && !opts.ignoreHttpStatusErrors) {
		throw Object.assign(new Error(`Request failed with status code ${next.statusCode}`), {
			httpCode: String(next.statusCode),
		});
	}
	if (!opts.returnFullResponse) return next.body;
	return {
		body: next.body,
		headers: next.headers ?? {},
		statusCode: next.statusCode,
		statusMessage: '',
	};
}

/** A transport failure: n8n's error carries no HTTP code. */
export function noResponse(message = 'connect ECONNREFUSED 127.0.0.1:8080'): Error {
	return new Error(message);
}

// ─── check-input ────────────────────────────────────────────────────────────
// MEASURED bodies below were captured on 2026-09-16 from an agent built from
// public getaxonflow/axonflow dcd5f636d (/health: edition community, version
// 11.0.0), POSTing the node's own request shape to /api/v1/mcp/check-input.

/** MEASURED: 200, an ordinary statement. */
export const CHECK_INPUT_ALLOW = {
	allowed: true,
	policies_evaluated: 92,
	policy_info: {
		policies_evaluated: 92,
		blocked: false,
		redactions_applied: 0,
		matched_policies: [{ policy_id: 'baseline.permit.tool.call', policy_name: '', category: '', severity: '', action: '' }],
		processing_time_ms: 0,
	},
	decision_id: '13abe310-1ba3-4d34-8620-5445f855e5d6',
	redaction_evaluated: true,
	engine: 'anchored',
	subject_type: 'Client',
	policy_bundle: 'sha256:be33fe8cde91167b29684c4ff87a76fb52e71db55218b8ea30d762ae626b794f',
};

/** MEASURED: 403, `rm -rf / --no-preserve-root`, refused by a shipped control. */
export const CHECK_INPUT_DENY = {
	allowed: false,
	block_reason: 'explicit_constraint',
	policies_evaluated: 92,
	decision_id: '6090bc98-9703-41cf-8a0a-8585a9456f13',
	policy_matches: [
		{
			policy_id: 'corpus:static_policies:sys__dangerous__destructive__fs',
			policy_name: 'Destructive Filesystem Operations',
			allow_override: false,
		},
	],
	engine: 'anchored',
	subject_type: 'Client',
	policy_bundle: 'sha256:be33fe8cde91167b29684c4ff87a76fb52e71db55218b8ea30d762ae626b794f',
};

/**
 * CENSUS-MEASURED: the block_reason text axonflow-internal-docs#145 recorded
 * on Community (window 1, an organization document whose constraint needs an
 * attribute no client sends). The code and the sentence are joined by a
 * SEMICOLON. Not reproduced on the lane's community stack: publishing that
 * document goes through typed authoring, which needs a licence.
 */
export const CHECK_INPUT_DENY_UNKNOWN_CONSTRAINT = {
	allowed: false,
	block_reason:
		'unknown_constraint; ceiling.refund (organization, document version 1) could not be evaluated: no value was supplied for args.request_type, which the document requires',
	policies_evaluated: 98,
	decision_id: 'd7b77a30-a8c2-4fe1-baac-9857f00f27f2',
};

/** SPEC-DERIVED: PRD v11 §1 item 13 (a challenge on a plane with no hold is a deny with approval_required); the census's F4 row records the `approval_required: ...` form. */
export const CHECK_INPUT_DENY_APPROVAL_REQUIRED = {
	allowed: false,
	block_reason: 'approval_required: policy sys_example_high_value requires a reviewer',
	policies_evaluated: 1,
};

// ─── errors ─────────────────────────────────────────────────────────────────

/** SPEC-DERIVED: JSONError, the auth middleware's envelope. A community stack admits any credential, so a rejection 401 is not measurable there. */
export const MIDDLEWARE_401 = { error: { code: 401, message: 'invalid credentials' } };

/** SPEC-DERIVED: a REST per-minute 429, a plain error body with Retry-After only (RateLimitEnvelope description). */
export const PER_MINUTE_429 = { error: 'rate limit exceeded' };

/** SPEC-DERIVED: RateLimitEnvelope for a daily-quota 429 (Community SaaS only). */
export const DAILY_QUOTA_429 = {
	error: 'daily request quota exceeded',
	limit_type: 'daily_quota',
	tier: 'free',
	limit: 1000,
	remaining: 0,
	window: '24h',
	resets_at: '2026-09-17T00:00:00Z',
};

/** SPEC-DERIVED: RateLimitEnvelope with 403 for a Pro-only feature (not a decision). */
export const FEATURE_PRO_ONLY_403 = {
	error: 'this feature requires the Pro tier',
	limit_type: 'feature_pro_only',
	tier: 'free',
};

/** MEASURED: 402 from check-input for a sixth client id on a community organization. */
export const TIER_LIMIT_402 = {
	success: false,
	error: 'ERR_TIER_LIMIT_SERVICE_PRINCIPAL: the community edition admits at most 5 service_principal(s) per organization and 5 are already admitted. Upgrade at https://getaxonflow.com/enterprise',
	blocked: false,
};

/** MEASURED: 404 from /api/v1/hitl/queue on a community agent. */
export const HITL_QUEUE_404 = {
	error: 'not_found',
	error_description:
		'No such endpoint on the AxonFlow agent. If you are an MCP client doing OAuth discovery: this server uses HTTP Basic auth (base64(org_id:license_key)) via AXONFLOW_AUTH, not OAuth.',
};

/** SPEC-DERIVED: the HITL queue's create response, the APIResponse envelope `{success, data: {id, status, expires_at}}` extractApprovalData reads. The route is Enterprise-only, so a community stack answers 404 (HITL_QUEUE_404). */
export const HITL_CREATED = {
	success: true,
	data: { id: 'approval-uuid-1', status: 'pending', expires_at: '2026-05-23T00:00:00Z' },
};
