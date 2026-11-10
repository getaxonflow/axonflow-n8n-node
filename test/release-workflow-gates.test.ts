import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import test from 'node:test';

const workflowPath = join(__dirname, '..', '.github', 'workflows', 'release.yml');
const workflow = readFileSync(workflowPath, 'utf8');

function jobBlock(name: string): string {
	const lines = workflow.split(/\r?\n/);
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

function needsOf(name: string): string[] {
	const block = jobBlock(name);
	const inline = block.match(/^    needs:\s*\[([^\]]+)\]\s*$/m);
	const scalar = block.match(/^    needs:\s*([A-Za-z0-9_-]+)\s*$/m);
	assert.ok(inline || scalar, `${name} must declare explicit job dependencies`);
	return (inline?.[1] ?? scalar?.[1] ?? '')
		.split(',')
		.map((dependency) => dependency.trim())
		.filter(Boolean)
		.sort();
}

test('npm publish is fail-closed behind every release proof', () => {
	assert.deepEqual(needsOf('publish'), ['build-and-test', 'lint', 'preflight', 'runtime-e2e']);
	assert.deepEqual(needsOf('runtime-e2e'), ['build-and-test']);
});

test('public release and registry verification cannot outrun npm publish', () => {
	assert.deepEqual(needsOf('create-release'), ['preflight', 'publish']);
	assert.deepEqual(needsOf('verify-publish'), ['preflight', 'publish']);
});
