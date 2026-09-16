import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';

import { AxonFlow } from '../nodes/AxonFlow/AxonFlow.node';
import {
	CHECK_INPUT_ALLOW,
	CHECK_INPUT_DENY,
	CHECK_INPUT_DENY_APPROVAL_REQUIRED,
	CHECK_INPUT_DENY_UNKNOWN_CONSTRAINT,
	DAILY_QUOTA_429,
	FEATURE_PRO_ONLY_403,
	HITL_CREATED,
	HITL_QUEUE_404,
	MIDDLEWARE_401,
	PER_MINUTE_429,
	TIER_LIMIT_402,
	WireResponse,
	n8nHelperAnswer,
	noResponse,
	wire,
} from './wire-fixtures';

/**
 * Every status-and-body combination the node can receive, one test each, and
 * each asserting the exact text or item a workflow sees: the whole defect in
 * axonflow-n8n-node#9 is WHICH words reach the user, so "it threw" proves
 * nothing here.
 */

type Json = Record<string, unknown>;

const CHECK_POLICY = {
	operation: 'checkPolicy',
	idempotencyKey: 'k',
	connectorType: 'n8n',
	statement: 'SELECT * FROM users; DROP TABLE users',
	mcpOperation: 'execute',
	parameters: '{}',
};

const WAIT_FOR_APPROVAL = {
	operation: 'waitForApproval',
	idempotencyKey: 'k',
	originalQuery: 'q',
	requestType: 'workflow_step',
	triggeredPolicyId: 'p',
	triggeredPolicyName: 'P',
	triggerReason: 'r',
	severity: 'low',
	limitWaitTime: 60,
	requestContext: '{}',
};

const RECORD_DECISION = {
	operation: 'recordDecision',
	idempotencyKey: 'k',
	toolName: 't',
	workflowId: 'w',
	stepId: 's',
	auditInput: '{}',
	auditOutput: '{}',
	auditSuccess: true,
	auditErrorMessage: '',
};

interface Run {
	params: Json;
	response: WireResponse | Error;
	continueOnFail?: boolean;
}

async function run({ params, response, continueOnFail = false }: Run) {
	const requests: Json[] = [];
	const ctx = {
		getInputData: () => [{ json: {} }],
		getCredentials: async () => ({
			endpoint: 'https://axonflow.local',
			clientId: 'tenant-abc',
			userToken: 'utok-xyz',
		}),
		getNodeParameter: (name: string, _i: number, fallback?: unknown) => {
			if (name in params) return params[name];
			if (fallback !== undefined) return fallback;
			throw new Error(`parameter not provided in fixture: ${name}`);
		},
		getNode: () => ({ name: 'AxonFlow1' }),
		getExecutionId: () => 'exec-1',
		continueOnFail: () => continueOnFail,
		helpers: {
			httpRequestWithAuthentication: async (
				_credential: string,
				opts: Json & { returnFullResponse?: boolean; ignoreHttpStatusErrors?: unknown },
			) => {
				requests.push(opts);
				return n8nHelperAnswer(response, opts);
			},
		},
	};
	// eslint-disable-next-line @typescript-eslint/no-explicit-any
	const result = (await (new AxonFlow().execute as any).call(ctx)) as Array<Array<{ json: Json }>>;
	return { item: result[0][0].json, requests };
}

async function errorOf(r: Run): Promise<Error & { httpCode?: string | null }> {
	try {
		await run(r);
	} catch (error) {
		return error as Error & { httpCode?: string | null };
	}
	assert.fail('expected the node to throw');
}

// ─── the request asks for the status and the body ───────────────────────────

for (const params of [CHECK_POLICY, WAIT_FOR_APPROVAL, RECORD_DECISION]) {
	test(`${params.operation}: asks n8n for the full response and no exception on an HTTP status`, async () => {
		const { requests } = await run({
			params,
			response: wire(200, params.operation === 'waitForApproval' ? HITL_CREATED : CHECK_INPUT_ALLOW),
		});
		assert.equal(requests[0].returnFullResponse, true);
		assert.equal(requests[0].ignoreHttpStatusErrors, true);
	});
}

// ─── Check Policy: a 403 carrying a decision is a decision ──────────────────

