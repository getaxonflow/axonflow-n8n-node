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
	/** The node version; 2 (a node created now) unless a test says otherwise. */
	typeVersion?: number;
}

async function run(runArgs: Run) {
	const { params, response, continueOnFail = false } = runArgs;
	const typeVersion = 'typeVersion' in runArgs ? runArgs.typeVersion : 2;
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
		getNode: () => ({ name: 'AxonFlow1', typeVersion }),
		getWorkflowDataProxy: () => ({ $runIndex: 0 }),
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
		'AxonFlow refused the request: a limit was reached (HTTP 403, limit_type "feature_pro_only"): LLM cost pre-flight is a Pro feature — see what a multi-step plan will cost before it runs.',
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
			'AxonFlow refused the request: a rate limit was reached (HTTP 429, limit_type "daily_quota", resets at 2026-09-17T00:00:00Z, retry after 3600 s): Daily request limit reached. Resets at midnight UTC.',
		);
		assert.equal(err.httpCode, '429', 'n8n Retry On Fail observes the status');
	});
}

test('429 WITHOUT the envelope (a per-minute limit) names the limit and the Retry-After only', async () => {
	const err = await errorOf({ params: CHECK_POLICY, response: wire(429, PER_MINUTE_429, { 'retry-after': '60' }) });
	assert.equal(
		err.message,
		'AxonFlow refused the request: a rate limit was reached (HTTP 429, retry after 60 s): Rate limit exceeded (60 req/min). Try again shortly.',
	);
});

