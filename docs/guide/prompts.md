# Approvals and questions

Supported prompts appear under **Needs You** with the command, file, or question you need to review. Answer from Warden or the terminal: the provider takes the first answer and withdraws the prompt from the other view.

## Choose an answer

| Answer | Effect |
| --- | --- |
| **Allow** | Approve this command or edit |
| **Allow for This Session** | Apply the provider's suggested permission for this session, when offered |
| **Always Allow** | Keep the exact rule offered by the provider; inspect the tooltip for its scope and destination |
| **Deny** | Decline and stop the turn, as in the terminal |
| A question's option | Submit that choice for a supported single-choice question |

Warden never answers on its own. The [interactive guide](../getting-started.md#follow-the-interactive-guide) includes a practice approval that executes nothing.

## Claude Code

[Connect Claude Code](connections.md#claude-code) to enable its `PermissionRequest` hook. The terminal keeps showing the prompt while Warden shows it.

**Allow for This Session** uses the rule Claude Code suggests without saving it to a settings file. **Always Allow** lets Claude Code keep that exact rule where it says, usually the project's `.claude/settings.local.json`. Warden does not write the rule itself.

If you answer in the terminal, or the hook waits ten minutes without an answer, Warden releases the prompt and withdraws its notification. With Warden closed, the hook returns immediately and the terminal handles the decision.

The prompt travels over a local socket restricted to your user. Commands and paths stay in memory. Turn **Answer prompts from Warden** off in **Settings → General** if you want all decisions to stay in the terminal.

## Codex

Warden can answer command approvals, edit approvals, and Plan-mode questions from the **Codex terminal app's shared background server**, on Codex **0.157 or later**, while answering is enabled.

Codex must be configured to ask for approvals. For one disposable test session:

```sh
codex -a on-request -s workspace-write
```

With `approval_policy = "never"`, Codex does not ask. Warden keeps the permission choices Codex offers. **Always Allow commands starting with …** lets Codex save that prefix rule in `~/.codex/rules/default.rules`; the tooltip identifies it.

!!! note "Some prompts stay in their own window"
    Sessions started with `-c`, `--profile`, `--no-daemon`, or `--oss` use their own server, as do the VS Code extension and ChatGPT app. Warden can monitor their local logs, but their approval prompts stay in their host window. `codex exec` does not ask. Other request types, including MCP forms, remain in the terminal.

Warden connects through the account's local socket and joins a thread only while it waits. Session logs alone do not record this approval wait.

## Questions without answer buttons

Warden also detects questions in hooks, input-tool events, and sometimes a final reply ending in a question mark. That last signal is a heuristic: it may miss a question or flag a rhetorical one. Click the session to answer in its host when no button is offered.

**Related:** [Phone access](phone.md) · [Troubleshooting](../reference/troubleshooting.md#approval-buttons-are-missing)