test('checkPolicy 403 with allowed:false emits the platform decision as the item, verbatim', async () => {
	const { item } = await run({ params: CHECK_POLICY, response: wire(403, CHECK_INPUT_DENY) });
	assert.deepEqual(item, CHECK_INPUT_DENY);
	assert.equal(item.allowed, false);
	assert.equal(item.block_reason, 'explicit_constraint');
	assert.equal(item.decision_id, '6090bc98-9703-41cf-8a0a-8585a9456f13');
	assert.deepEqual(item.policy_matches, CHECK_INPUT_DENY.policy_matches);
});

test('checkPolicy 403 carrying unknown_constraint: block_reason reaches the item in full', async () => {
	const { item } = await run({ params: CHECK_POLICY, response: wire(403, CHECK_INPUT_DENY_UNKNOWN_CONSTRAINT) });
	assert.equal(item.allowed, false);
	assert.equal(item.block_reason, CHECK_INPUT_DENY_UNKNOWN_CONSTRAINT.block_reason);
});

test('checkPolicy 403 carrying approval_required is a deny item (check-input has no hold)', async () => {
	const { item } = await run({ params: CHECK_POLICY, response: wire(403, CHECK_INPUT_DENY_APPROVAL_REQUIRED) });
	assert.equal(item.allowed, false);
	assert.match(String(item.block_reason), /^approval_required: /);
});

test('checkPolicy 403 deny: block_reason with control characters is passed through unmodified in the item', async () => {
	const block_reason = 'line one\nline two\u0007';
	const { item } = await run({ params: CHECK_POLICY, response: wire(403, { allowed: false, block_reason }) });
	assert.equal(item.block_reason, block_reason);
});

test('checkPolicy 403 deny: block_reason ABSENT still emits allowed:false and no invented reason', async () => {
	const { item } = await run({ params: CHECK_POLICY, response: wire(403, { allowed: false }) });
	assert.deepEqual(item, { allowed: false });
});

test('checkPolicy 403 deny: block_reason present but EMPTY is passed through as empty', async () => {
	const { item } = await run({ params: CHECK_POLICY, response: wire(403, { allowed: false, block_reason: '' }) });
	assert.deepEqual(item, { allowed: false, block_reason: '' });
});

test('checkPolicy 403 deny under failureMode closed is still a decision item, not an error', async () => {
	const { item } = await run({ params: { ...CHECK_POLICY, failureMode: 'closed' }, response: wire(403, CHECK_INPUT_DENY) });
	assert.equal(item.allowed, false);
});

test('checkPolicy 403 deny with continueOnFail is the decision item, not an error item', async () => {
	const { item } = await run({ params: CHECK_POLICY, response: wire(403, CHECK_INPUT_DENY), continueOnFail: true });
	assert.equal(item.allowed, false);
	assert.equal(item.error, undefined);
});

test('checkPolicy 403 with allowed:TRUE is not a decision: an error, never an allowed item', async () => {
	const err = await errorOf({ params: CHECK_POLICY, response: wire(403, { allowed: true, block_reason: 'x' }) });
	assert.equal(
		err.message,
		'AxonFlow answered HTTP 403 with allowed: true, which is not a decision the node can act on, so the request is treated as refused: x',
	);
});

test('checkPolicy 403 with the rate-limit envelope (feature_pro_only) is a tier limit, not a deny', async () => {
	const err = await errorOf({ params: CHECK_POLICY, response: wire(403, FEATURE_PRO_ONLY_403) });
	assert.equal(
		err.message,
		'AxonFlow refused the request: a tier limit was reached (HTTP 403, limit_type "feature_pro_only"): this feature requires the Pro tier',
	);
});

test('checkPolicy 403 with allowed ABSENT (a middleware refusal) is an error quoting the platform', async () => {
	const err = await errorOf({ params: CHECK_POLICY, response: wire(403, { error: 'tenant mismatch' }) });
	assert.equal(err.message, 'AxonFlow refused the request (HTTP 403): tenant mismatch');
});

test('checkPolicy 403 with allowed as a STRING "false" is not a decision (no type coercion)', async () => {
	const err = await errorOf({ params: CHECK_POLICY, response: wire(403, { allowed: 'false', error: 'odd' }) });
	assert.equal(err.message, 'AxonFlow refused the request (HTTP 403): odd');
});

