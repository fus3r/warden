'use strict';
// The pairing key stays in the URL fragment and this device's local storage, never in an HTTP request.
window.WardenRemote = (() => {
  const storageKey = 'warden.remote.v1';
  const utf8 = new TextEncoder();
  const decode = text => Uint8Array.from(atob(text.replace(/-/g, '+').replace(/_/g, '/') + '='.repeat((4 - text.length % 4) % 4)), c => c.charCodeAt(0));
  const encode = bytes => btoa(String.fromCharCode(...bytes)).replace(/\+/g, '-').replace(/\//g, '_').replace(/=/g, '');
  let credentials, keys, socket, hooks, retry, challenge, client, sequence = -1, intentional = false;
  const requests = new Map();
  const valid = value => value && ['room', 'token', 'key'].every(k => typeof value[k] === 'string' && /^[A-Za-z0-9_-]{43}$/.test(value[k]));
  const status = text => hooks?.onStatus(text);
  async function derive() {
    const input = await crypto.subtle.importKey('raw', decode(credentials.key), 'HKDF', false, ['deriveKey']);
    const key = direction => crypto.subtle.deriveKey({ name: 'HKDF', hash: 'SHA-256', salt: utf8.encode(credentials.room), info: utf8.encode('warden.phone.' + direction + '.v1') }, input, { name: 'AES-GCM', length: 256 }, false, ['encrypt', 'decrypt']);
    keys = { toMac: await key('toMac'), toPhone: await key('toPhone') };
  }
  async function sendEncrypted(value) {
    if (socket?.readyState !== WebSocket.OPEN || !keys) throw new Error('The Mac is not connected.');
    const nonce = crypto.getRandomValues(new Uint8Array(12));
    const encrypted = new Uint8Array(await crypto.subtle.encrypt({ name: 'AES-GCM', iv: nonce }, keys.toMac, utf8.encode(JSON.stringify(value))));
    const packet = new Uint8Array(nonce.length + encrypted.length); packet.set(nonce); packet.set(encrypted, nonce.length);
    socket.send(JSON.stringify({ type: 'cipher', box: encode(packet) }));
  }
  async function receive(message) {
    if (message.type === 'ready' || message.type === 'peer') {
      if (!(message.peer ?? message.online)) { challenge = null; status('Your Mac is offline. Warden will reconnect when it is available.'); }
      return;
    }
    if (message.type === 'subscribed') { document.getElementById('remote-push-note').textContent = 'Notifications are enabled for this phone.'; return; }
    if (message.type !== 'cipher' || typeof message.box !== 'string' || message.box.length > 1000000) return;
    const bytes = decode(message.box);
    const value = JSON.parse(new TextDecoder().decode(await crypto.subtle.decrypt({ name: 'AES-GCM', iv: bytes.slice(0, 12) }, keys.toPhone, bytes.slice(12))));
    if (value.type === 'challenge' && typeof value.challenge === 'string') {
      challenge = value.challenge; client = crypto.randomUUID(); sequence = -1;
      await sendEncrypted({ type: 'hello', challenge, client, name: /iPad/.test(navigator.userAgent) ? 'iPad' : /iPhone/.test(navigator.userAgent) ? 'iPhone' : 'Phone' });
      return;
    }
    if (value.challenge !== challenge || value.client !== client) return;
    if (value.type === 'paired' && valid(value.credentials)) {
      credentials = value.credentials; localStorage.setItem(storageKey, JSON.stringify(credentials));
      const previous = socket; socket = null; previous?.close(); await connect(); return;
    }
    if (value.type === 'state' && Number.isInteger(value.sequence) && value.sequence > sequence && Array.isArray(value.state?.needsYou)) {
      sequence = value.sequence;
      localStorage.setItem(storageKey, JSON.stringify(credentials));
      hooks.onState(value.state);
    } else if (value.type === 'reply' && requests.has(value.id)) {
      const pending = requests.get(value.id); requests.delete(value.id); clearTimeout(pending.timer); pending.resolve(value.ok);
    }
  }
  async function connect() {
    clearTimeout(retry);
    if (!valid(credentials)) return pairingInstructions();
    intentional = false; challenge = null;
    const previous = socket; socket = null; previous?.close();
    await derive();
    const ws = new WebSocket(location.origin.replace(/^http/, 'ws') + '/v1/socket'); socket = ws;
    ws.onopen = () => {
      if (socket !== ws) return;
      status('Connecting to your Mac…');
      ws.send(JSON.stringify({ role: 'phone', room: credentials.room, token: credentials.token }));
      restorePush().catch(() => {});
    };
    // Preserve order across asynchronous Web Crypto calls.
    let chain = Promise.resolve();
    ws.onmessage = event => { chain = chain.then(() => socket === ws ? receive(JSON.parse(event.data)) : undefined).catch(() => status('This connection could not be verified. Pair again from your Mac.')); };
    ws.onclose = event => {
      if (socket !== ws || intentional) return;
      status(event.code === 1008 ? 'This pairing is no longer available. Pair again from your Mac.' : 'Connection interrupted. Reconnecting…');
      retry = setTimeout(() => connect().catch(() => status('Unable to connect. Try again.')), event.code === 1008 ? 15000 : 3000);
    };
    ws.onerror = () => {};
  }
  function pairingInstructions() {
    status('On your Mac, choose Phone → Pair a Phone, then scan the QR code. You can also paste its pairing link below.');
    const main = document.getElementById('offline');
    if (document.getElementById('remote-link')) return;
    const form = document.createElement('form'); form.className = 'group padded';
    const label = document.createElement('label'); label.textContent = 'Pairing link'; label.htmlFor = 'remote-link';
    const input = document.createElement('input'); input.id = 'remote-link'; input.type = 'url'; input.autocomplete = 'off'; input.placeholder = 'Paste the link copied from Warden'; input.style.width = '100%';
    const button = document.createElement('button'); button.type = 'submit'; button.className = 'button primary'; button.textContent = 'Pair this phone';
    form.append(label, input, button); main.append(form);
    form.addEventListener('submit', event => {
      event.preventDefault();
      try {
        const url = new URL(input.value);
        if (url.origin !== location.origin) throw new Error('Use the same Warden service as the link.');
        const next = JSON.parse(new TextDecoder().decode(decode(new URLSearchParams(url.hash.slice(1)).get('connect') || '')));
        if (!valid(next)) throw new Error('Invalid pairing link.');
        credentials = next; input.value = ''; connect().catch(() => status('Unable to connect.'));
      } catch (error) { status(error.message); }
    });
  }
  async function request(type, fields = {}) {
    if (!challenge) throw new Error('The Mac is not connected.');
    const id = crypto.randomUUID();
    const result = new Promise((resolve, reject) => {
      requests.set(id, { resolve, reject, timer: setTimeout(() => { requests.delete(id); reject(new Error('The Mac did not answer.')); }, 12000) });
    });
    try { await sendEncrypted({ ...fields, type, id, challenge, client }); }
    catch (error) { const pending = requests.get(id); if (pending) { clearTimeout(pending.timer); requests.delete(id); pending.reject(error); } }
    return result;
  }
  async function restorePush() {
    if (!('serviceWorker' in navigator) || !('PushManager' in window)) return;
    const registration = await navigator.serviceWorker.register('/sw.js');
    const subscription = await registration.pushManager.getSubscription();
    if (subscription && socket?.readyState === WebSocket.OPEN) socket.send(JSON.stringify({ type: 'subscribe', subscription }));
  }
  function pushControls() {
    const footer = document.querySelector('#content footer');
    const button = document.createElement('button'); button.type = 'button'; button.className = 'button'; button.textContent = 'Enable phone notifications';
    const note = document.createElement('p'); note.id = 'remote-push-note'; note.className = 'note';
    footer.prepend(button, note);
    button.onclick = async () => {
      button.disabled = true;
      try {
        if (!('PushManager' in window) || !('serviceWorker' in navigator)) throw new Error('On iPhone, add Warden to the Home Screen and open it there to enable notifications.');
        const permission = await Notification.requestPermission();
        if (permission !== 'granted') throw new Error('Notifications were not allowed. You can change this in your phone settings.');
        const config = await (await fetch('/config', { cache: 'no-store' })).json();
        if (!config.vapidPublicKey) throw new Error('Phone notifications are not configured on this service.');
        const registration = await navigator.serviceWorker.register('/sw.js');
        await navigator.serviceWorker.ready;
        const subscription = await registration.pushManager.getSubscription() || await registration.pushManager.subscribe({ userVisibleOnly: true, applicationServerKey: decode(config.vapidPublicKey) });
        if (socket?.readyState !== WebSocket.OPEN) throw new Error('Reconnect to your Mac, then try again.');
        socket.send(JSON.stringify({ type: 'subscribe', subscription }));
      } catch (error) { note.textContent = error.message; }
      finally { button.disabled = false; }
    };
  }
  return {
    async start(callbacks) {
      hooks = callbacks; pushControls();
      try {
        const pairing = new URLSearchParams(location.hash.slice(1)).get('connect');
        history.replaceState(null, '', location.pathname);
        credentials = pairing ? JSON.parse(new TextDecoder().decode(decode(pairing))) : JSON.parse(localStorage.getItem(storageKey) || 'null');
        if (valid(credentials)) await connect(); else pairingInstructions();
      } catch { pairingInstructions(); }
    },
    retry() { connect().catch(() => status('Unable to reconnect.')); },
    async post(path, body) {
      if (path === '/api/answer') return new Response('{}', { status: await request('answer', body) ? 200 : 409 });
      if (path === '/api/unpair') {
        if (!await request('unpair')) throw new Error('Could not unpair this device.');
        intentional = true; clearTimeout(retry); socket?.close(); localStorage.removeItem(storageKey); credentials = null;
        const registration = await navigator.serviceWorker?.getRegistration(); const subscription = await registration?.pushManager.getSubscription(); await subscription?.unsubscribe();
        pairingInstructions(); return new Response('{}', { status: 200 });
      }
      return new Response('{}', { status: 400 });
    },
  };
})();
