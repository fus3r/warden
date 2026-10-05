# Sources and privacy

Warden monitors coding activity on the Mac and optionally on Linux hosts you connect over SSH, and labels the evidence behind it. It does not inspect screen contents, browser tabs, API keys, or account cookies, and does not read provider credentials.

## Current coverage

| Surface | Session state and attention | Context | Limits |
| --- | --- | --- | --- |
| Claude Code CLI, IDE extension, Desktop Code | Local transcripts and optional hooks; supported permission prompts, questions, failures, and interruptions | Exact with bridge | Claude Code usage read, then bridge values |
| Codex CLI, VS Code extension, desktop app | Local logs; supported shared terminal-server approvals and Plan-mode questions; input events and completion/failure signals | Estimated | Local CLI account read per bucket, then log values |
| Linux agents over SSH | Redacted remote logs and current-user process metadata; Claude agent status when supported; remote questions answered in the terminal | Codex estimated; Claude unavailable without an exact reading | Remote CLI account read, then log values, separately labeled by host |
| ChatGPT and Claude native apps outside coding sessions | App presence only | Unavailable | Unavailable |

Answerable Codex prompts require a supported shared terminal server. See [Approvals and questions](../guide/prompts.md#codex) for exceptions. A final reply ending in a question mark is a heuristic, not a guaranteed question detector.

Limit percentages and reset times come from provider telemetry. Stale readings are labeled. A percentage drop is an observed change, not a scheduled reset inferred from forums.

## Bounded log reads

Session scans run every eight seconds. They consider at most 28 recent Claude logs and 56 Codex logs, reading the first 64 KB and a bounded tail: 512 KB for Claude, 1 MB for Codex, expanded to at most 8 MB for a recent unresolved Codex session. Unchanged logs use an in-memory cache. Claude subagent transcripts are read only to determine whether they still work.

A session counts as running while its agent process lives. A quiet transcript during a long reasoning step does not itself mark the session inactive.

The SSH collector uses the same head/tail sizes, widens unresolved tails to at most 8 MB, and caches unchanged files. It sends at most 84 logs in a 2 MB snapshot. Message text, tool arguments/results and unknown payload fields are removed on the remote host before transmission. Session titles and project paths are metadata and do cross SSH. See [Remote agents over SSH](../guide/remote-ssh.md) for observation limits.

Usage history initially reads logs changed in the last five weeks. Later reads consume only added lines, once a minute and when the menu opens. Saved checkpoints preserve model and cumulative counts so resumed logs are not counted again. Forked Claude replies are deduplicated by hash.

## Data locations

Warden data lives under `~/Library/Application Support/Warden` unless listed otherwise. Provider logs remain owned by the provider.

| Data | Location | Retention or contents |
| --- | --- | --- |
| Bridge status and latest session events | `status/`, `events/` | Status older than seven days and events older than two days are removed; no stored prompts or replies |
| Latest limit readings | `usage.json` | Last reported value of each window |
| Token history and read positions | `usage-active.json`, `usage-archive.json` | Daily provider, model, project, and token totals for 90 days; no conversation text |
| Copied-reply deduplication | `usage-replies.json` | Reply hashes and counting ownership for 40 days |
| Quota attribution | `quota-ledger.json` | Readings, use awaiting allocation, and daily project points for 90 days; unallocated use without a first reading waits at most eight days |
| Activity | `activity.json` | Work/wait spans, times, states, project paths, session IDs, and approval tool names for 30 days |
| Remote hosts | `remote-hosts.json` | Host IDs, destinations, names and enabled flags; optional generated relay pairing tokens and encryption key, restricted to your Mac account; no SSH or provider credentials; snapshots stay in memory |
| Temporary remote collector bootstrap | `remote-bootstrap/` | Private source and generated pairing material on this Mac, delivered over SSH stdin; no Warden file installed on Linux |
| Shared SSH authentication | `ssh/` | OpenSSH control sockets restricted to your Mac account; no saved passwords, MFA codes or phone approvals |
| Approval socket | `ipc/` | Local socket restricted to your user; command and question content stays in memory |
| Local phone access | `Phone/certificate.json`, `Phone/devices.json` | Server certificate and key, and paired device secret hashes; owner-only access |
| Relay phone devices | `Phone/remote-devices.json` | Private device credentials with owner-only access; prompt content stays in memory |
| Widgets | `Widget/snapshot.json` | Folder names, providers, states, tool names, and limits; no session titles, commands, or questions |
| Custom sounds and scripts | `Sounds/`, `Automations/` | Files you add; latest automation results stay in memory |

Plan prices stay in Warden's preferences. The start of an absence and a provider incident summary stay in memory. Exported CSV reports can contain full project paths.

train-guard stores its managed runtime under `~/.local/share/train-guard`, its command link under `~/.local/bin`, and state/logs under `~/.train-guard`. Warden reads active guard records and ignored-agent lists; a session exception writes its ID, agent, and folder name to that list. Earlier shell installations use `~/.claude/tools/train-guard`.

All-jobs exceptions write only an enabled flag and an optional expiry time to `~/.train-guard/global-override.json`; the usual policy and per-session exceptions remain intact. Reset reminders entered from Usage keep the provider, account label, and expiry date in Warden's local preferences. Provider reset availability comes from Codex's CLI; Warden does not read browser cookies or credentials.

## Optional network access

| Feature | What leaves the Mac |
| --- | --- |
| Account usage reads | The provider CLI's authenticated usage request, using its own sign-in; Warden sends no prompt |
| Remote SSH monitoring | Bundled collector code sent to a host you add; filtered states and counters return over SSH. Remote CLIs perform their own prompt-free account usage reads. No data goes to a Warden service |
| Optional memory-only HTTPS monitoring | After one SSH login, a temporary Linux process sends redacted telemetry encrypted for this Mac through the configured relay. Routing hashes and liveness configuration persist. Cloudflare replaces one stored opaque packet per host; packets older than 90 seconds are deleted at the next feed read. The Node relay keeps its latest packet in memory. No encryption key or conversation content reaches either relay |
| Provider status checks | A request to `status.claude.com` or `status.openai.com`, with no cookies or session details, at most every five minutes while a relevant failure is observed |
| Local paired phone | Session details and answers encrypted over HTTPS directly between Mac and phone |
| Self-hosted relay | End-to-end encrypted packets; the relay keeps routing-token hashes, last-connection times, and push subscriptions, without session history |
| Your automation scripts | Whatever the script sends, which can include alert titles, questions, project paths, or a phone page address |

Account reads, SSH hosts, status checks, phone access, and automations have settings controls. The downloadable beta includes local phone access; relay deployment is separate.

## Remove collected data

Quit Warden before deleting `~/Library/Application Support/Warden` to remove its collected data. Disconnect hooks and revoke phone pairing before uninstalling. The original Claude settings backups remain in the account folder for recovery.

Turning recording off pauses collection; it does not erase previous totals. See [Update or uninstall](../getting-started.md#update-or-uninstall) and [train-guard removal](../guide/train-guard.md#migrate-or-remove).