test('a 403 deny body on a NON-check operation is an error (only check-input answers decisions)', async () => {
	const err = await errorOf({ params: RECORD_DECISION, response: wire(403, CHECK_INPUT_DENY) });
	assert.equal(err.message, 'AxonFlow refused the request (HTTP 403): explicit_constraint');
});

// ─── 2xx ────────────────────────────────────────────────────────────────────

test('checkPolicy 200 allowed:true passes through verbatim', async () => {
	const { item } = await run({ params: CHECK_POLICY, response: wire(200, CHECK_INPUT_ALLOW) });
	assert.deepEqual(item, CHECK_INPUT_ALLOW);
});

test('checkPolicy 200 with allowed ABSENT passes through without inventing allowed', async () => {
	const { item } = await run({ params: CHECK_POLICY, response: wire(200, { policies_evaluated: 0 }) });
	assert.equal('allowed' in item, false);
});

test('a 2xx without a JSON object body refuses to continue', async () => {
	const err = await errorOf({ params: CHECK_POLICY, response: wire(200, 'ok') });
	assert.equal(
		err.message,
		'AxonFlow answered HTTP 200 without a JSON object body, so the node cannot read a result from it.',
	);
});

test('a 2xx without a body under failureMode open is still an error, never a fallback item', async () => {
	await assert.rejects(run({ params: { ...CHECK_POLICY, failureMode: 'open' }, response: wire(204) }), /HTTP 204 without a JSON object body/);
});

// ─── 401 / 402 / 429 / other 4xx: named errors, rethrown under both modes ──

for (const failureMode of ['open', 'closed']) {
	test(`401 (failureMode ${failureMode}) names the credential and quotes the platform`, async () => {
		const err = await errorOf({ params: { ...CHECK_POLICY, failureMode }, response: wire(401, MIDDLEWARE_401) });
		assert.equal(
			err.message,
			'AxonFlow rejected the credential (HTTP 401): 401: invalid credentials. Check the Client ID and User Token of the AxonFlow API credential.',
		);
		assert.equal(err.httpCode, '401');
	});

	test(`402 (failureMode ${failureMode}) names the tier limit and quotes the platform`, async () => {
		const err = await errorOf({ params: { ...CHECK_POLICY, failureMode }, response: wire(402, TIER_LIMIT_402) });
		assert.equal(
			err.message,
			'AxonFlow refused the request: a tier limit of this deployment was reached (HTTP 402): ERR_TIER_LIMIT_SERVICE_PRINCIPAL: the community edition admits at most 5 service_principal(s) per organization and 5 are already admitted. Upgrade at https://getaxonflow.com/enterprise',
		);
	});

	test(`429 with the envelope (failureMode ${failureMode}) names the limit, limit_type and resets_at`, async () => {
		const err = await errorOf({
			params: { ...CHECK_POLICY, failureMode },
			response: wire(429, DAILY_QUOTA_429, { 'retry-after': '3600' }),
		});
		assert.equal(
			err.message,
			'AxonFlow refused the request: a rate limit was reached (HTTP 429, limit_type "daily_quota", resets at 2026-09-17T00:00:00Z, retry after 3600 s): daily request quota exceeded',
		);
		assert.equal(err.httpCode, '429', 'n8n Retry On Fail observes the status');
	});
}

test('429 WITHOUT the envelope (a per-minute limit) names the limit and the Retry-After only', async () => {
	const err = await errorOf({ params: CHECK_POLICY, response: wire(429, PER_MINUTE_429, { 'retry-after': '60' }) });
	assert.equal(
		err.message,
		'AxonFlow refused the request: a rate limit was reached (HTTP 429, retry after 60 s): rate limit exceeded',
	);
});

test('429 with neither envelope nor Retry-After is still named a rate limit', async () => {
	const err = await errorOf({ params: CHECK_POLICY, response: wire(429, PER_MINUTE_429) });
	assert.equal(err.message, 'AxonFlow refused the request: a rate limit was reached (HTTP 429): rate limit exceeded');
});

