# Changelog

## 0.4.0 beta (build 8)

- Return Codex questions to the correct VS Code terminal by excluding tool app servers from terminal matching. Report a missing editor terminal instead of activating an unrelated window.
- Add an option to sleep after all agent work, unanswered prompts and supervised jobs finish when using closed-lid mode.
- Add timed, custom-date and indefinite train-guard exceptions for all jobs, while preserving per-session controls.
- Remind users before Codex reset credits expire, with provider-backed expiry dates and manually entered Claude reset reminders.
- Bundle train-guard 0.5.1.dev0 with standalone enforcement of all-jobs exception expiry, including when Warden is closed.

## 0.4.0 beta (build 7)

- Alert for Codex questions while the agent keeps working, without repeating the alert when the turn ends with the same question open.
- Open Settings and report windows reliably from the menu.
- Correct session liveness and preserve saved usage when source logs are no longer available during migration.
- Keep usage reads and approvals on the selected account, and stop monitoring accounts that have been removed.
- Escape special characters in Claude Code hook paths.
- Revoke pending phone state requests when a device is unpaired, so it cannot receive later updates.
- Expand the documentation with illustrated guides for setup, sessions, notifications, history, power and phone access.

## 0.4.0 beta (build 6)

- Native menu bar monitoring for Claude Code and Codex, with session navigation, supported approvals, notifications and widgets.
- Context and quota readings, local usage history and work-planning estimates.
- A replayable interactive guide with live state, saved progress and safe approval practice.
- An offline universal train-guard runtime for Apple silicon and Intel Macs.
- Keep Awake for active sessions, supervised jobs and answerable prompts on a paired phone, with battery and thermal safeguards.
- Local phone pairing, including correct local-mode selection when no relay is configured and all Home Screen icons.
- Optional encrypted phone relay source and Docker deployment instructions for self-hosting.
- Universal DMG and ZIP downloads, an optional VS Code terminal companion, source and artifact identification, and bundled license notices.

Requires macOS 14 or later. This beta is not notarized. A hosted relay is not included; physical phone, Intel Mac and closed-lid checks remain part of external beta testing.
