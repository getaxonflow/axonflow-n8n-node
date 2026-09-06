import { test } from 'node:test';
import assert from 'node:assert/strict';

import { buildPepHandshake, PEP_HANDSHAKE_HEADER, PEP_ID } from '../nodes/AxonFlow/pep-handshake';

/**
 * Golden vector captured from the PLATFORM's own shipped encoder
 * (contract.PEPHandshake.Encode, via the axonflow-enterprise runtime-e2e
 * client's -print-handshake mode), NOT regenerated from this module's output.
 *
 * This is the whole anti-drift mechanism. This repository cannot import the
 * contract package - it lives in a private repo - so pep-handshake.ts is a hand
 * transcription of a wire format, the drift class that bit five SDKs in
 * axonflow-enterprise#3603. A test that built its expectation by calling
 * buildPepHandshake would agree with whatever that function did, including
 * being wrong.
 */
const GOLDEN =
	'eyJwcm9maWxlX3ZlcnNpb24iOjEsInBlcF9pZCI6Im44bi1ub2RlIiwiYXVkaWVuY2UiOiJheG9uZmxvdy1kZWNpc2lvbi1wcm9vZiIsImNhcGFiaWxpdGllcyI6W119';
const AUDIENCE = 'axonflow-decision-proof';

test('the handshake encodes byte for byte as the platform encoder does', () => {
	assert.equal(buildPepHandshake(AUDIENCE), GOLDEN);
});

test('the node declares NO capabilities, because it performs no substitution', () => {
	// A field_redact obligation is discharged by substituting the platform's
	// engine-masked text for the original. This node performs no substitution:
	// checkPolicy returns the platform response as the node's output and the
	// surrounding workflow decides what to do with it. The node therefore cannot
	// ESTABLISH that the obligation will be discharged, and declaring
	// field_redact would tell the platform to allow the call on the strength of
	// a substitution the node does not perform.
	const doc = JSON.parse(Buffer.from(buildPepHandshake(AUDIENCE)!, 'base64url').toString('utf8'));
	assert.deepEqual(doc.capabilities, []);
	assert.equal(doc.pep_id, PEP_ID);
});

test('an empty declaration serialises as [] and never as an absent member', () => {
	// An OMITTED capabilities member is MALFORMED to the platform and refuses the
	// request; [] is a declaration. A conditional that dropped the member when
	// empty would turn every honest declaration into a 400, and the whole-string
	// comparison above would move with it - so this asserts the decoded shape.
	const raw = Buffer.from(buildPepHandshake(AUDIENCE)!, 'base64url').toString('utf8');
	assert.ok(raw.includes('"capabilities":[]'));
	assert.ok('capabilities' in JSON.parse(raw));
});

test('no identity or entitlement member reaches the wire', () => {
	// A PEP may declare what it CAN DO, never who it is or what it is entitled
	// to, and the platform refuses an unknown member outright.
	const doc = JSON.parse(Buffer.from(buildPepHandshake(AUDIENCE)!, 'base64url').toString('utf8'));
	assert.deepEqual(Object.keys(doc).sort(), ['audience', 'capabilities', 'pep_id', 'profile_version']);
});

test('no audience means no handshake at all', () => {
	// The nothing-changes-by-default arm.
	assert.equal(buildPepHandshake(undefined), undefined);
	assert.equal(buildPepHandshake(''), undefined);
});

test('a malformed audience throws rather than silently disabling the handshake', () => {
	// A value that quietly disabled the handshake would leave an operator
	// believing a control was in force when it was not.
	for (const bad of ['has spaces', '-leading-hyphen', 'a'.repeat(129), 'trailing\n']) {
		assert.throws(() => buildPepHandshake(bad), undefined, `audience ${JSON.stringify(bad)} was accepted`);
	}
});

test('the header is named exactly as the platform reads it', () => {
	assert.equal(PEP_HANDSHAKE_HEADER, 'X-Axonflow-PEP-Handshake');
});

test('the audience pattern is anchored to the WHOLE string, not the last line', () => {
	// The same grammar is hand-ported into five clients and the end anchor means
	// something different in each. Python's $ also matches just BEFORE a trailing
	// newline (it accepted "aud\n" until anchored with \A/\Z); shell's grep is
	// line-based (it accepted "aud\nhas spaces", putting a raw newline inside a
	// JSON string). JavaScript's $ is end-of-input without the m flag, so this
	// port is correct as written - but that is exactly the claim that goes stale
	// if someone adds the m flag, and the two sibling defects were invisible by
	// inspection because all three regexps were character-identical.
	for (const bad of ['aud\n', 'aud\nhas spaces', 'aud\r\n', '\naud']) {
		assert.throws(
			() => buildPepHandshake(bad),
			undefined,
			`audience ${JSON.stringify(bad)} was accepted; a multi-line value puts a raw newline inside a JSON string, which the platform refuses as a malformed handshake`,
		);
	}
});
