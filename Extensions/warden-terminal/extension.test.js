const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs/promises');
const path = require('node:path');
const os = require('node:os');
const { randomUUID } = require('node:crypto');
const { listen } = require('./extension');

test('a click selects the owning terminal and window, without typing into either terminal', async () => {
    const folder = await fs.mkdtemp(path.join(os.tmpdir(), 'warden-focus-'));
    const shown = [];
    const focused = [];
    const window = (name, pids) => ({
        window: { terminals: pids.map(pid => ({ processId: Promise.resolve(pid), show: preserve => shown.push([name, pid, preserve]) })) },
        commands: { executeCommand: async command => focused.push([name, command]) }
    });
    const a = listen(window('other project', [101]), folder);
    const b = listen(window('actual host', [202, 303]), folder);
    try {
        const id = randomUUID();
        const request = path.join(folder, `${id}.json`);
        await fs.writeFile(`${request}.tmp`, JSON.stringify({ ancestors: [999, 303, 404] }));
        await fs.rename(`${request}.tmp`, request);
        for (let n = 0; n < 50; n++) {
            if (await fs.stat(path.join(folder, `${id}.done`)).catch(() => false)) break;
            await new Promise(resolve => setTimeout(resolve, 20));
        }
        assert.deepEqual(shown, [['actual host', 303, false]]);
        assert.deepEqual(focused, [['actual host', 'workbench.action.focusWindow']]);
        assert.ok(await fs.stat(path.join(folder, `${id}.done`)));
    } finally {
        a.dispose(); b.dispose();
        await fs.rm(folder, { recursive: true });
    }
});

test('an unknown process leaves existing terminals alone and does not acknowledge success', async () => {
    const folder = await fs.mkdtemp(path.join(os.tmpdir(), 'warden-focus-'));
    let touched = false;
    const watcher = listen({ window: { terminals: [{ processId: Promise.resolve(101), show() { touched = true; } }] },
        commands: { executeCommand() { touched = true; } } }, folder);
    try {
        const id = randomUUID();
        const request = path.join(folder, `${id}.json`);
        await fs.writeFile(`${request}.tmp`, JSON.stringify({ ancestors: [999] }));
        await fs.rename(`${request}.tmp`, request);
        await new Promise(resolve => setTimeout(resolve, 100));
        assert.equal(touched, false);
        assert.equal(await fs.stat(path.join(folder, `${id}.done`)).catch(() => false), false);
    } finally {
        watcher.dispose();
        await fs.rm(folder, { recursive: true });
    }
});

test('a lookup reports each candidate tab across windows without focusing or typing', async () => {
    const folder = await fs.mkdtemp(path.join(os.tmpdir(), 'warden-focus-'));
    const window = (pid, name) => ({
        window: { terminals: [{ processId: Promise.resolve(pid), name,
            show() { assert.fail('a lookup must not focus a terminal'); } }] },
        commands: { executeCommand() { assert.fail('a lookup must not focus a window'); } }
    });
    // Duplicate titles in separate windows must both reach Warden so it can reject the ambiguity.
    const a = listen(window(101, '✳ Fix navigation | warden'), folder);
    const b = listen(window(202, '✳ Fix navigation | warden'), folder);
    try {
        const id = randomUUID();
        const request = path.join(folder, `${id}.json`);
        await fs.writeFile(`${request}.tmp`, JSON.stringify({ terminals: [
            { pid: 303, ancestors: [303, 101, 404] },
            { pid: 505, ancestors: [505, 202, 404] },
            { pid: 606, ancestors: [606, 404] }
        ] }));
        await fs.rename(`${request}.tmp`, request);
        let replies = [];
        for (let n = 0; n < 50; n++) {
            replies = (await fs.readdir(folder)).filter(name => name.endsWith('.terminals'));
            if (replies.length === 2) break;
            await new Promise(resolve => setTimeout(resolve, 20));
        }
        const names = (await Promise.all(replies.map(async name => JSON.parse(await fs.readFile(path.join(folder, name), 'utf8'))))).flat();
        assert.deepEqual(names.sort((a, b) => a.pid - b.pid), [
            { pid: 303, name: '✳ Fix navigation | warden' },
            { pid: 505, name: '✳ Fix navigation | warden' }
        ]);
        assert.equal(await fs.stat(path.join(folder, `${id}.done`)).catch(() => false), false);
    } finally {
        a.dispose(); b.dispose();
        await fs.rm(folder, { recursive: true });
    }
});
