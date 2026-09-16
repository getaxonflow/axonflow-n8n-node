#!/usr/bin/env node
/**
 * Finds `producer | grep -q ...` in shell scripts that run under pipefail.
 *
 * THE DEFECT. `grep -q` (and -m, -l, -L) exits at its first match. If the
 * producer is still writing, it dies of SIGPIPE with status 141, and under
 * `set -o pipefail` that 141 is the pipeline's status: a pipeline that MATCHED
 * reports failure, so `if producer | grep -q X` takes the not-found branch.
 * Whether it fires depends on how much the producer has left to write, so it
 * is green almost everywhere and red now and then.
 *
 * THE FIX keeps the reader from leaving early: `grep -q X <<<"$VAR"` (no pipe),
 * or `producer | grep X >/dev/null` (grep reads to the end).
 *
 * SCOPE. A `.sh` file is in scope when it sets pipefail in code, lives under a
 * `lib/` or `_lib/` directory, or is sourced (`source f` / `. f`) by a scanned
 * file: a sourced helper runs with its caller's options.
 *
 * WHAT COUNTS AS A PIPE. A `|` in code: not in a comment, a single-quoted
 * string, a heredoc body, or a double-quoted string outside a `$(...)`. `||` is
 * not a pipe. A pipe that ends a line continues onto the next. A finding is
 * reported at the first physical line of its statement.
 *
 * Usage: lint-grep-q-under-pipefail.js PATH [PATH...]
 * Exit:  0 no findings, 1 findings, 2 usage or read error.
 */
'use strict';

const fs = require('node:fs');
const path = require('node:path');

const EARLY_EXIT_LONG = new Set(['--quiet', '--silent', '--max-count', '--files-with-matches', '--files-without-match']);
const GREPS = new Set(['grep', 'egrep', 'fgrep']);
// Commands that run the command after them with the same stdin, so
// `timeout 5 grep -q` is a grep reading the pipe: `takes` is how many leading
// non-option words the wrapper itself takes (timeout's duration), `valueOpts`
// its options whose value is the NEXT word (`nice -n 10`). xargs is
// deliberately absent: it reads the pipe itself and runs grep on the file names
// it collects, so an early grep exit does not signal the producer.
const COMMAND_WRAPPERS = new Map([
	['command', { takes: 0, valueOpts: [] }],
	['exec', { takes: 0, valueOpts: [] }],
	['nohup', { takes: 0, valueOpts: [] }],
	['time', { takes: 0, valueOpts: [] }],
	['env', { takes: 0, valueOpts: ['-u', '-C', '-S'] }],
	['nice', { takes: 0, valueOpts: ['-n'] }],
	['stdbuf', { takes: 0, valueOpts: ['-i', '-o', '-e'] }],
	['sudo', { takes: 0, valueOpts: ['-u', '-g', '-C', '-h', '-p'] }],
	['timeout', { takes: 1, valueOpts: ['-s', '-k'] }],
]);

function listShellFiles(target) {
	const stat = fs.statSync(target);
	if (stat.isFile()) return target.endsWith('.sh') ? [target] : [];
	const out = [];
	for (const entry of fs.readdirSync(target, { withFileTypes: true })) {
		if (entry.name === 'node_modules' || entry.name === '.git') continue;
		out.push(...listShellFiles(path.join(target, entry.name)));
	}
	return out.sort();
}

/**
 * Splits a script into code segments, dropping comments, single-quoted text,
 * heredoc bodies and double-quoted text outside command substitutions. Each
 * character of code keeps its physical line number.
 */
