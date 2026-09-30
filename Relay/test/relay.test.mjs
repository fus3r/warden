import test from 'node:test';
import assert from 'node:assert/strict';
import { once } from 'node:events';
import { mkdtempSync, readFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { randomBytes, createCipheriv, hkdfSync } from 'node:crypto';
import { WebSocket } from 'ws';
import { createRelay } from '../server.mjs';

const token = () => randomBytes(32).toString('base64url');
function inbox(socket) {
  const queue = [], waiting = [];
  socket.on('message', data => { const value = JSON.parse(data); const next = waiting.shift(); next ? next(value) : queue.push(value); });
  return async function next(type) {
    for (;;) {
      const value = queue.length ? queue.shift() : await new Promise(resolve => waiting.push(resolve));
      if (value.type === type) return value;
    }
  };
}
async function client(port, credentials) {
  const ws = new WebSocket(`ws://127.0.0.1:${port}/v1/socket`), next = inbox(ws);
  await once(ws, 'open'); ws.send(JSON.stringify(credentials));
  return { ws, next, send: value => ws.send(JSON.stringify(value)) };
}
async function startService(t, options = {}) {
  const dataDirectory = mkdtempSync(join(tmpdir(), 'warden-relay-'));
  let relay = createRelay({ dataDirectory, publicOrigin: 'https://phone.example.test', ...options });
  await new Promise(resolve => relay.server.listen(0, '127.0.0.1', resolve));
  t.after(async () => { await relay.close(); rmSync(dataDirectory, { recursive: true, force: true }); });
  return { get port() { return relay.server.address().port; }, dataDirectory,
    async restart() { await relay.close(); relay = createRelay({ dataDirectory, publicOrigin: 'https://phone.example.test', ...options }); await new Promise(resolve => relay.server.listen(0, '127.0.0.1', resolve)); } };
}

test('authenticated peers exchange only ciphertext; stolen room IDs and revoked tokens are rejected', { timeout: 10000 }, async t => {
  const service = await startService(t);
  const room = token(), owner = token(), phoneToken = token(), secret = randomBytes(32);
  const mac = await client(service.port, { role: 'mac', room, token: owner, phoneToken }); await mac.next('ready');
  const intruder = await client(service.port, { role: 'phone', room, token: token() });
  assert.equal((await once(intruder.ws, 'close'))[0], 1008);
  const phone = await client(service.port, { role: 'phone', room, token: phoneToken }); await phone.next('ready'); await mac.next('peer');
  const iv = randomBytes(12), cipher = createCipheriv('aes-256-gcm', hkdfSync('sha256', secret, room, 'warden.phone.toMac.v1', 32), iv);
  const box = Buffer.concat([iv, cipher.update('private command for this Mac'), cipher.final(), cipher.getAuthTag()]).toString('base64url');
  phone.send({ type: 'cipher', box, command: 'must not be forwarded' });
  assert.deepEqual(await mac.next('cipher'), { type: 'cipher', box });
  const saved = readFileSync(join(service.dataDirectory, 'rooms.json'), 'utf8');
  for (const value of [owner, phoneToken, secret.toString('base64url'), box, 'private command']) assert.equal(saved.includes(value), false);
  const closed = once(phone.ws, 'close'); mac.send({ type: 'revoke' }); assert.equal((await closed)[0], 1008);
  const oldQR = await client(service.port, { role: 'phone', room, token: phoneToken }); assert.equal((await once(oldQR.ws, 'close'))[0], 1008);
});

test('pairings and generic push subscriptions survive a relay restart, without duplicate push bursts', { timeout: 10000 }, async t => {
  const pushes = [], service = await startService(t, { sendPush: async subscription => pushes.push(subscription) });
  const room = token(), owner = token(), phoneToken = token();
  let mac = await client(service.port, { role: 'mac', room, token: owner, phoneToken }); await mac.next('ready');
  let phone = await client(service.port, { role: 'phone', room, token: phoneToken }); await phone.next('ready');
  const subscription = { endpoint: 'https://web.push.apple.com/test-fixture', keys: { p256dh: 'test', auth: 'test' } };
  phone.send({ type: 'subscribe', subscription }); await phone.next('subscribed');
  await service.restart();
  mac = await client(service.port, { role: 'mac', room, token: owner, phoneToken }); await mac.next('ready');
  phone = await client(service.port, { role: 'phone', room, token: phoneToken }); assert.equal((await phone.next('ready')).peer, true);
  mac.send({ type: 'notify', body: 'This must never be sent as a push payload' });
  mac.send({ type: 'notify' });
  await new Promise(resolve => setTimeout(resolve, 80));
  assert.deepEqual(pushes, [subscription]);
  const config = await (await fetch(`http://127.0.0.1:${service.port}/config`)).json(); assert.ok(config.vapidPublicKey);
  const page = await fetch(`http://127.0.0.1:${service.port}/`); assert.ok(page.headers.get('content-security-policy').includes("script-src 'self'"));
  assert.ok((await page.text()).includes('/remote.js'));
  assert.equal((await fetch(`http://127.0.0.1:${service.port}/icon-192.png`)).status, 200);
  assert.equal((await fetch(`http://127.0.0.1:${service.port}/icon-512.png`)).status, 200);
});

test('untrusted push endpoints and malformed protocol messages cannot reach internal services', { timeout: 10000 }, async t => {
  const service = await startService(t), room = token(), owner = token(), phoneToken = token();
  const mac = await client(service.port, { role: 'mac', room, token: owner, phoneToken }); await mac.next('ready');
  const phone = await client(service.port, { role: 'phone', room, token: phoneToken }); await phone.next('ready');
  phone.send({ type: 'subscribe', subscription: { endpoint: 'http://127.0.0.1/admin', keys: { p256dh: 'x', auth: 'x' } } });
  assert.equal((await once(phone.ws, 'close'))[0], 1008);
  const malformed = new WebSocket(`ws://127.0.0.1:${service.port}/v1/socket`); await once(malformed, 'open'); malformed.send('null');
  assert.equal((await once(malformed, 'close'))[0], 1008);
  assert.equal((await fetch(`http://127.0.0.1:${service.port}/health`)).status, 200);
});
