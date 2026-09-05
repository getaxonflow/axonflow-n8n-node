/**
 * The ADR-065 PEP capability handshake, client side
 * (getaxonflow/axonflow-enterprise#3763).
 *
 * The node tells the platform WHAT IT CAN DISCHARGE, on every governed call, as
 * a base64url-encoded JSON document in one request header. A platform that
 * would attach a mandatory obligation this node has declared it cannot carry
 * out DENIES the request, rather than handing the content over and trusting the
 * node to cope (ADR-065 invariant 8).
 *
 * # WHY THIS NODE DECLARES NOTHING, AND WHY THAT IS THE HONEST ANSWER
 *
 * A `field_redact` obligation is discharged by substituting the platform's
 * engine-masked text for the original before the content moves on. ADR-056
 * forbids a client from redacting for itself, so substitution is the only
 * sanctioned discharge.
 *
 * This node performs no substitution anywhere. `checkPolicy` returns the
 * platform's response as the node's output and the surrounding n8n workflow
 * decides what to do with it; there is no `redacted` handling in `nodes/` at
 * all. Whether the masked statement is ever used is a property of a workflow
 * this package does not own and cannot see.
 *
 * So the node cannot ESTABLISH that the obligation will be discharged, and
 * under ADR-065 a PEP declares what it can discharge rather than what a
 * downstream consumer might choose to do. Declaring `field_redact` here would
 * be precisely the self-asserted claim the design refuses: the platform would
 * ALLOW the call believing a substitution was coming, and a workflow that
 * simply forwards `statement` would send the unredacted original while the
 * audit row recorded a redaction that never reached the wire.
 *
 * Declaring the empty set makes the platform DENY instead. That is a visible
 * refusal an operator can act on, in place of a silent leak.
 *
 * This is a statement about the NODE, not about n8n users. A workflow that does
 * substitute `redacted_statement` is doing the right thing; the node still
 * cannot promise on its behalf.
 *
 * # WHY THIS RE-IMPLEMENTS AN ENCODER THAT EXISTS
 *
 * The canonical encoder is `contract.PEPHandshake.Encode` in a PRIVATE
 * repository this public one cannot import, so this is a hand transcription of
 * a wire format - the drift class that bit five SDKs in
 * axonflow-enterprise#3603. `pep-handshake.test.ts` therefore asserts the exact
 * bytes against a vector captured from the platform's own shipped encoder.
 */

/** The request header a declaration rides on. */
export const PEP_HANDSHAKE_HEADER = 'X-Axonflow-PEP-Handshake';

/**
 * The only profile this build emits. The platform matches it with EXACT
 * equality, never as a floor or a range.
 */
const PROFILE_VERSION = 1;

/**
 * This enforcement point's name inside the caller's credential namespace.
 *
 * It carries no colon: the platform composes `client:<credential>:<pep_id>`,
 * so admitting one would let a name appear inside an identifier that no string
 * search could tell apart from a real in-process plane.
 */
export const PEP_ID = 'n8n-node';

/** The platform refuses a header value longer than this. */
const MAX_HANDSHAKE_BYTES = 4096;

/** Bounds the operator-supplied audience before it can reach the wire. */
const AUDIENCE_PATTERN = /^[A-Za-z0-9][A-Za-z0-9._:-]*$/;

export interface PepCapability {
	type: string;
	version: number;
}

/**
 * The wire document. EVERY member is required.
 *
 * `capabilities` in particular is always serialised. An OMITTED member is
 * MALFORMED to the platform and refuses the request, while `[]` is the
 * legitimate declaration "I discharge nothing" - different facts with
 * different outcomes, and collapsing them is the defect the handshake exists
 * to close.
 */
interface PepHandshakeDoc {
	profile_version: number;
	pep_id: string;
	audience: string;
	capabilities: PepCapability[];
}

/**
 * Renders the declaration as the header value, or returns undefined when no
 * audience is configured.
 *
 * # WHY AN AUDIENCE IS REQUIRED RATHER THAN DEFAULTED
 *
 * The audience is what a decision proof gets bound to and only the DEPLOYMENT
 * knows it; a node that invented one would assert a binding nobody asked for.
 * It is also why the handshake is opt-in: on an Enterprise platform the
 * transition it gates is ALLOW -> DENY for a governed call the platform would
 * have masked. Undefined means no header, and the node then behaves byte for
 * byte as it did before.
 *
 * Throws on a malformed audience rather than silently omitting the header: a
 * value that quietly disabled the handshake would leave an operator believing
 * a control was in force when it was not.
 */
export function buildPepHandshake(audience: string | undefined): string | undefined {
	if (!audience) {
		return undefined;
	}
	if (audience.length > 128 || !AUDIENCE_PATTERN.test(audience)) {
		throw new Error(
			`invalid AxonFlow PEP audience ${JSON.stringify(audience)}: ` +
				`1-128 bytes matching ${AUDIENCE_PATTERN}`,
		);
	}

	const doc: PepHandshakeDoc = {
		profile_version: PROFILE_VERSION,
		pep_id: PEP_ID,
		audience,
		// Empty, and non-omitted. See the file comment for why this node cannot
		// honestly claim to discharge a redaction.
		capabilities: [],
	};

	const encoded = Buffer.from(JSON.stringify(doc), 'utf8').toString('base64url');
	if (encoded.length > MAX_HANDSHAKE_BYTES) {
		throw new Error(
			`the AxonFlow PEP capability handshake encodes to ${encoded.length} bytes; ` +
				`the header carries at most ${MAX_HANDSHAKE_BYTES}`,
		);
	}
	return encoded;
}
