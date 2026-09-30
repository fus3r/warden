# Warden

A native macOS menu bar app for Claude Code and Codex. Find sessions that need you, return to their terminals, and follow context and usage. Built-in [train-guard](https://github.com/fus3r/train-guard) integration supervises long local jobs.

**macOS 14+ · Apple silicon and Intel · MIT**

[Download](https://github.com/fus3r/warden/releases) · [Documentation](https://warden.readthedocs.io/en/latest/) · [Changelog](CHANGELOG.md)

## Install

1. Download the **Warden DMG** from [Releases](https://github.com/fus3r/warden/releases).
2. Drag Warden into Applications and open it.
3. Follow the interactive guide from the lantern in your menu bar.

No Python or Xcode installation is needed. This beta is not yet notarized; macOS may require **Privacy & Security → Open Anyway**. See the [installation guide](docs/getting-started.md).

## What it does

- Session alerts, supported approvals and terminal navigation.
- Context and quota readings, local history and work planning.
- Optional train-guard, Keep Awake, local phone access and widgets.

Monitoring stays on your Mac. Warden does not read provider credentials. See the [user guide](docs/usage.md) for supported integrations and data handling, or [build from source](docs/development.md).

[MIT license](LICENSE). Bundled sounds and dependencies retain their [own licenses and credits](NOTICE.md).
