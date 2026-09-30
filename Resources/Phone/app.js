'use strict';

// Warden's phone page. It asks the Mac for its state and waits for changes, shows what needs you, and sends an
// answer only when you tap one. Everything that comes from an agent is set as text, never as markup.

const page = {
  version: null,
  data: null,
  skew: 0,
  failures: 0,
  request: null,
  wake: null,
  answered: new Map(),
  // Sessions answered from this phone, whose card keeps the answer until the Mac reports what happened next.
  recent: new Map(),
  seen: new Set(),
  firstRender: true,
};

const $ = (id) => document.getElementById(id);

function element(tag, className, text) {
  const node = document.createElement(tag);
  if (className) node.className = className;
  if (text !== undefined && text !== null) node.textContent = text;
  return node;
}

// A wait that Try Again or coming back to the page can cut short.
function pause(ms) {
  return new Promise((resolve) => {
    const timer = setTimeout(resolve, ms);
    page.wake = () => {
      clearTimeout(timer);
      resolve();
    };
  });
}

// Asks the Mac again at once.
function askNow() {
  if (window.WardenRemote) { window.WardenRemote.retry(); return; }
  if (page.wake) page.wake();
  if (page.request) page.request.abort();
}

// The Mac's clock, as the phone can best tell it.
function now() {
  return Date.now() - page.skew;
}

function age(iso) {
  const seconds = Math.max(0, (now() - Date.parse(iso)) / 1000);
  if (seconds < 60) return 'now';
  if (seconds < 3600) return `${Math.floor(seconds / 60)} min`;
  if (seconds < 86400) return `${Math.floor(seconds / 3600)} h`;
  return `${Math.floor(seconds / 86400)} d`;
}

// "Resets in 42 min", "Resets in 2 h 05", "Resets Monday".
function resetLine(iso) {
  const seconds = (Date.parse(iso) - now()) / 1000;
  if (seconds <= 0) return 'Reset, awaiting a new reading';
  if (seconds < 3600) return `Resets in ${Math.max(1, Math.floor(seconds / 60))} min`;
  if (seconds < 86400) {
    const minutes = Math.floor((seconds % 3600) / 60);
    return `Resets in ${Math.floor(seconds / 3600)} h ${String(minutes).padStart(2, '0')}`;
  }
  return `Resets ${new Date(Date.parse(iso)).toLocaleDateString(undefined, { weekday: 'long' })}`;
}

function lowerFirst(text) {
  return text ? text.charAt(0).toLowerCase() + text.slice(1) : text;
}

function show(view) {
  for (const id of ['content', 'pairing', 'offline']) $(id).hidden = id !== view;
}

function plate(lantern, headline, subline) {
  const node = $('plate');
  node.dataset.lantern = lantern;
  $('headline').textContent = headline;
  $('subline').textContent = subline || '';
}

function flare() {
  const node = $('plate');
  node.classList.remove('flare');
  void node.offsetWidth;
  node.classList.add('flare');
}

// MARK: Rendering

function render(data) {
  page.data = data;
  page.skew = Date.now() - Date.parse(data.now);
  const needs = data.needsYou;
  const working = data.working;

  const count = needs.length;
  const headline = count === 0 ? 'Nothing needs you' : count === 1 ? '1 session needs you' : `${count} sessions need you`;
  const agents = working.length === 0 ? 'No agents working' : working.length === 1 ? '1 agent working' : `${working.length} agents working`;
  let subline = `${agents} on ${data.mac}`;
  if (data.snoozedUntil && Date.parse(data.snoozedUntil) > now()) {
    const until = new Date(Date.parse(data.snoozedUntil));
    const today = until.toDateString() === new Date(now()).toDateString();
    const when = until.toLocaleString([], today ? { hour: '2-digit', minute: '2-digit' } : { weekday: 'long', hour: '2-digit', minute: '2-digit' });
    subline += `. Alerts on the Mac are snoozed until ${when}`;
  }
  plate(count > 0 ? 'attention' : working.length > 0 ? 'working' : 'idle', headline, subline);

  // Answers already sent stay shown until the Mac reports the prompt gone.
  const waiting = new Set(needs.map((session) => session.prompt && session.prompt.id).filter(Boolean));
  for (const id of page.answered.keys()) if (!waiting.has(id)) page.answered.delete(id);

  let arrived = false;
  const cards = needs.map((session) => {
    const key = session.prompt ? session.prompt.id : `${session.id}:${session.since}`;
    const fresh = !page.firstRender && !page.seen.has(key);
    if (fresh) arrived = true;
    page.seen.add(key);
    return card(session, fresh);
  });
  $('needs-list').replaceChildren(...cards);
  $('needs').hidden = needs.length === 0;
  if (arrived) flare();

  $('working-list').replaceChildren(...working.map(workingRow));
  $('working').hidden = working.length === 0;

  $('limits-list').replaceChildren(...data.limits.map(limitRow));
  $('limits').hidden = data.limits.length === 0;
  page.firstRender = false;
  show('content');
}

