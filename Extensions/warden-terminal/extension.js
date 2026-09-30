const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');
const { randomUUID } = require('node:crypto');

// Local process ancestry and terminal tab names only. No terminal contents or commands are read.
function listen(vscode, folder) {
    fs.mkdirSync(folder, { recursive: true, mode: 0o700 });
    fs.chmodSync(folder, 0o700);
    const windowID = randomUUID();
    const validAncestors = ancestors => Array.isArray(ancestors) && ancestors.length <= 16 &&
        ancestors.every(pid => Number.isSafeInteger(pid) && pid > 1);
    const seen = new Set();
    const watcher = fs.watch(folder, async (_event, name) => {
        if (!name || !/^[0-9a-f-]{36}\.json$/i.test(name) || seen.has(name)) return;
        seen.add(name);
        if (seen.size > 32) seen.delete(seen.values().next().value);
        const request = path.join(folder, name);
        try {
            const stat = await fs.promises.stat(request);
            if (stat.size > 16384 || Date.now() - stat.mtimeMs > 2000) return;
            const { ancestors, terminals: candidates } = JSON.parse(await fs.promises.readFile(request, 'utf8'));
            if (candidates !== undefined) {
                if (!Array.isArray(candidates) || candidates.length > 32 || !candidates.every(candidate =>
                    Number.isSafeInteger(candidate?.pid) && candidate.pid > 1 && validAncestors(candidate.ancestors))) return;
            } else if (!validAncestors(ancestors)) return;
            const terminals = await Promise.all(vscode.window.terminals.map(async terminal => ({
                terminal, pid: await terminal.processId
            })));
            if (candidates) {
                const names = candidates.flatMap(candidate => {
                    const match = terminals.find(({ pid }) => candidate.ancestors.includes(pid));
                    return match ? [{ pid: candidate.pid, name: match.terminal.name }] : [];
                });
                if (!names.length || !fs.existsSync(request)) return;
                const reply = request.replace(/\.json$/, `.${windowID}.terminals`);
                await fs.promises.writeFile(`${reply}.tmp`, JSON.stringify(names), { mode: 0o600 });
                // Publish complete metadata, just as Warden publishes a complete request.
                if (fs.existsSync(request)) await fs.promises.rename(`${reply}.tmp`, reply);
                else await fs.promises.unlink(`${reply}.tmp`);
                return;
            }
            const match = terminals.find(({ pid }) => ancestors.includes(pid));
            // Warden may have timed out or cancelled the click while a terminal was starting.
            if (!match || !fs.existsSync(request)) return;
            await vscode.commands.executeCommand('workbench.action.focusWindow');
            match.terminal.show(false);
            if (fs.existsSync(request)) await fs.promises.writeFile(request.replace(/\.json$/, '.done'), '', { mode: 0o600 });
        } catch {
            // An expired request disappearing, or a window closing, simply leaves Warden's fallback in charge.
        }
    });
    return { dispose: () => watcher.close() };
}

function activate(context) {
    const vscode = require('vscode');
    // Remote terminal PIDs belong to a different machine and must never match a local agent.
    if (process.platform !== 'darwin' || vscode.env.remoteName) return;
    context.subscriptions.push(listen(vscode, path.join(os.homedir(), 'Library/Application Support/Warden/editor-focus')));
}

module.exports = { activate, listen };