test('429 with neither envelope nor Retry-After is still named a rate limit', async () => {
	const err = await errorOf({ params: CHECK_POLICY, response: wire(429, PER_MINUTE_429) });
	assert.equal(err.message, 'AxonFlow refused the request: a rate limit was reached (HTTP 429): Rate limit exceeded (60 req/min). Try again shortly.');
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
		`AxonFlow has no approval queue at this endpoint (HTTP 404): /api/v1/hitl/queue is served by AxonFlow Enterprise only, so a Community deployment cannot create an approval request (on Enterprise, check that the Endpoint is the AxonFlow agent): not_found: ${HITL_QUEUE_404.error_description}`,
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
		getNode: () => ({ name: 'AxonFlow1', typeVersion: 2 }),
		getWorkflowDataProxy: () => ({ $runIndex: 0 }),
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

test('saved workflows: the operation values are unchanged', () => {
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

async function defaultKeyFor(nodeName: string, executionId = '12345', runIndex = 0, statement = CHECK_POLICY.statement): Promise<string> {
	const requests: Json[] = [];
	const ctx = {
		getInputData: () => [{ json: {} }],
		getCredentials: async () => ({ endpoint: 'https://axonflow.local', clientId: 'c', userToken: 't' }),
		getNodeParameter: (name: string, _i: number, fallback?: unknown) =>
			name === 'statement' ? statement : name in CHECK_POLICY && name !== 'idempotencyKey' ? (CHECK_POLICY as Json)[name] : fallback,
		getNode: () => ({ name: nodeName, typeVersion: 2 }),
		getWorkflowDataProxy: () => ({ $runIndex: runIndex }),
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

const H = '[0-9a-f]{8}';

test('default key: <execution>-<item>-<run>-<name>-<request hash>; a valid node name is used unchanged', async () => {
	assert.match(await defaultKeyFor('AxonFlow'), new RegExp(`^12345-0-0-AxonFlow-${H}$`));
	assert.match(await defaultKeyFor('Node_1.v2:a/b-c'), new RegExp(`^12345-0-0-Node_1\\.v2:a/b-c-${H}$`));
});

test('default key: a name with spaces and parentheses becomes a key the platform accepts, with a hash of the name', async () => {
	const key = await defaultKeyFor('AxonFlow Record (Idempotent)');
	assert.match(key, PLATFORM_KEY);
	assert.match(key, new RegExp(`^12345-0-0-AxonFlow_Record__Idempotent_-${H}-${H}$`));
});

test('default key: two names that differ only in a replaced character get different keys', async () => {
	const a = await defaultKeyFor('Check Policy');
	const b = await defaultKeyFor('Check_Policy');
	assert.notEqual(a, b);
	assert.match(b, new RegExp(`^12345-0-0-Check_Policy-${H}$`));
	assert.match(a, PLATFORM_KEY);
});

test('default key: a non-ASCII name is accepted by the platform alphabet', async () => {
	assert.match(await defaultKeyFor('Prüfung – Richtlinie ✓'), PLATFORM_KEY);
});

test('default key: a very long name, or a very long execution id, is capped at 256 and still distinct', async () => {
	const long = 'x'.repeat(400);
	const key1 = await defaultKeyFor(long + 'a');
	const key2 = await defaultKeyFor(long + 'b');
	const key3 = await defaultKeyFor('AxonFlow', '9'.repeat(400));
	for (const key of [key1, key2, key3]) {
		assert.equal(key.length, 256);
		assert.match(key, PLATFORM_KEY);
	}
	assert.notEqual(key1, key2);
});

test('default key: a different statement in the same execution, item and run gets a different key (no replayed decision)', async () => {
	// A Loop Over Items with batch size 1 runs the node with the same execution
	// id and item index each time; AxonFlow replays a stored answer for a
	// repeated key without comparing bodies.
	const allow = await defaultKeyFor('AxonFlow', '12345', 0, 'SELECT 1');
	const deny = await defaultKeyFor('AxonFlow', '12345', 0, 'rm -rf /');
	assert.notEqual(allow, deny);
});

test('default key: the same statement in another run of the node gets a different key; a retry of the same call keeps its key', async () => {
	const run0 = await defaultKeyFor('AxonFlow', '12345', 0, 'SELECT 1');
	const run1 = await defaultKeyFor('AxonFlow', '12345', 1, 'SELECT 1');
	const run0again = await defaultKeyFor('AxonFlow', '12345', 0, 'SELECT 1');
	assert.notEqual(run0, run1);
	assert.equal(run0, run0again);
	assert.match(run1, new RegExp(`^12345-0-1-AxonFlow-${H}$`));
});

test('an explicit Idempotency Key is sent as given, even one the platform will refuse', async () => {
	const { requests } = await run({ params: { ...CHECK_POLICY, idempotencyKey: 'my key' }, response: wire(200, CHECK_INPUT_ALLOW) });
	assert.equal((requests[0].headers as Record<string, string>)['Idempotency-Key'], 'my key');
});

test('default key: the platform alphabet is case-sensitive, so names differing only in case get different keys', async () => {
	const a = await defaultKeyFor('A b');
	const b = await defaultKeyFor('A B');
	assert.notEqual(a, b);
	assert.match(a, new RegExp(`^12345-0-0-A_b-${H}-${H}$`));
	assert.match(b, new RegExp(`^12345-0-0-A_B-${H}-${H}$`));
});

test('default key: two invalid names that sanitise to the same text get different keys (the hash reads the ORIGINAL name)', async () => {
	const a = await defaultKeyFor('A B');
	const b = await defaultKeyFor('A(B');
	assert.match(a, new RegExp(`^12345-0-0-A_B-${H}-${H}$`));
	assert.match(b, new RegExp(`^12345-0-0-A_B-${H}-${H}$`));
	assert.notEqual(a, b);
});


// ─── On Deny: one default per node version ───────────────────────────────────

test('On Deny, version 1 with the option unset: a 403 deny STOPS the node with the reason and the decision named', async () => {
	const err = await errorOf({ params: CHECK_POLICY, response: wire(403, CHECK_INPUT_DENY), typeVersion: 1 });
	assert.equal(err.message, 'AxonFlow denied the request: explicit_constraint (decision 6090bc98-9703-41cf-8a0a-8585a9456f13)');
	assert.equal(err.httpCode, '403');
});

test('On Deny, version 1: failureMode open does not swallow a deny (a 4xx is rethrown, as before)', async () => {
	const err = await errorOf({ params: { ...CHECK_POLICY, failureMode: 'open' }, response: wire(403, CHECK_INPUT_DENY), typeVersion: 1 });
	assert.match(err.message, /^AxonFlow denied the request: explicit_constraint/);
});

test('On Deny, version 1 under continueOnFail: the item carries error and no allowed, so a false branch on allowed is never reached', async () => {
	const { item } = await run({ params: CHECK_POLICY, response: wire(403, CHECK_INPUT_DENY), typeVersion: 1, continueOnFail: true });
	assert.deepEqual(item, { error: 'AxonFlow denied the request: explicit_constraint (decision 6090bc98-9703-41cf-8a0a-8585a9456f13)' });
});

test('On Deny, version 2 with the option unset: a 403 deny is the item', async () => {
	const { item } = await run({ params: CHECK_POLICY, response: wire(403, CHECK_INPUT_DENY), typeVersion: 2 });
	assert.deepEqual(item, CHECK_INPUT_DENY);
});

test('On Deny set explicitly overrides the version default, both ways', async () => {
	const { item } = await run({ params: { ...CHECK_POLICY, onDeny: 'output' }, response: wire(403, CHECK_INPUT_DENY), typeVersion: 1 });
	assert.equal(item.allowed, false);
	const err = await errorOf({ params: { ...CHECK_POLICY, onDeny: 'error' }, response: wire(403, CHECK_INPUT_DENY), typeVersion: 2 });
	assert.match(err.message, /^AxonFlow denied the request: explicit_constraint/);
});

test('On Deny error: a deny with no block_reason and no decision_id still names itself', async () => {
	const err = await errorOf({ params: { ...CHECK_POLICY, onDeny: 'error' }, response: wire(403, { allowed: false }) });
	assert.equal(err.message, 'AxonFlow denied the request: no reason given');
});

test('On Deny error: control characters in the reason are removed from the message', async () => {
	const err = await errorOf({ params: { ...CHECK_POLICY, onDeny: 'error' }, response: wire(403, { allowed: false, block_reason: 'a\nb', decision_id: 'd1' }) });
	assert.equal(err.message, 'AxonFlow denied the request: a b (decision d1)');
});

test('On Deny error: a 200 with allowed:false (a platform older than v8) stops too; an allow never does', async () => {
	const err = await errorOf({ params: { ...CHECK_POLICY, onDeny: 'error' }, response: wire(200, { allowed: false, block_reason: 'old_deny' }) });
	assert.equal(err.message, 'AxonFlow denied the request: old_deny');
	const { item } = await run({ params: { ...CHECK_POLICY, onDeny: 'error' }, response: wire(200, CHECK_INPUT_ALLOW) });
	assert.equal(item.allowed, true);
});

test('On Deny applies to Check Policy only: an Audit Log 2xx body with allowed:false is passed through', async () => {
	const { item } = await run({ params: { ...RECORD_DECISION }, response: wire(201, { allowed: false, audit_id: 'a1' }), typeVersion: 1 });
	assert.equal(item.audit_id, 'a1');
});

test('the node declares versions 1 and 2, defaults new nodes to 2, and gives On Deny one default per version', () => {
	const d = new AxonFlow().description;
	assert.deepEqual(d.version, [1, 2]);
	assert.equal(d.defaultVersion, 2);
	const onDeny = d.properties.filter((p) => p.name === 'onDeny');
	const byVersion = Object.fromEntries(
		onDeny.map((p) => [String((p.displayOptions?.show?.['@version'] as number[])[0]), p.default]),
	);
	assert.deepEqual(byVersion, { '1': 'error', '2': 'output' });
});

// ─── 401 causes, approvals, transport errors ─────────────────────────────────

test('401 for a required per-user token names the organization rule, not the credential', async () => {
	// SOURCE-DERIVED: check-input answers an organization that requires a user
	// token, when none is sent, with sendErrorResponse("Invalid user token: token
	// required") (authenticator.go and run.go at axonflow-enterprise 76fb9d376).
	const err = await errorOf({ params: CHECK_POLICY, response: wire(401, { success: false, error: 'Invalid user token: token required' }) });
	assert.equal(err.message, 'AxonFlow refused the request (HTTP 401): this organization requires a per-user token, which the n8n node does not send: Invalid user token: token required');
});

test('a 401 for anything else still names the credential', async () => {
	const err = await errorOf({ params: CHECK_POLICY, response: wire(401, { success: false, error: 'Authentication required' }) });
	assert.match(err.message, /^AxonFlow rejected the credential \(HTTP 401\): Authentication required\. Check the Client ID/);
});

test('401 platform text ending in a period is not doubled', async () => {
	const err = await errorOf({ params: CHECK_POLICY, response: wire(401, { error: 'token expired.' }) });
	assert.equal(err.message, 'AxonFlow rejected the credential (HTTP 401): token expired. Check the Client ID and User Token of the AxonFlow API credential.');
});

test('waitForApproval 201 (spec shape): approval_id is the request_id UUID, request_id is added, raw keeps the integer id', async () => {
	const { item } = await run({ params: WAIT_FOR_APPROVAL, response: wire(201, HITL_CREATED) });
	assert.equal(item.approval_id, '8f14e45f-ceea-467a-9575-4bd3e1e5b0c1');
	assert.equal(item.request_id, '8f14e45f-ceea-467a-9575-4bd3e1e5b0c1');
	assert.equal(((item.raw as Json).data as Json).id, 42);
});

test('waitForApproval without request_id falls back to data.id (older platforms)', async () => {
	const { item } = await run({ params: WAIT_FOR_APPROVAL, response: wire(200, { success: true, data: { id: 'legacy-id', status: 'pending' } }) });
	assert.equal(item.approval_id, 'legacy-id');
	assert.equal(item.request_id, undefined);
});

test('a transport error as n8n reports it (httpCode ECONNREFUSED, not a number) is no_response under Open and rethrown under Closed', async () => {
	const { item } = await run({ params: CHECK_POLICY, response: noResponse() });
	assert.equal(item.cause, 'no_response');
	assert.equal('allowed' in item, false);
	await assert.rejects(run({ params: { ...CHECK_POLICY, failureMode: 'closed' }, response: noResponse() }), /ECONNREFUSED/);
});

test('On Deny with any value other than "output" stops on a deny (an expression resolving to nothing, a mistyped value)', async () => {
	for (const onDeny of ['', 'Error', 'stop', 'OUTPUT', null, 0]) {
		for (const typeVersion of [1, 2]) {
			const err = await errorOf({ params: { ...CHECK_POLICY, onDeny }, response: wire(403, CHECK_INPUT_DENY), typeVersion });
			assert.match(err.message, /^AxonFlow denied the request: explicit_constraint/, `onDeny=${JSON.stringify(onDeny)} v${typeVersion}`);
		}
	}
});

test('On Deny on a node with no typeVersion falls back to stop', async () => {
	const err = await errorOf({ params: CHECK_POLICY, response: wire(403, CHECK_INPUT_DENY), typeVersion: undefined as unknown as number });
	assert.match(err.message, /^AxonFlow denied the request/);
});

test('default key: the run index is read from the workflow data proxy', async () => {
	const requests: Json[] = [];
	const ctx = {
		getInputData: () => [{ json: {} }],
		getCredentials: async () => ({ endpoint: 'https://axonflow.local', clientId: 'c', userToken: 't' }),
		getNodeParameter: (name: string, _i: number, fallback?: unknown) =>
			name in CHECK_POLICY && name !== 'idempotencyKey' ? (CHECK_POLICY as Json)[name] : fallback,
		getNode: () => ({ name: 'AxonFlow', typeVersion: 2 }),
		getWorkflowDataProxy: () => ({ $runIndex: 7 }),
		getExecutionId: () => '5',
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
	assert.match((requests[0].headers as Record<string, string>)['Idempotency-Key'], /^5-0-7-AxonFlow-[0-9a-f]{8}$/);
});
