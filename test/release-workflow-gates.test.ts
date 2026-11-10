import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import test from 'node:test';

const workflowPath = join(__dirname, '..', '.github', 'workflows', 'release.yml');
const workflow = readFileSync(workflowPath, 'utf8');

function jobBlock(name: string, source = workflow): string {
	const lines = source.split(/\r?\n/);
	const start = lines.findIndex((line) => line === `  ${name}:`);
	assert.notEqual(start, -1, `release workflow must define the ${name} job`);

	let end = lines.length;
	for (let index = start + 1; index < lines.length; index += 1) {
		if (/^  [A-Za-z0-9_-]+:$/.test(lines[index])) {
			end = index;
			break;
		}
	}
	return lines.slice(start, end).join('\n');
}

function needsOf(name: string, source = workflow): string[] {
	const block = jobBlock(name, source);
	const inline = block.match(/^    needs:\s*\[([^\]]+)\]\s*$/m);
	const scalar = block.match(/^    needs:\s*([A-Za-z0-9_-]+)\s*$/m);
	assert.ok(inline || scalar, `${name} must declare explicit job dependencies`);
	return (inline?.[1] ?? scalar?.[1] ?? '')
		.split(',')
		.map((dependency) => dependency.trim())
		.filter(Boolean)
		.sort();
}

function assertPublishIsFailClosed(source = workflow): void {
	assert.deepEqual(needsOf('publish', source), ['build-and-test', 'lint', 'preflight', 'runtime-e2e']);
	assert.deepEqual(needsOf('runtime-e2e', source), ['build-and-test']);

	assert.doesNotMatch(
		jobBlock('publish', source),
		/^    if\s*:/m,
		'publish must use the default success() condition for its required jobs',
	);
	assert.doesNotMatch(
		jobBlock('runtime-e2e', source),
		/^\s+continue-on-error\s*:/m,
		'runtime-e2e must not allow a failing job or step to succeed',
	);
}

test('npm publish is fail-closed behind every release proof', () => assertPublishIsFailClosed());

test('the release gate rejects publish conditions that run after a failed dependency', () => {
	for (const condition of ['always()', '${{ !cancelled() }}']) {
		const bypassed = workflow.replace('  publish:\n', `  publish:\n    if: ${condition}\n`);
		assert.throws(
			() => assertPublishIsFailClosed(bypassed),
			/publish must use the default success\(\) condition/,
		);
	}
});

test('the release gate rejects a soft-failed runtime proof', () => {
	const bypassed = workflow.replace(
		'  runtime-e2e:\n',
		'  runtime-e2e:\n    continue-on-error: true\n',
	);
	assert.throws(
		() => assertPublishIsFailClosed(bypassed),
		/runtime-e2e must not allow a failing job or step to succeed/,
	);
});

test('public release and registry verification cannot outrun npm publish', () => {
	assert.deepEqual(needsOf('create-release'), ['preflight', 'publish']);
	assert.deepEqual(needsOf('verify-publish'), ['preflight', 'publish']);
});
