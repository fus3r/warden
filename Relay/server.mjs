// One small relay for the publisher to host. Agent content is opaque authenticated ciphertext.
import http from 'node:http';
import { readFileSync, writeFileSync, renameSync, mkdirSync, existsSync } from 'node:fs';
import { resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { timingSafeEqual, createHash } from 'node:crypto';
import { WebSocketServer, WebSocket } from 'ws';
import { isIP } from 'node:net';
import webpush from 'web-push';

const here = dirname(fileURLToPath(import.meta.url));
const digest = value => createHash('sha256').update(value).digest('hex');
const token = value => typeof value === 'string' && /^[A-Za-z0-9_-]{43}$/.test(value);
const equal = (a, b) => typeof a === 'string' && typeof b === 'string' && a.length === b.length && timingSafeEqual(Buffer.from(a), Buffer.from(b));
const allowedPush = endpoint => {
  try {
    const u = new URL(endpoint);
    return u.protocol === 'https:' && !u.username && !u.password && (!u.port || u.port === '443') &&
      (u.hostname === 'fcm.googleapis.com' || u.hostname === 'updates.push.services.mozilla.com' || u.hostname.endsWith('.push.apple.com'));
  } catch { return false; }
};

export function createRelay({ dataDirectory, publicOrigin, phoneDirectory = resolve(here, '../Resources/Phone'),
                              maxRooms = 1000, trustProxy = false, sendPush } = {}) {
  const rooms = new Map();
  const file = dataDirectory && resolve(dataDirectory, 'rooms.json');
  const vapid = dataDirectory && resolve(dataDirectory, 'vapid.json');
  let vapidKeys;
  if (dataDirectory) {
    mkdirSync(dataDirectory, { recursive: true, mode: 0o700 });
    if (existsSync(file)) for (const record of JSON.parse(readFileSync(file, 'utf8'))) rooms.set(record.id, record);
    vapidKeys = existsSync(vapid) ? JSON.parse(readFileSync(vapid, 'utf8')) : webpush.generateVAPIDKeys();
    if (!existsSync(vapid)) writeFileSync(vapid, JSON.stringify(vapidKeys), { mode: 0o600 });
    webpush.setVapidDetails(process.env.VAPID_SUBJECT || (publicOrigin?.startsWith('https:') ? publicOrigin : 'mailto:warden@localhost'), vapidKeys.publicKey, vapidKeys.privateKey);
  }
  const persist = () => {
    if (!file) return;
    const records = [...rooms.values()].map(({ id, ownerHash, phoneHash, subscription, seen }) => ({ id, ownerHash, phoneHash, subscription, seen }));
    writeFileSync(file + '.new', JSON.stringify(records), { mode: 0o600 });
    renameSync(file + '.new', file);
  };
  const send = (ws, message) => { if (ws?.readyState === WebSocket.OPEN) ws.send(JSON.stringify(message)); };
  const headers = { 'Cache-Control': 'no-store', 'Referrer-Policy': 'no-referrer', 'X-Content-Type-Options': 'nosniff',
    'Content-Security-Policy': "default-src 'self'; script-src 'self'; connect-src 'self'; img-src 'self' data:; style-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'self'" };
  const assets = new Map();
  for (const [name, type] of [['index.html', 'text/html'], ['app.js', 'text/javascript'], ['app.css', 'text/css'], ['manifest.webmanifest', 'application/manifest+json'], ['icon.png', 'image/png'], ['icon-192.png', 'image/png'], ['icon-512.png', 'image/png']]) {
    const source = resolve(phoneDirectory, name);
    if (!existsSync(source)) continue;
    let data = readFileSync(source);
    if (name === 'index.html') data = Buffer.from(data.toString().replace('<script src="/app.js"', '<script src="/remote.js" defer></script>\n<script src="/app.js"'));
    assets.set('/' + name, { data, type });
  }
  for (const name of ['remote.js', 'sw.js']) assets.set('/' + name, { data: readFileSync(resolve(here, 'public', name)), type: 'text/javascript' });
  const server = http.createServer((req, res) => {
    let path;
    try { path = new URL(req.url, 'http://localhost').pathname; } catch { res.writeHead(400).end(); return; }
    if (req.method !== 'GET') { res.writeHead(405, headers).end(); return; }
    if (path === '/health') { res.writeHead(200, { ...headers, 'Content-Type': 'application/json' }).end('{"ok":true}'); return; }
    if (path === '/config') { res.writeHead(200, { ...headers, 'Content-Type': 'application/json' }).end(JSON.stringify({ vapidPublicKey: vapidKeys?.publicKey || null })); return; }
    const asset = assets.get(path === '/' ? '/index.html' : path);
    if (!asset) { res.writeHead(404, headers).end(); return; }
    res.writeHead(200, { ...headers, 'Content-Type': asset.type, ...(path === '/sw.js' ? { 'Service-Worker-Allowed': '/' } : {}) }).end(asset.data);
  });
  const wss = new WebSocketServer({ noServer: true, maxPayload: 1_000_000, perMessageDeflate: false });
  const attempts = new Map();
  server.on('upgrade', (req, socket, head) => {
    if (req.url !== '/v1/socket' || (req.headers.origin && publicOrigin && req.headers.origin !== publicOrigin)) { socket.destroy(); return; }
    const forwarded = req.headers['x-warden-client-ip'];
    const address = trustProxy && typeof forwarded === 'string' && isIP(forwarded) ? forwarded : req.socket.remoteAddress;
    const current = attempts.get(address) || { at: Date.now(), count: 0 };
    if (Date.now() - current.at > 60000) { current.at = Date.now(); current.count = 0; }
    current.count++; attempts.set(address, current);
    if (current.count > 60 || wss.clients.size >= maxRooms * 3) { socket.destroy(); return; }
    wss.handleUpgrade(req, socket, head, ws => wss.emit('connection', ws));
  });
  wss.on('connection', ws => {
    let room, role, budget = { at: Date.now(), count: 0 };
    const timer = setTimeout(() => ws.close(1008, 'Authentication required'), 5000);
    const reject = () => ws.close(1008, 'Connection refused');
    ws.on('error', () => {});
    ws.on('message', async bytes => {
      try {
      if (Date.now() - budget.at > 10000) budget = { at: Date.now(), count: 0 };
      if (++budget.count > 100) return reject();
      let message;
      try { message = JSON.parse(bytes.toString()); } catch { return reject(); }
      if (!message || typeof message !== 'object' || Array.isArray(message)) return reject();
      if (!room) {
        if (!['mac', 'phone'].includes(message.role) || !token(message.room) || !token(message.token)) return reject();
        role = message.role;
        const existing = rooms.get(message.room);
        if (role === 'mac') {
          if (!token(message.phoneToken)) return reject();
          if (existing && !equal(existing.ownerHash, digest(message.token))) return reject();
          if (!existing && rooms.size >= maxRooms) return reject();
          room = existing || { id: message.room, ownerHash: digest(message.token), phoneHash: digest(message.phoneToken) };
          if (!equal(room.phoneHash, digest(message.phoneToken))) return reject();
          rooms.set(room.id, room);
        } else {
          if (!existing || !equal(existing.phoneHash, digest(message.token))) return reject();
          room = existing;
        }
        clearTimeout(timer);
        room[role]?.close(1000, 'Reconnected');
        room[role] = ws; room.seen = Date.now(); persist();
        send(ws, { type: 'ready', peer: room[role === 'mac' ? 'phone' : 'mac']?.readyState === WebSocket.OPEN });
        send(room[role === 'mac' ? 'phone' : 'mac'], { type: 'peer', online: true });
        return;
      }
      room.seen = Date.now();
      if (message.type === 'cipher' && typeof message.box === 'string' && /^[A-Za-z0-9_-]+$/.test(message.box)) {
        const peer = room[role === 'mac' ? 'phone' : 'mac'];
        if (peer?.readyState === WebSocket.OPEN) send(peer, { type: 'cipher', box: message.box });
        else send(ws, { type: 'peer', online: false });
      } else if (message.type === 'subscribe' && role === 'phone') {
        const sub = message.subscription;
        if (!allowedPush(sub?.endpoint) || typeof sub?.keys?.p256dh !== 'string' || typeof sub?.keys?.auth !== 'string' || JSON.stringify(sub).length > 4096) return reject();
        room.subscription = sub; persist(); send(ws, { type: 'subscribed' });
      } else if (message.type === 'notify' && role === 'mac' && room.subscription && Date.now() - (room.lastPush || 0) >= 15000) {
        room.lastPush = Date.now();
        try {
          if (sendPush) await sendPush(room.subscription);
          else await webpush.sendNotification(room.subscription, JSON.stringify({ title: 'Warden needs you', body: 'Open Warden to see what is waiting on your Mac.' }), { TTL: 300, topic: 'warden-attention', timeout: 10000 });
        } catch (error) {
          if ([404, 410].includes(error.statusCode)) { delete room.subscription; persist(); }
        }
      } else if (message.type === 'revoke' && role === 'mac') {
        rooms.delete(room.id); persist(); room.phone?.close(1008, 'Unpaired'); ws.close(1000, 'Unpaired');
      }
      } catch { ws.close(1011, 'Service temporarily unavailable'); }
    });
    ws.on('close', () => {
      clearTimeout(timer);
      if (room?.[role] === ws) { delete room[role]; send(room[role === 'mac' ? 'phone' : 'mac'], { type: 'peer', online: false }); }
    });
  });
  const maintenance = setInterval(() => {
    const now = Date.now();
    for (const [address, attempt] of attempts) if (now - attempt.at > 60000) attempts.delete(address);
    for (const [id, room] of rooms) if (!room.mac && !room.phone && now - room.seen > 7 * 86400000) rooms.delete(id);
    for (const ws of wss.clients) {
      if (ws.isAlive === false) { ws.terminate(); continue; }
      ws.isAlive = false; ws.once('pong', () => { ws.isAlive = true; }); ws.ping();
    }
    try { persist(); } catch { console.error('Could not save relay pairings. Check storage permissions and free space.'); }
  }, 30000);
  maintenance.unref();
  return { server, close: async () => { clearInterval(maintenance); for (const ws of wss.clients) ws.terminate(); await new Promise(resolve => wss.close(resolve)); await new Promise(resolve => server.close(resolve)); } };
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const port = Number(process.env.PORT || 8787);
  const publicOrigin = process.env.PUBLIC_ORIGIN;
  if (!publicOrigin) throw new Error('Set PUBLIC_ORIGIN to the public HTTPS origin (or http://localhost for local development).');
  const url = new URL(publicOrigin);
  if (url.protocol !== 'https:' && !['localhost', '127.0.0.1'].includes(url.hostname)) throw new Error('Public deployments require HTTPS.');
  const relay = createRelay({ dataDirectory: resolve(process.env.DATA_DIR || './data'), publicOrigin, trustProxy: process.env.TRUST_PROXY === '1' });
  relay.server.listen(port, process.env.BIND_ADDRESS || '127.0.0.1', () => console.log(`Warden relay listening on port ${port}`));
}
