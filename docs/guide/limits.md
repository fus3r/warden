# Context and quotas

Context belongs to a conversation. Usage limits belong to an account and may be shared across sessions or scoped to a model. Check both before adding a large task.

## Context readings

The ring beside a working session shows how much of its context window is used. Claude Code's bridge provides an exact reading; Codex's reading is estimated from the last input tokens and logged capacity. Unavailable information stays unavailable.

Choose context warnings in **Settings → General**. A high reading can be a reason to compact or start a new session in the agent's own interface; Warden does not do that for you.

## Account usage

The menu's **Usage** section shows each reported window, its used percentage, and time until reset. A tick marks where usage would sit at an even pace. Model-specific limits and Claude extra usage appear separately when reported.

- A model can reach its own limit while the shared plan still has room.
- A reading's source and age matter. When a read fails, Warden shows when the value was last reported.
- Values older than 30 minutes do not drive forecasts or the menu bar percentage.
- A reported reset passing is provisional until a new reading confirms availability. A sudden drop is an **observed change**, not a promised provider schedule.
- Banked Codex resets show the next expiry when the provider reports it; Warden does not spend them.

When recent pace would exhaust a window before its reset, Warden estimates when. The Usage tooltip adds recent pace from readings in the last hour. For comparisons at different paces, open [Work Planner](planner.md).

## Where the readings come from

Warden can keep limits current between sessions, every ten minutes and when you open the menu:

| Provider | Read |
| --- | --- |
| Claude Code | The `get_usage` control request behind `/usage`, with hooks, MCP servers, and plugins disabled; no prompt or model request |
| Codex | The read-only `account/rateLimits/read` request through the local CLI's app-server |

The provider's CLI uses its own sign-in and contacts its service. Warden does not read credentials. Failed reads retain the previous telemetry. Turn **Keep Claude limits current** or **Keep Codex limits current** off in **Settings → General** if needed. The [connection guide](connections.md) shows this settings tab.

Claude Code marks its usage request experimental. Warden reads the supported fields for shared windows, model-specific windows, and extra usage. See [Sources and privacy](../reference/privacy.md) for full coverage.

## Prompt cache

For a waiting Claude session with a large context, Warden can show a deadline such as **Reply within 22 min to keep its cache**. Recent Sessions can show **Cache 41 min** or **Cache expired**.

When available, expiry and token counts come from Claude Code's own status line report (2.1.251 or later), along with the reported cache hit ratio and possible reason for a miss. Otherwise Warden infers them from the last cache write in the log.

A later reply may rewrite context rather than read cached input. Warden estimates that cost in points of the 5-hour limit using the observed rate in [History → Limits](history.md#limits), or in tokens before that rate is known. Providers do not report the quota cost of an individual request. Five minutes before an hour-long cache expires, an enabled alert can remind you when the estimated cost is at least one point.

Cache deadlines and costs are evidence for a decision, not guaranteed subscription savings.

**Next:** [History and reports →](history.md)