function head(session) {
  const row = element('div', 'row-head');
  row.append(element('span', 'title', session.title || session.project), element('span', 'age', age(session.since)));
  return row;
}

function where(session) {
  return element('p', 'where', session.title ? `${session.agent} in ${session.project}` : session.agent);
}

function card(session, fresh) {
  const node = element('article', fresh ? 'card fresh' : 'card');
  node.append(head(session), where(session), element('p', 'status', session.status));
  const prompt = session.prompt;
  if (!prompt) {
    const recent = page.recent.get(session.id);
    if (recent && recent.until > Date.now()) node.append(element('p', 'result', recent.text));
    else node.append(element('p', 'note', 'Answer this on your Mac.'));
    return node;
  }
  if (prompt.question) node.append(element('p', 'question', prompt.question));
  if (prompt.summary) node.append(element('pre', 'command', prompt.summary));
  const sent = page.answered.get(prompt.id);
  if (sent) {
    node.append(element('p', sent.error ? 'result error' : 'result', sent.text));
    if (!sent.error) return node;
  }
  if (prompt.choices.length === 0) {
    node.append(element('p', 'note', 'This question has several parts. Answer it on your Mac.'));
    return node;
  }
  const choices = element('div', 'choices');
  for (const choice of prompt.choices) {
    const button = element('button', `button${choice.role ? ` ${choice.role}` : ''}`, choice.title);
    button.type = 'button';
    button.addEventListener('click', () => answer(session, prompt, choice, choices));
    choices.append(button);
    if (choice.detail) choices.append(element('p', 'choice-detail', choice.detail));
  }
  node.append(choices);
  return node;
}

function workingRow(session) {
  const row = element('li');
  const agent = session.title ? `${session.agent} in ${session.project}` : session.agent;
  row.append(head(session), element('p', 'where', `${agent}, ${lowerFirst(session.status)}`));
  return row;
}

function limitRow(limit) {
  const row = element('li', limit.stale ? 'limit stale' : 'limit');
  const top = element('div', 'limit-head');
  const name = element('span', null, limit.name);
  const value = element('span', null, limit.stale && limit.used === 0 ? 'Awaiting a reading' : `${Math.round(limit.used)}%`);
  top.append(name, value);
  const bar = element('div', 'bar');
  bar.setAttribute('role', 'img');
  bar.setAttribute('aria-label', `${limit.name}: ${Math.round(limit.used)} percent used`);
  const fill = element('div', 'bar-fill');
  fill.style.setProperty('--used', `${Math.min(100, Math.max(0, limit.used))}%`);
  if (limit.urgent) fill.classList.add('urgent');
  bar.append(fill);
  if (limit.pace !== null && limit.pace !== undefined && !limit.stale) {
    const tick = element('div', 'bar-pace');
    tick.style.setProperty('--pace', `${Math.min(100, Math.max(0, limit.pace))}%`);
    bar.append(tick);
  }
  row.append(top, bar);
  if (limit.resetsAt) row.append(element('p', 'limit-reset', resetLine(limit.resetsAt)));
  return row;
}

// MARK: Talking to the Mac

async function post(path, body) {
  if (window.WardenRemote) return window.WardenRemote.post(path, body);
  return fetch(path, {
    method: 'POST',
    credentials: 'same-origin',
    cache: 'no-store',
    headers: { 'Content-Type': 'application/json', 'X-Warden': '1' },
    body: JSON.stringify(body || {}),
  });
}

const sentText = {
  allow: 'Allowed',
  allowForSession: 'Allowed for this session',
  allowAlways: 'Always allowed',
  deny: 'Denied',
};

