#!/bin/sh
# One-shot bootstrap for the demo profile: creates the first-run owner account,
# imports the workflow files next to this script and activates them. The owner
# password is generated per install and printed to this container's log.
#
# Uses n8n's REST API rather than the "n8n import:workflow" CLI: the REST path
# registers triggers and webhooks in the running process, while the CLI writes
# the database underneath a running instance.

set -eu

N8N_SEED_URL="${N8N_SEED_URL:-http://n8n-demo:5678}"
SEED_WORKFLOW_DIR="${SEED_WORKFLOW_DIR:-/demo/workflows}"
SEED_EMAIL="${SEED_EMAIL:-demo@example.com}"

export N8N_SEED_URL SEED_WORKFLOW_DIR SEED_EMAIL

if [ ! -d "$SEED_WORKFLOW_DIR" ]; then
	echo "[seed] no workflow directory at $SEED_WORKFLOW_DIR" >&2
	exit 1
fi

# node, not curl/wget: it is the one HTTP-capable runtime the n8n image is
# guaranteed to carry, and the owner-setup response cookie needs a client that
# exposes response headers.
SEED_JS=$(
	cat <<'NODE_SCRIPT'
const fs = require('fs');
const crypto = require('crypto');

const base = process.env.N8N_SEED_URL;
const dir = process.env.SEED_WORKFLOW_DIR;
const email = process.env.SEED_EMAIL;

const log = (message) => console.log('[seed] ' + message);
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

let cookie = '';

async function call(method, path, payload) {
	const headers = {};
	if (payload !== undefined) headers['content-type'] = 'application/json';
	if (cookie) headers.cookie = cookie;
	const response = await fetch(base + path, {
		method,
		headers,
		body: payload === undefined ? undefined : JSON.stringify(payload),
	});
	return {
		status: response.status,
		body: await response.text(),
		setCookie: response.headers.getSetCookie(),
	};
}

function data(response, what) {
	if (response.status !== 200) {
		throw new Error(what + ' failed with HTTP ' + response.status + ': ' + response.body);
	}
	return JSON.parse(response.body).data;
}

// /healthz answers as soon as the port is open; readiness also requires the
// database connected and migrated, so an early 503 is expected.
async function waitForReadiness() {
	const deadline = Date.now() + 240_000;
	while (Date.now() < deadline) {
		try {
			if ((await call('GET', '/healthz/readiness')).status === 200) return;
		} catch {
			// connection refused while the listener comes up
		}
		await sleep(2000);
	}
	throw new Error(base + ' did not report readiness within four minutes');
}

// n8n requires 8-64 chars with a digit and an uppercase letter; the fixed
// first and last character satisfy that.
function generatePassword() {
	return 'D' + crypto.randomBytes(18).toString('base64url').slice(0, 22) + '1';
}

// Returns false when the instance already has an owner, i.e. this script has
// run against this database before.
async function createOwner(password) {
	const settings = data(await call('GET', '/rest/settings'), 'reading /rest/settings');
	if (!settings.userManagement.showSetupOnFirstLoad) return false;
	const response = await call('POST', '/rest/owner/setup', {
		email,
		firstName: 'Demo',
		lastName: 'User',
		password,
	});
	if (response.status !== 200) {
		throw new Error('owner setup failed with HTTP ' + response.status + ': ' + response.body);
	}
	// the setup response carries the session cookie; no separate login step
	cookie = response.setCookie.map((entry) => entry.split(';')[0]).join('; ');
	if (!cookie) throw new Error('owner setup returned no session cookie');
	return true;
}

async function importWorkflow(file) {
	const source = JSON.parse(fs.readFileSync(dir + '/' + file, 'utf8'));
	const created = data(
		await call('POST', '/rest/workflows', {
			name: source.name,
			nodes: source.nodes,
			connections: source.connections,
			settings: source.settings,
		}),
		'creating the workflow in ' + file,
	);
	// PATCH {"active":true} answers 200 but does not activate; activation is
	// its own endpoint and needs the version id.
	data(
		await call('POST', '/rest/workflows/' + created.id + '/activate', {
			versionId: created.versionId,
		}),
		'activating ' + created.name,
	);
	log('imported and activated "' + created.name + '" as ' + created.id);
}

async function main() {
	log('waiting for ' + base + ' to report readiness');
	await waitForReadiness();

	const password = generatePassword();
	if (!(await createOwner(password))) {
		log('this instance already has an owner account, so it has been seeded before');
		log('nothing to do; "docker compose down -v" discards it and seeds a fresh one');
		return;
	}
	log('created the owner account ' + email);

	const files = fs.readdirSync(dir).filter((name) => name.endsWith('.json')).sort();
	if (files.length === 0) throw new Error('no workflow files in ' + dir);
	for (const file of files) await importWorkflow(file);

	log('the demo instance publishes no port; these credentials only matter if you publish one');
	log('  user:     ' + email);
	log('  password: ' + password);
	log('this password was generated for this installation and is printed only here');
}

main().catch((error) => {
	console.error('[seed] ' + error.message);
	process.exit(1);
});
NODE_SCRIPT
)

exec node -e "$SEED_JS"
