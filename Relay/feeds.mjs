// Temporary Linux collectors publish opaque state independently of SSH. The relay never gets the encryption key.
import { createHash, timingSafeEqual } from 'node:crypto';

const token = value => typeof value === 'string' && /^[A-Za-z0-9_-]{43}$/.test(value);
const digest = value => createHash('sha256').update(value).digest('hex');
const equal = (a, b) => typeof a === 'string' && typeof b === 'string' && a.length === b.length && timingSafeEqual(Buffer.from(a), Buffer.from(b));
const providers = value => Array.isArray(value) ? [...new Set(value.filter(v => ['Claude', 'Codex'].includes(v)))] : [];
const bodyLimit = 3_000_000, memoryLimit = 32_000_000;
const offlineLimit = 7 * 86400000;

export function createFeeds({ records = [], save = () => {}, packetStore = null, maxFeeds = 100, maintenanceEnabled = true } = {}) {
  const feeds = new Map(), attempts = new Map();
  for (const feed of records) feeds.set(feed.id, feed);
  const persist = () => {
    const records = [...feeds.values()].map(({ id, readerHash, publisherHash, seen, readerSeen, challenge, usageProviders, paused }) =>
      ({ id, readerHash, publisherHash, seen, readerSeen, challenge, usageProviders, paused }));
    return save(records);
  };
  const expire = () => {
    for (const [id, feed] of feeds) if (Date.now() - (feed.readerSeen || feed.seen) > offlineLimit) { feeds.delete(id); packetStore?.delete(id); }
    for (const [address, attempt] of attempts) if (Date.now() - attempt.at > 60000) attempts.delete(address);
  };
  const maintenance = maintenanceEnabled ? setInterval(() => { expire(); Promise.resolve(persist()).catch(() => {}); }, 60000) : null;
  maintenance?.unref();
  const reply = (res, code, value = {}) => res.writeHead(code, { 'Content-Type': 'application/json', 'Cache-Control': 'no-store',
    'Referrer-Policy': 'no-referrer', 'X-Content-Type-Options': 'nosniff' }).end(JSON.stringify(value));
  async function handle(req, res, path, address) {
    expire();
    const match = /^\/v1\/feeds\/([A-Za-z0-9_-]{43})$/.exec(path);
    if (!match) { reply(res, 404); return; }
    const current = attempts.get(address) || { at: Date.now(), count: 0 };
    if (Date.now() - current.at > 60000) { current.at = Date.now(); current.count = 0; }
    current.count++; attempts.set(address, current);
    if (current.count > 120) { reply(res, 429); return; }
    const id = match[1], credential = /^Bearer ([A-Za-z0-9_-]{43})$/.exec(req.headers.authorization || '')?.[1];
    if (!credential) { reply(res, 401); return; }
    let feed = feeds.get(id);
    const reader = feed && equal(feed.readerHash, digest(credential));
    const publisher = feed && equal(feed.publisherHash, digest(credential));
    if (req.method !== 'PUT' && !feed) { reply(res, 410, { stop: true }); return; }
    if (feed && !reader && !publisher) { reply(res, 403); return; }
    let value = {};
    if (['PUT', 'POST'].includes(req.method)) {
      let size = 0, chunks = [];
      const timer = setTimeout(() => req.destroy(), 15000);
      try {
        for await (const bytes of req) { size += bytes.length; if (size > (req.method === 'PUT' ? 4096 : bodyLimit)) { reply(res, 413); req.destroy(); return; } chunks.push(bytes); }
        value = JSON.parse(Buffer.concat(chunks).toString());
        if (!value || typeof value !== 'object' || Array.isArray(value)) { reply(res, 400); return; }
      } catch { if (!res.destroyed) reply(res, 400); return; }
      finally { clearTimeout(timer); }
    }
    if (req.method === 'PUT') {
      if (!token(value.publisherToken) || !token(value.challenge)) { reply(res, 400); return; }
      if (feed && (!reader || !equal(feed.publisherHash, digest(value.publisherToken)))) { reply(res, 403); return; }
      expire();
      if (!feed && feeds.size >= maxFeeds) { reply(res, 503); return; }
      feed ||= { id, readerHash: digest(credential), publisherHash: digest(value.publisherToken) };
      if (feed.challenge !== value.challenge) { delete feed.box; packetStore?.delete(id); }
      feed.challenge = value.challenge; feed.usageProviders = providers(value.usageProviders);
      feed.paused = false;
      feed.readerSeen = feed.seen = Date.now(); feeds.set(id, feed); await persist();
      reply(res, 200); return;
    }
    if (req.method === 'DELETE' && reader) {
      feeds.delete(id); packetStore?.delete(id); await persist(); reply(res, 200); return;
    }
    if (req.method === 'PATCH' && reader) {
      // Pause immediately invalidates the next upload. A new temporary process must be started to resume.
      feed.paused = req.headers['x-warden-paused'] === '1';
      if (feed.paused) { delete feed.box; delete feed.readerSeen; packetStore?.delete(id); }
      else feed.readerSeen = Date.now();
      await persist();
      reply(res, 200); return;
    }
    const configuration = { challenge: feed.challenge, usageProviders: feed.usageProviders || [] };
    if (publisher) {
      if (feed.paused || !feed.readerSeen || Date.now() - feed.readerSeen > offlineLimit) { reply(res, 200, { stop: true }); return; }
      if (req.method === 'GET') { reply(res, 200, configuration); return; }
      if (req.method === 'POST') {
        if (typeof value.box !== 'string' || value.box.length > bodyLimit - 64 || !/^[A-Za-z0-9_-]+$/.test(value.box)) { reply(res, 400); return; }
        const bytes = [...feeds.values()].reduce((sum, f) => sum + (f.box?.length || 0), 0) - (feed.box?.length || 0) + value.box.length;
        if (bytes > memoryLimit) { reply(res, 503); return; }
        packetStore?.set(id, value.box);
        feed.box = value.box; feed.seen = Date.now();
        reply(res, 200, configuration); return;
      }
    }
    if (req.method === 'GET' && reader) {
      feed.readerSeen = feed.seen = Date.now();
      if (!feed.savedAt || Date.now() - feed.savedAt > 60000) { feed.savedAt = Date.now(); await persist(); }
      reply(res, 200, { box: (packetStore ? packetStore.get(id) : feed.box) || null }); return;
    }
    reply(res, 405);
  }
  return { handle, close() { if (maintenance) clearInterval(maintenance); } };
}
