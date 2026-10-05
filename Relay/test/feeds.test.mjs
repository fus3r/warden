import test from 'node:test';
import assert from 'node:assert/strict';
import { randomBytes } from 'node:crypto';
import { mkdtempSync, readFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { createRelay } from '../server.mjs';

const token = () => randomBytes(32).toString('base64url');

test('HTTPS feed isolates publishing, viewing and revocation; restart retains hashes without telemetry', async t => {
  const directory = mkdtempSync(join(tmpdir(), 'warden-feed-'));
  let relay = createRelay({ dataDirectory: directory, publicOrigin: 'http://127.0.0.1' });
  async function start() { await new Promise(resolve => relay.server.listen(0, '127.0.0.1', resolve)); }
  await start();
  t.after(async () => { await relay.close(); rmSync(directory, { recursive: true, force: true }); });
  const room = token(), owner = token(), publisher = token(), challenge = token(), box = token();
  const request = async (credential, method, value, headers = {}) => fetch(`http://127.0.0.1:${relay.server.address().port}/v1/feeds/${room}`, {
    method, headers: { Authorization: `Bearer ${credential}`, 'Content-Type': 'application/json', ...headers },
    body: value ? JSON.stringify(value) : undefined
  });
  assert.equal((await request(owner, 'PUT', { publisherToken: publisher, challenge, usageProviders: ['Codex', 'private text'] })).status, 200);
  assert.equal((await request(token(), 'GET')).status, 403);
  assert.equal((await request(publisher, 'DELETE')).status, 405);
  assert.equal((await request(publisher, 'PUT', { publisherToken: publisher, challenge })).status, 403);
  assert.deepEqual(await (await request(publisher, 'GET')).json(), { challenge, usageProviders: ['Codex'] });
  assert.equal((await request(owner, 'POST', { box })).status, 405);
  assert.equal((await request(publisher, 'POST', { box, prompt: 'must not pass through' })).status, 200);
  assert.deepEqual(await (await request(owner, 'GET')).json(), { box });
  const saved = readFileSync(join(directory, 'feeds.json'), 'utf8');
  for (const secret of [owner, publisher, box, 'must not pass through']) assert.equal(saved.includes(secret), false);
  await relay.close(); relay = createRelay({ dataDirectory: directory, publicOrigin: 'http://127.0.0.1' }); await start();
  assert.deepEqual(await (await request(owner, 'GET')).json(), { box: null });
  assert.deepEqual(await (await request(publisher, 'GET')).json(), { challenge, usageProviders: ['Codex'] });
  await request(owner, 'PATCH', undefined, { 'X-Warden-Paused': '1' });
  assert.deepEqual(await (await request(publisher, 'POST', { box })).json(), { stop: true });
  assert.equal((await request(owner, 'DELETE')).status, 200);
  assert.equal((await request(publisher, 'POST', { box })).status, 410);
});

test('the Cloudflare Worker serves the same bounded authenticated feed protocol', async t => {
  const base = process.env.WARDEN_FEED_RELAY_URL;
  if (!base) { t.skip('Set WARDEN_FEED_RELAY_URL to the local Wrangler worker.'); return; }
  const room = token(), owner = token(), publisher = token(), challenge = token(), box = token();
  const request = (credential, method, value) => fetch(`${base}/v1/feeds/${room}`, { method,
    headers: { Authorization: `Bearer ${credential}`, 'Content-Type': 'application/json' }, body: value ? JSON.stringify(value) : undefined });
  t.after(() => request(owner, 'DELETE'));
  assert.equal((await request(owner, 'PUT', { publisherToken: publisher, challenge })).status, 200);
  assert.equal((await request(token(), 'GET')).status, 403);
  assert.deepEqual(await (await request(publisher, 'GET')).json(), { challenge, usageProviders: [] });
  assert.equal((await request(publisher, 'POST', { box })).status, 200);
  // Durable Objects may hibernate after ten idle seconds. The twenty-second Mac poll must still
  // see the latest publication when the runtime reconstructs the object between requests.
  await new Promise(resolve => setTimeout(resolve, 12000));
  assert.deepEqual(await (await request(owner, 'GET')).json(), { box });
  const large = 'A'.repeat(2_100_000);
  assert.equal((await request(publisher, 'POST', { box: large })).status, 200);
  assert.ok((await (await request(owner, 'GET')).json()).box === large, 'A bounded packet larger than one SQLite row must round-trip intact.');
  assert.equal((await request(owner, 'PUT', { publisherToken: publisher, challenge: token() })).status, 200);
  assert.deepEqual(await (await request(owner, 'GET')).json(), { box: null });
  await request(owner, 'DELETE');
  assert.equal((await request(publisher, 'POST', { box })).status, 410);
});
