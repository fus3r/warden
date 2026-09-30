# Sessions and the menu

Click the lantern in the menu bar. Sessions waiting for you appear above running work, with usage readings and the controls you have chosen to show below.

<figure class="warden-menu-shot" markdown="span">
[![Warden's native menu with Needs You, Working, Usage, and History.](../assets/screenshots/menu.png)](../assets/screenshots/menu.png)
<figcaption>Sample sessions and quota readings. Click a session to return to its terminal; answerable prompts also have buttons.</figcaption>
</figure>

## Read the lantern

The number counts sessions working or waiting for you. The lantern lights while agents work, shows an exclamation mark when a session needs you, and dims while alerts are snoozed.

**Settings → General** can add a usage percentage beside it: the fullest current limit or a limit you choose, shown as used or remaining.

## Find a session

| Section | What it tells you | What to do |
| --- | --- | --- |
| **Needs You** | Approvals, questions, failures, and interrupted turns; approvals first, then oldest waits | Answer a supported prompt or click to return to the agent |
| **Working** | Running sessions, context rings, turn duration, and active background agents | Click to inspect the live terminal |
| **Recent Sessions** | Finished, paused, or ended sessions | Return to the session or resume it |
| **Usage** | Account and model limits, reset readings, and pace estimates | [Read the quota evidence](limits.md) |
| **Work Planner** | Observed constraints for a work period | [Review before more work](planner.md) |
| **History** | Usage, quota allocation, and activity reports | [Inspect local history](history.md) |

Session names come from Claude Code's title or session name and Codex's thread names. Without a title, a Claude session can use the start of its last prompt, kept in memory only; otherwise Warden shows the folder.

A session whose own turn ended stays under Working while its background agents work. A programmatic run such as `claude -p` or `codex exec` remains under Needs You only while its process runs; stopped runs move to Recent Sessions with their reason.

## Return to the right terminal

Warden identifies the session's process from its bridge or open transcript. Terminal and iTerm select its tab. The [VS Code companion](connections.md#vs-code-companion) selects its integrated terminal and window. macOS asks once before Warden may control Terminal or iTerm.

Without a live host, Warden opens Terminal in the account and project folder with `claude --resume <session-id>` or `codex resume <session-id>`. Claude background sessions use `claude attach`. A click sends no new prompt. If Terminal cannot open, Warden offers to copy the resume command.

## Understand a wait

- **No new output** means the log has not changed for ten minutes. The agent may be running a long tool, reasoning, or waiting on a stalled request. Inspect its terminal; Esc stops the turn.
- A retry message, such as **Offline, retrying**, comes from the session's log.
- A Claude usage-limit wait shows the reported resume time. If the reset happens during a long sleep, Claude Code may wait for Enter instead.
- An interrupted turn stays under Needs You while the agent is open. Warden delays its alert by 30 seconds so you can redirect the agent after Esc.

See [Approvals and questions](prompts.md) for answer buttons and [Context and quotas](limits.md#prompt-cache) for cache deadlines.

## While You Were Away

After at least 15 minutes without keyboard or mouse input, or with the screen locked, Warden can show a summary when you return. It lists sessions that finished or need you, work and waiting time, and observed quota changes.

The summary stays at the top of the menu for half an hour and also sends a silent notification. Its submenu opens the session that waited longest. The absence start stays in memory only. Configure the summary in **Settings → General**.

## Widgets

Right-click the desktop, choose **Edit Widgets**, and search for **Warden**. Three sizes show waiting and working counts and the fullest limits, on the desktop or in Notification Center.

Click a session to bring it forward; click elsewhere to open the menu. Widgets show folder names, agent states, tool names, and limits, with no titles, commands, or questions. They refresh on changes and every quarter hour, and dim after half an hour without an update.

**Next:** [Approvals and questions →](prompts.md)