test('429 with a MALFORMED resets_at quotes it and marks it, and ignores a non-string limit_type', async () => {
	const err = await errorOf({
		params: CHECK_POLICY,
		response: wire(429, { error: 'quota', limit_type: 7, resets_at: 'tomorrow-ish' }, { 'retry-after': 'soon' }),
	});
	assert.equal(
		err.message,
		'AxonFlow refused the request: a rate limit was reached (HTTP 429, resets_at "tomorrow-ish" (not a date)): quota',
	);
});

test('429 with PRESENT-but-EMPTY limit_type and resets_at omits both', async () => {
	const err = await errorOf({ params: CHECK_POLICY, response: wire(429, { error: 'quota', limit_type: '', resets_at: '' }) });
	assert.equal(err.message, 'AxonFlow refused the request: a rate limit was reached (HTTP 429): quota');
});

test('401 with NO body still names the credential', async () => {
	const err = await errorOf({ params: CHECK_POLICY, response: wire(401) });
	assert.equal(
		err.message,
		'AxonFlow rejected the credential (HTTP 401): (the response carried no error text). Check the Client ID and User Token of the AxonFlow API credential.',
	);
});

test('401 on Record Decision names the credential too (one decision point for every operation)', async () => {
	const err = await errorOf({ params: RECORD_DECISION, response: wire(401, { success: false, error: 'unauthorized' }) });
	assert.match(err.message, /^AxonFlow rejected the credential \(HTTP 401\): unauthorized\./);
});

test('422 quotes the platform', async () => {
	const err = await errorOf({ params: RECORD_DECISION, response: wire(422, { message: 'tool_name is required' }) });
	assert.equal(err.message, 'AxonFlow refused the request (HTTP 422): tool_name is required');
});

test('the quoted platform text has control characters removed and is capped', async () => {
	const long = `bad\u0000\nthing ${'x'.repeat(600)}`;
	const err = await errorOf({ params: CHECK_POLICY, response: wire(400, { error: long }) });
	assert.ok(!/[\u0000-\u001f\u007f]/.test(err.message), err.message);
	assert.ok(err.message.startsWith('AxonFlow refused the request (HTTP 400): bad thing xxx'));
	assert.ok(err.message.endsWith('…'));
});

test('platform text that contains a Node error code (ECONNREFUSED) is not replaced by n8n canned text', async () => {
	const err = await errorOf({ params: CHECK_POLICY, response: wire(401, { error: 'upstream ECONNREFUSED to the identity store' }) });
	assert.match(err.message, /^AxonFlow rejected the credential \(HTTP 401\): upstream ECONNREFUSED to the identity store\./);
});

// ─── Wait for Approval on Community ─────────────────────────────────────────

test('waitForApproval 404 names the edition', async () => {
	const err = await errorOf({ params: WAIT_FOR_APPROVAL, response: wire(404, HITL_QUEUE_404) });
	assert.equal(
		err.message,
		`AxonFlow has no approval queue at this endpoint (HTTP 404): /api/v1/hitl/queue is served by AxonFlow Enterprise only, so a Community deployment cannot create an approval request: not_found: ${HITL_QUEUE_404.error_description}`,
	);
});

test('a 404 on Check Policy is NOT described as an edition problem', async () => {
	const err = await errorOf({ params: CHECK_POLICY, response: wire(404, '404 page not found\n') });
	assert.equal(err.message, 'AxonFlow refused the request (HTTP 404): 404 page not found');
});

test('a string error with no error_description is quoted alone (error_description ABSENT)', async () => {
	const err = await errorOf({ params: CHECK_POLICY, response: wire(400, { error: 'bad request' }) });
	assert.equal(err.message, 'AxonFlow refused the request (HTTP 400): bad request');
});

// ─── 5xx and no answer: failureMode, and the fallback item is never silent ──

test('5xx under failureMode open: _axonflow_unreachable plus governance and cause, allowed ABSENT', async () => {
	const { item } = await run({ params: { ...CHECK_POLICY, failureMode: 'open' }, response: wire(503, { error: 'policy store unavailable' }) });
	assert.deepEqual(item, {
		_axonflow_unreachable: true,
		governance: 'unavailable',
		cause: 'http_503',
		error: 'AxonFlow failed to process the request (HTTP 503): policy store unavailable',
		operation: 'checkPolicy',
	});
	assert.equal('allowed' in item, false, 'an allowed key would flip every saved IF on $json.allowed');
});

