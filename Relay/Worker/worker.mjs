import { DurableObject } from 'cloudflare:workers';
import { createFeeds } from '../feeds.mjs';

/// The free-plan SQLite object stores routing hashes and the latest opaque packet, never encryption keys.
export class FeedRelay extends DurableObject {
  constructor(ctx, env) {
    super(ctx, env);
    const sql = ctx.storage.sql;
    sql.exec('CREATE TABLE IF NOT EXISTS feed_packets (id TEXT, part INTEGER, box TEXT, seen INTEGER, PRIMARY KEY (id, part))');
    const packetStore = {
      get(id) {
        sql.exec('DELETE FROM feed_packets WHERE seen < ?', Date.now() - 90000);
        return [...sql.exec('SELECT box FROM feed_packets WHERE id = ? ORDER BY part', id)].map(row => row.box).join('') || null;
      },
      set(id, box) {
        // A SQLite row is limited to 2 MB. At most two bounded chunks hold one packet, not a history.
        const width = 1_500_000, count = Math.ceil(box.length / width);
        ctx.storage.transactionSync(() => {
          sql.exec('DELETE FROM feed_packets WHERE id = ? AND part >= ?', id, count);
          for (let part = 0; part < count; part++) sql.exec(
            'INSERT INTO feed_packets VALUES (?, ?, ?, ?) ON CONFLICT (id, part) DO UPDATE SET box = excluded.box, seen = excluded.seen',
            id, part, box.slice(part * width, (part + 1) * width), Date.now());
        });
      },
      delete(id) { sql.exec('DELETE FROM feed_packets WHERE id = ?', id); }
    };
    ctx.blockConcurrencyWhile(async () => {
      this.feeds = createFeeds({ records: await ctx.storage.get('registrations') || [], maintenanceEnabled: false,
        packetStore, save: records => ctx.storage.put('registrations', records) });
    });
  }
  async fetch(request) {
    const reader = request.body?.getReader();
    const incoming = {
      headers: Object.fromEntries(request.headers), method: request.method,
      destroy() { reader?.cancel(); },
      async *[Symbol.asyncIterator]() {
        if (!reader) return;
        for (;;) { const { value, done } = await reader.read(); if (done) return; yield Buffer.from(value); }
      }
    };
    let status = 200, headers = {};
    return new Promise((resolve, reject) => {
      const outgoing = {
        writeHead(code, values) { status = code; headers = values; return this; },
        async end(value) {
          // Close an unread rejected upload before returning through the Workers request pipeline.
          try { await reader?.cancel(); } catch {}
          resolve(new Response(value, { status, headers }));
        }
      };
      this.feeds.handle(incoming, outgoing, new URL(request.url).pathname, request.headers.get('CF-Connecting-IP') || 'unknown').catch(reject);
    });
  }
}

export default {
  async fetch(request, env) {
    const path = new URL(request.url).pathname;
    if (request.method === 'GET' && path === '/health') return Response.json({ ok: true, service: 'warden-agent-relay' });
    if (!/^\/v1\/feeds\/[A-Za-z0-9_-]{43}$/.test(path)) return new Response(null, { status: 404 });
    // Finish the bounded upload before forwarding it. A rejected Durable Object request must not
    // leave a pipe reading the original HTTP body after this Worker has returned its response.
    if (request.body) {
      const reader = request.body.getReader(), chunks = [];
      let size = 0;
      const timer = setTimeout(() => reader.cancel(), 15000);
      try {
        for (;;) {
          const { value, done } = await reader.read();
          if (done) break;
          size += value.length;
          if (size > (request.method === 'POST' ? 3_000_000 : 4096)) {
            await reader.cancel(); return new Response(null, { status: 413 });
          }
          chunks.push(value);
        }
        request = new Request(request, { body: Buffer.concat(chunks) });
      } finally { clearTimeout(timer); }
    }
    return env.FEEDS.getByName('warden-feeds-v1').fetch(request);
  }
};
