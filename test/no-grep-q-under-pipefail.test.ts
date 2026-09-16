import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, readFileSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { basename, join } from 'node:path';

// eslint-disable-next-line @typescript-eslint/no-var-requires
const { scan } = require('../scripts/lint-grep-q-under-pipefail.js') as {
	scan: (targets: string[]) => {
		files: string[];
		inScope: string[];
		findings: Array<{ file: string; line: number; text: string }>;
	};
};

const FIXTURES = join(__dirname, 'fixtures', 'grep-q-pipefail');

test('spellings: every EXPECT line is reported once, at its own line, and nothing else', () => {
	const path = join(FIXTURES, 'positive', 'spellings.sh');
	const want = readFileSync(path, 'utf8')
		.split('\n')
		.map((text, i) => ({ text, line: i + 1 }))
		.filter(({ text }) => text.includes('# EXPECT') && !text.trim().startsWith('#'))
		.map(({ line }) => line);
	assert.ok(want.length >= 10, `only ${want.length} EXPECT lines`);
	assert.deepEqual(
		scan([join(FIXTURES, 'positive')]).findings.map((f) => f.line),
		want,
	);
});

for (const [dir, inScope, findings] of [
	['suite', 1, []],
	['no-pipefail', 0, []],
	['lib', 1, ['helper.sh:6']],
	['sourced', 2, ['helpers.sh:5']],
] as Array<[string, number, string[]]>) {
	test(`control ${dir}: ${inScope} in scope, findings ${JSON.stringify(findings)}`, () => {
		const result = scan([join(FIXTURES, 'control', dir)]);
		assert.equal(result.inScope.length, inScope, JSON.stringify(result.inScope));
		assert.deepEqual(
			result.findings.map((f) => `${basename(f.file)}:${f.line}`),
			findings,
		);
	});
}

test('a planted producer | grep -q in a clean pipefail script is reported', () => {
	const dir = mkdtempSync(join(tmpdir(), 'grep-q-plant-'));
	writeFileSync(join(dir, 'planted.sh'), '#!/usr/bin/env bash\nset -euo pipefail\nV=x\nif docker ps | grep -q axonflow; then :; fi\n');
	const result = scan([dir]);
	assert.deepEqual(
		result.findings.map((f) => f.line),
		[4],
	);
});

test('the runtime-e2e harness has no producer | grep -q under pipefail', () => {
	const result = scan([join(__dirname, '..', 'runtime-e2e')]);
	assert.ok(result.inScope.length >= 15, `only ${result.inScope.length} scripts in scope; a scanner that reads nothing cannot pass`);
	assert.deepEqual(
		result.findings.map((f) => `${f.file}:${f.line}: ${f.text}`),
		[],
	);
});