async function answer(session, prompt, choice, buttons) {
  for (const button of buttons.querySelectorAll('button')) button.disabled = true;
  let result;
  try {
    const response = await post('/api/answer', { approval: prompt.id, choice: choice.id });
    if (response.status === 401) return unpaired();
    if (response.ok) result = { text: sentText[choice.id] || `Answered: ${choice.title}` };
    else if (response.status === 409) result = { text: 'Already answered on the Mac.' };
    else result = { text: 'Warden could not send this answer. Try again.', error: true };
  } catch (error) {
    result = { text: 'The Mac did not answer. Try again.', error: true };
  }
  page.answered.set(prompt.id, result);
  if (!result.error) page.recent.set(session.id, { text: result.text, until: Date.now() + 30000 });
  if (page.data) render(page.data);
}

async function poll() {
  for (;;) {
    const controller = new AbortController();
    page.request = controller;
    const since = page.version === null ? '' : `?since=${page.version}`;
    try {
      const response = await fetch(`/api/state${since}`, { credentials: 'same-origin', cache: 'no-store', signal: controller.signal });
      if (response.status === 401) return unpaired();
      if (!response.ok) throw new Error(`HTTP ${response.status}`);
      const data = await response.json();
      // The Mac sends its first state a moment after it starts listening.
      if (!Array.isArray(data.needsYou)) throw new Error('No state yet');
      page.failures = 0;
      page.version = data.version;
      render(data);
    } catch (error) {
      if (controller.signal.aborted) continue;
      page.failures += 1;
      if (page.failures >= 2) offline();
      await pause(Math.min(10000, 1000 * page.failures));
    }
  }
}

function offline() {
  const mac = page.data ? page.data.mac : 'your Mac';
  plate('dim', `Can't reach ${mac}`, 'Trying again');
  $('offline-text').textContent = window.WardenRemote
    ? 'Warden needs to be running on your Mac and connected to the Internet.'
    : 'Warden needs to be running on the Mac, with this phone on the same Wi-Fi network.';
  show('offline');
}

function unpaired() {
  page.version = null;
  page.data = null;
  plate('idle', 'Pair with Warden', 'Answer your coding agents from this phone');
  $('pair-note').textContent = '';
  show('pairing');
}

async function pair(body) {
  $('pair-button').disabled = true;
  $('pair-note').textContent = 'Pairing…';
  try {
    const response = await post('/api/pair', body);
    if (response.ok) {
      $('pair-note').textContent = '';
      $('code').value = '';
      poll();
      return;
    }
    $('pair-note').textContent = 'That code did not work, or it expired. Choose Pair a Phone on your Mac for a new one.';
  } catch (error) {
    $('pair-note').textContent = 'The Mac did not answer. Check that this phone is on the same Wi-Fi.';
  } finally {
    $('pair-button').disabled = false;
  }
}

function setUp() {
  $('pair-form').addEventListener('submit', (event) => {
    event.preventDefault();
    const code = $('code').value.replace(/\D/g, '');
    if (code.length === 6) pair({ code });
    else $('pair-note').textContent = 'Type the six digits shown on your Mac.';
  });
  $('retry').addEventListener('click', () => {
    page.failures = 0;
    askNow();
  });
  let confirming = null;
  $('unpair').addEventListener('click', async () => {
    const button = $('unpair');
    if (!confirming) {
      button.textContent = 'Tap Again to Unpair';
      confirming = setTimeout(() => {
        button.textContent = 'Unpair This Phone';
        confirming = null;
      }, 4000);
      return;
    }
    clearTimeout(confirming);
    confirming = null;
    button.textContent = 'Unpair This Phone';
    try { await post('/api/unpair'); } catch (error) { offline(); return; }
    askNow();
    if (!window.WardenRemote) unpaired();
  });
  // Coming back to the page asks at once instead of waiting for a held request that the phone may have dropped.
  document.addEventListener('visibilitychange', () => {
    if (document.visibilityState === 'visible') askNow();
  });
  // Ages and reset times move on between changes.
  setInterval(() => { if (page.data && !$('content').hidden) render(page.data); }, 30000);

  if (window.WardenRemote) {
    window.WardenRemote.start({
      onState(data) { page.failures = 0; page.version = data.version; render(data); },
      onStatus(text) { page.data = null; page.version = null; plate('dim', 'Warden on your Mac', 'Encrypted connection'); $('offline-text').textContent = text; show('offline'); },
    });
    return;
  }

  // A link from the pairing QR code carries a single-use token after #p=. The browser never sends the fragment.
  const token = (location.hash.match(/[#&]p=([A-Za-z0-9_-]+)/) || [])[1];
  if (token) {
    history.replaceState(null, '', location.pathname);
    unpaired();
    pair({ token });
  } else {
    poll();
  }
}

document.addEventListener('DOMContentLoaded', setUp);
