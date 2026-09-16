#!/usr/bin/env node
/**
 * execution-node-data.js <execution.json> <node name> <item|error>
 *
 * Prints one node's first output item (compact JSON), or its error message,
 * from a response of n8n's GET /rest/executions/:id. Prints nothing when the
 * node has no such output, so a caller's assertion on the printed value fails.
 *
 * n8n has returned the run data in two shapes: an object under `resultData`,
 * and a `data` string in the "flatted" encoding (a JSON array in which every
 * string inside an object or array is the index of the real value). Both are
 * read here, in one place, so no leg carries its own guess at the shape.
 */
'use strict';

const fs = require('node:fs');

function unflatten(input) {
	const done = new Map();
	const revive = (index) => {
		if (done.has(index)) return done.get(index);
		const value = input[index];
		if (typeof value !== 'object' || value === null) {
			done.set(index, value);
			return value;
		}
		const out = Array.isArray(value) ? [] : {};
		done.set(index, out);
		for (const key of Object.keys(value)) {
			const v = value[key];
			out[key] = typeof v === 'string' ? revive(Number(v)) : v;
		}
		return out;
	};
	return revive(0);
}

function runDataOf(response) {
	const execution = response && typeof response === 'object' && 'data' in response ? response.data : response;
	if (!execution || typeof execution !== 'object') return undefined;
	if (execution.resultData) return execution;
	let data = execution.data;
	if (typeof data === 'string') {
		try {
			data = unflatten(JSON.parse(data));
		} catch {
			return undefined;
		}
	}
	return data && typeof data === 'object' ? data : undefined;
}

const [file, nodeName, what] = process.argv.slice(2);
if (!file || !nodeName || (what !== 'item' && what !== 'error')) {
	console.error('usage: execution-node-data.js <execution.json> <node name> <item|error>');
	process.exit(2);
}
let response;
try {
	response = JSON.parse(fs.readFileSync(file, 'utf8'));
} catch {
	process.exit(0);
}
const data = runDataOf(response);
const run = data?.resultData?.runData?.[nodeName]?.[0];
if (what === 'item') {
	const json = run?.data?.main?.[0]?.[0]?.json;
	if (json !== undefined) process.stdout.write(JSON.stringify(json));
} else {
	const error = run?.error ?? (data?.resultData?.lastNodeExecuted === nodeName ? data?.resultData?.error : undefined);
	if (error && typeof error.message === 'string') process.stdout.write(error.message);
}