function codeOf(source) {
	const chars = []; // { c, line }
	const stack = ['code']; // code | dquote | subst
	let line = 1;
	let pendingHeredocs = [];
	let i = 0;
	const top = () => stack[stack.length - 1];
	const inCode = () => top() !== 'dquote';
	while (i < source.length) {
		const c = source[i];
		if (c === '\n') {
			chars.push({ c, line });
			line++;
			i++;
			if (pendingHeredocs.length) {
				for (const { word, strip } of pendingHeredocs) {
					while (i < source.length) {
						const end = source.indexOf('\n', i);
						const text = source.slice(i, end === -1 ? source.length : end);
						i = end === -1 ? source.length : end + 1;
						line++;
						if ((strip ? text.replace(/^\t+/, '') : text) === word) break;
					}
				}
				pendingHeredocs = [];
			}
			continue;
		}
		if (c === '\\' && i + 1 < source.length) {
			if (source[i + 1] === '\n') {
				chars.push({ c: ' ', line });
				line++;
				i += 2;
				continue;
			}
			if (inCode()) {
				// An escaped word character stays part of its word (`\grep` is
				// grep); an escaped metacharacter (`\|`) is not syntax, so it is
				// blanked.
				const next = source[i + 1];
				if ("|&;()<>'\"`$# \t\\".includes(next)) chars.push({ c: ' ', line }, { c: ' ', line });
				else chars.push({ c: '\\', line }, { c: next, line });
			}
			i += 2;
			continue;
		}
		if (top() === 'dquote') {
			if (c === '"') stack.pop();
			else if (c === '$' && source[i + 1] === '(' && source[i + 2] !== '(') {
				stack.push('subst');
				chars.push({ c: ' ', line }, { c: ' ', line });
				i += 2;
				continue;
			}
			i++;
			continue;
		}
		// code or subst
		if (c === '#' && (i === 0 || /[\s;|&(]/.test(source[i - 1]))) {
			while (i < source.length && source[i] !== '\n') i++;
			continue;
		}
		if (c === "'") {
			const end = source.indexOf("'", i + 1);
			const body = source.slice(i + 1, end === -1 ? source.length : end);
			line += (body.match(/\n/g) || []).length;
			chars.push({ c: ' ', line });
			i = end === -1 ? source.length : end + 1;
			continue;
		}
		if (c === '"') {
			stack.push('dquote');
			chars.push({ c: ' ', line });
			i++;
			continue;
		}
		if (c === '$' && source[i + 1] === '(' && source[i + 2] !== '(') {
			stack.push('subst');
			chars.push({ c: ';', line }, { c: ' ', line });
			i += 2;
			continue;
		}
		if (c === ')' && top() === 'subst') {
			stack.pop();
			chars.push({ c: ';', line });
			i++;
			continue;
		}
		if (c === '<' && source.startsWith('<<', i) && source[i + 2] !== '<') {
			const m = /^<<(-?)\s*(['"]?)([A-Za-z_][A-Za-z0-9_]*)\2/.exec(source.slice(i));
			if (m) {
				pendingHeredocs.push({ word: m[3], strip: m[1] === '-' });
				for (let k = 0; k < m[0].length; k++) chars.push({ c: ' ', line });
				i += m[0].length;
				continue;
			}
		}
		chars.push({ c, line });
		i++;
	}
	return chars;
}

function setsPipefail(source) {
	return codeOf(source)
		.map((x) => x.c)
		.join('')
		.split(/[\n;]/)
		// `set -euo pipefail`, `set -o errexit -o pipefail`, `set -e -o pipefail`
		.some((stmt) => /(^|\s)set\s+(\S+\s+)*-[A-Za-z]*o\s+pipefail\b/.test(stmt));
}

function sourcedNames(source) {
	const names = new Set();
	// The path is usually quoted ("$LIB_DIR/n8n-api.sh", or
	// "$(dirname "$0")/helpers.sh"), and quotes are not code, so this reads the
	// raw source: a `source` or `.` at the start of a statement, and the *.sh
	// name the rest of that line ends in.
	for (const m of source.matchAll(/(?:^|[;&|]|\bthen|\bdo|\belse)[ \t]*(?:source|\.)[ \t]+[^;&|\n]*?([A-Za-z0-9_.-]+\.sh)\b/gm)) {
		names.add(m[1]);
	}
	return names;
}

function isEarlyExitGrep(words) {
	let k = 0;
	while (k < words.length) {
		const w = words[k].replace(/^[({!]+/, '');
		if (w === '' || /^[A-Za-z_][A-Za-z0-9_]*=/.test(w)) {
			k++; // `{`, `(`, `!` on their own, or an assignment
			continue;
		}
		const name = path.posix.basename(w.replace(/^\\/, ''));
		if (COMMAND_WRAPPERS.has(name)) {
			const wrapper = COMMAND_WRAPPERS.get(name);
			k++;
			// the wrapper's own options (and the value of one that takes the next
			// word), then the words it takes itself
			while (k < words.length && words[k].startsWith('-')) {
				const takesValue = wrapper.valueOpts.includes(words[k]);
				k++;
				if (takesValue) k++;
			}
			k += wrapper.takes;
			continue;
		}
		if (!GREPS.has(name)) return false;
		break;
	}
	if (k >= words.length) return false;
	for (const raw of words.slice(k + 1)) {
		const w = raw.replace(/[;})]+$/, '');
		if (w === '--') break;
		if (EARLY_EXIT_LONG.has(w.split('=')[0])) return true;
		if (/^-[A-Za-z0-9]*[qmlL]/.test(w) && !w.startsWith('--')) return true;
	}
	return false;
}

function findingsIn(source) {
	const chars = codeOf(source);
	const findings = [];
	let stmtLine = null;
	for (let i = 0; i < chars.length; i++) {
		const { c, line } = chars[i];
		if (stmtLine === null && !/\s/.test(c)) stmtLine = line;
		if (c === '|' && chars[i + 1]?.c !== '|' && chars[i - 1]?.c !== '|') {
			let j = i + 1;
			if (chars[j]?.c === '&') j++;
			while (j < chars.length && /\s/.test(chars[j].c)) j++;
			let text = '';
			while (j < chars.length && !/[;|&\n)]/.test(chars[j].c)) text += chars[j++].c;
			if (isEarlyExitGrep(text.trim().split(/\s+/))) findings.push(stmtLine ?? line);
			continue;
		}
		if (c === '\n') {
			// A statement continues past a line that ends with a pipe or && / ||.
			let k = i - 1;
			while (k >= 0 && chars[k].c === ' ') k--;
			const prev = chars[k]?.c;
			if (prev !== '|' && prev !== '&') stmtLine = null;
		} else if (c === ';') {
			stmtLine = null;
		}
	}
	return [...new Set(findings)];
}

function scan(targets) {
	// Each file's path below the scan root it was found under: the lib/ scope
	// reads only directories inside the scan, never the checkout's own location.
	const rel = new Map();
	for (const t of targets) {
		for (const f of listShellFiles(t)) if (!rel.has(f)) rel.set(f, path.relative(t, f));
	}
	const files = [...rel.keys()];
	const sources = new Map(files.map((f) => [f, fs.readFileSync(f, 'utf8')]));
	const sourced = new Set();
	for (const text of sources.values()) for (const name of sourcedNames(text)) sourced.add(name);
	const inScope = files.filter(
		(f) =>
			setsPipefail(sources.get(f)) ||
			path.dirname(rel.get(f)).split(path.sep).some((part) => part === 'lib' || part === '_lib') ||
			sourced.has(path.basename(f)),
	);
	const findings = [];
	for (const f of inScope) {
		const lines = sources.get(f).split('\n');
		for (const ln of findingsIn(sources.get(f))) {
			findings.push({ file: f, line: ln, text: lines[ln - 1].trim() });
		}
	}
	return { files, inScope, findings };
}

module.exports = { scan };

if (require.main === module) {
	const targets = process.argv.slice(2);
	if (!targets.length) {
		console.error('usage: lint-grep-q-under-pipefail.js PATH [PATH...]');
		process.exit(2);
	}
	let result;
	try {
		result = scan(targets);
	} catch (error) {
		console.error(`lint-grep-q-under-pipefail: ${error.message}`);
		process.exit(2);
	}
	for (const f of result.findings) console.log(`${f.file}:${f.line}: ${f.text}`);
	console.log(`${result.files.length} script(s), ${result.inScope.length} in pipefail scope, ${result.findings.length} finding(s)`);
	process.exit(result.findings.length ? 1 : 0);
}