test('no response under failureMode open: cause no_response, allowed ABSENT', async () => {
	const { item } = await run({ params: CHECK_POLICY, response: noResponse() });
	assert.equal(item._axonflow_unreachable, true);
	assert.equal(item.governance, 'unavailable');
	assert.equal(item.cause, 'no_response');
	assert.equal('allowed' in item, false);
});

test('5xx under failureMode closed throws the named platform fault', async () => {
	const err = await errorOf({ params: { ...CHECK_POLICY, failureMode: 'closed' }, response: wire(500, { error: 'boom' }) });
	assert.equal(err.message, 'AxonFlow failed to process the request (HTTP 500): boom');
});

test('no response under failureMode closed throws', async () => {
	await assert.rejects(run({ params: { ...CHECK_POLICY, failureMode: 'closed' }, response: noResponse() }), /ECONNREFUSED/);
});

test('a helper that ignores returnFullResponse (a bare body) is refused, never read as a decision', async () => {
	const ctx = {
		getInputData: () => [{ json: {} }],
		getCredentials: async () => ({ endpoint: 'https://axonflow.local', clientId: 'c', userToken: 't' }),
		getNodeParameter: (name: string, _i: number, fallback?: unknown) =>
			name in CHECK_POLICY ? (CHECK_POLICY as Json)[name] : fallback,
		getNode: () => ({ name: 'AxonFlow1' }),
		getExecutionId: () => 'exec-1',
		continueOnFail: () => false,
		helpers: { httpRequestWithAuthentication: async () => ({ allowed: true }) },
	};
	await assert.rejects(
		// eslint-disable-next-line @typescript-eslint/no-explicit-any
		(new AxonFlow().execute as any).call(ctx),
		/returned no HTTP status/,
	);
});

// ─── saved workflows ────────────────────────────────────────────────────────

test('saved workflows: every parameter the shipped example and the runtime legs set still exists (key presence only)', () => {
	// This proves KEY PRESENCE against the node description, not that n8n loads
	// the workflow; the runtime legs prove that.
	const described = new AxonFlow().description;
	const params = new Set(described.properties.map((p) => p.name));
	const operations = new Set(
		(described.properties.find((p) => p.name === 'operation')?.options ?? []).map((o) => (o as { value: string }).value),
	);
	const root = join(__dirname, '..');
	const files = [
		'examples/governed-loan-workflow.json',
		'runtime-e2e/check-policy-operation-hits-axonflow/workflow.json',
		'runtime-e2e/failure-mode-open-vs-closed/workflow-open.json',
		'runtime-e2e/record-decision-writes-audit-row/workflow.json',
	];
	let checked = 0;
	for (const file of files) {
		const workflow = JSON.parse(readFileSync(join(root, file), 'utf8')) as { nodes: Array<{ type: string; parameters: Json }> };
		for (const node of workflow.nodes.filter((n) => /\.axonFlow$/.test(n.type))) {
			for (const key of Object.keys(node.parameters)) {
				assert.ok(params.has(key), `${file}: parameter ${key} no longer exists`);
			}
			assert.ok(operations.has(String(node.parameters.operation)), `${file}: operation ${String(node.parameters.operation)}`);
			checked++;
		}
	}
	assert.ok(checked >= 7, `expected the example's four nodes and the legs' nodes, checked ${checked}`);
});

test('saved workflows: the operation values and the unreachable item key are unchanged', () => {
	const values = (new AxonFlow().description.properties.find((p) => p.name === 'operation')?.options ?? []).map(
		(o) => (o as { value: string }).value,
	);
	assert.deepEqual([...values].sort(), ['auditLog', 'checkPolicy', 'recordDecision', 'waitForApproval']);
});

