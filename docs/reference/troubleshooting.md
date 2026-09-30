# Troubleshooting

Start with **Settings → Setup**. It shows permissions, source coverage, login status, and the optional power service without requesting new permissions.

## The lantern or a session is missing

- Check that Warden is open and look in the macOS menu bar, not the Dock.
- Start a current Claude Code or Codex session. Native ChatGPT and Claude chats outside coding sessions expose app presence only.
- For Claude Code, check its connection. After moving Warden or updating Claude Code, use the offered repair.
- For another account folder, choose **Settings → General → Add Account Folder…**. See [Connect your sessions](../guide/connections.md).

## Clicking opens the wrong VS Code terminal

Install the [VS Code companion](../guide/connections.md#vs-code-companion). Without it, Warden activates the live host app. Reload VS Code only when interrupting the current sessions is acceptable.

Terminal and iTerm tab selection requires the macOS Automation permission requested on first use. If Warden cannot open Terminal, it offers to copy the resume command.

## Approval buttons are missing

For Claude Code, connect its hooks and enable **Answer prompts from Warden** in **Settings → General**.

For Codex, check the version, approval policy, and session type. The shared terminal server on 0.157 or later supports answering. Sessions with their own server, editor extensions, and the ChatGPT app keep prompts in their own window. `approval_policy = "never"` and `codex exec` do not ask.

Some questions are only detected from text and have no answer buttons. Click the session to answer in its host. See [Approvals and questions](../guide/prompts.md).

## Notifications do not appear

Use the Setup notification test, then check **System Settings → Notifications → Warden** and Focus. Check Warden's snooze, quiet hours, alert mode, and per-session mute or style. Voice and sounds can also be suppressed during microphone use.

A successfully submitted test does not prove that macOS displayed a banner. See [Notifications and sounds](../guide/notifications.md).

## Quotas or predictions are unavailable

Check the reading's source and age. Enable account usage reads in **Settings → General** if desired, and verify the CLI's own sign-in in its normal interface. Warden does not need your credentials.

The planner needs three readings over at least ten minutes with a measurable change. A reset or long gap starts learning again; it does not forecast beyond a reset. Missing prices affect API equivalents, not token totals. See [Context and quotas](../guide/limits.md) and [Work Planner](../guide/planner.md).

## train-guard stays paused

Run `train-guard status` to read the active policy and last decision. The default policy pauses on battery, so reconnect power to resume the same process. Warden's **Ignore train-guard** lets you exempt a chosen session yourself.

If the command is missing just after installation, open a new terminal and check that `~/.local/bin` is on its PATH. Active guards block runtime updates and removal. See [train-guard](../guide/train-guard.md).

## The Mac sleeps or the lid stops work

Check **Settings → Power** for the actual protection state, battery reserve, and power-source preference. Idle Keep Awake does not cover closing the lid. Closed-lid work needs the signed release app, the optional service, macOS approval, and verification on your Mac.

If service protection cannot be confirmed, Warden stops reporting it as active. See [Keep Awake](../guide/power.md).

## The phone cannot connect

For the downloadable beta, put both devices on the same local network and keep the Mac awake. Check the installed certificate profile and trust setting, then open a fresh pairing. Pair the Home Screen app separately from Safari; their cookies differ.

If the Mac's local name changed, make and install a new profile. Local-network pairing does not work over mobile data or a VPN; that requires a configured relay build. See [Phone access](../guide/phone.md).

## Report a reproducible problem

Open a [GitHub issue](https://github.com/fus3r/warden/issues) with the Warden/macOS versions, steps to reproduce, and what you expected and observed. Remove conversation content, private paths, credentials, pairing links, and complete logs from screenshots or attachments.