test('Wait for Approval copy says what the operation does on v11: creates a request and returns, no pause promised', () => {
	const option = (new AxonFlow().description.properties.find((p) => p.name === 'operation')?.options ?? []).find(
		(o) => (o as { value: string }).value === 'waitForApproval',
	) as { description: string; action: string };
	const copy = `${option.description} ${option.action}`;
	assert.doesNotMatch(copy, /pause the workflow until|Wait for HITL approval/);
	assert.match(option.description, /return at once/);
	assert.match(option.description, /Enterprise/);
});

// ─── the default Idempotency-Key is one the platform accepts ─────────────────

// platform/shared/idempotency/store.go: ^[A-Za-z0-9_.:\-/]+$, at most 256.
const PLATFORM_KEY = /^[A-Za-z0-9_.:\-/]+$/;

async function defaultKeyFor(nodeName: string, executionId = '12345'): Promise<string> {
	const requests: Json[] = [];
	const ctx = {
		getInputData: () => [{ json: {} }],
		getCredentials: async () => ({ endpoint: 'https://axonflow.local', clientId: 'c', userToken: 't' }),
		getNodeParameter: (name: string, _i: number, fallback?: unknown) =>
			name in CHECK_POLICY && name !== 'idempotencyKey' ? (CHECK_POLICY as Json)[name] : fallback,
		getNode: () => ({ name: nodeName }),
		getExecutionId: () => executionId,
		continueOnFail: () => false,
		helpers: {
			httpRequestWithAuthentication: async (_c: string, opts: Json & { returnFullResponse?: boolean; ignoreHttpStatusErrors?: unknown }) => {
				requests.push(opts);
				return n8nHelperAnswer(wire(200, CHECK_INPUT_ALLOW), opts);
			},
		},
	};
	// eslint-disable-next-line @typescript-eslint/no-explicit-any
	await (new AxonFlow().execute as any).call(ctx);
	return (requests[0].headers as Record<string, string>)['Idempotency-Key'];
}

test('default key: a valid node name is used unchanged (existing default keys do not move)', async () => {
	assert.equal(await defaultKeyFor('AxonFlow'), '12345-0-AxonFlow');
	assert.equal(await defaultKeyFor('Node_1.v2:a/b-c'), '12345-0-Node_1.v2:a/b-c');
});

test('default key: a name with spaces and parentheses becomes a key the platform accepts, with a hash', async () => {
	const key = await defaultKeyFor('AxonFlow Record (Idempotent)');
	assert.match(key, PLATFORM_KEY);
	assert.match(key, /^12345-0-AxonFlow_Record__Idempotent_-[0-9a-f]{8}$/);
});

test('default key: two names that differ only in a replaced character get different keys', async () => {
	const a = await defaultKeyFor('Check Policy');
	const b = await defaultKeyFor('Check_Policy');
	const c = await defaultKeyFor('Check-Policy');
	assert.notEqual(a, b);
	assert.equal(b, '12345-0-Check_Policy');
	assert.equal(c, '12345-0-Check-Policy');
	assert.match(a, PLATFORM_KEY);
});

test('default key: a non-ASCII name is accepted by the platform alphabet', async () => {
	const key = await defaultKeyFor('Prüfung – Richtlinie ✓');
	assert.match(key, PLATFORM_KEY);
});

test('default key: a very long name is capped at 256 and still distinct', async () => {
	const long = 'x'.repeat(400);
	const key1 = await defaultKeyFor(long + 'a');
	const key2 = await defaultKeyFor(long + 'b');
	assert.equal(key1.length, 256);
	assert.equal(key2.length, 256);
	assert.notEqual(key1, key2);
	assert.match(key1, PLATFORM_KEY);
});

test('an explicit Idempotency Key is sent as given, even one the platform will refuse', async () => {
	const { requests } = await run({ params: { ...CHECK_POLICY, idempotencyKey: 'my key' }, response: wire(200, CHECK_INPUT_ALLOW) });
	assert.equal((requests[0].headers as Record<string, string>)['Idempotency-Key'], 'my key');
});

test('default key: the platform alphabet is case-sensitive, so names differing only in case get different keys', async () => {
	const a = await defaultKeyFor('A b');
	const b = await defaultKeyFor('A B');
	assert.notEqual(a, b);
	assert.match(a, /^12345-0-A_b-[0-9a-f]{8}$/);
	assert.match(b, /^12345-0-A_B-[0-9a-f]{8}$/);
});
