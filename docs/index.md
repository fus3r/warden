# Warden

Warden puts your Claude Code and Codex sessions in the macOS menu bar. See which ones are working or waiting for you, return to a session's terminal, and check the context and quota information its provider makes available.

The app runs on **macOS 14 or later**, on Apple silicon and Intel. Monitoring and history stay on your Mac. Warden does not read provider credentials.

## Start here

[Download Warden from GitHub Releases](https://github.com/fus3r/warden/releases), drag the app into Applications and follow its interactive guide. The [getting started guide](getting-started.md) covers installation, connections and your first session.

The current version is **0.4.0 beta, build 6**. It includes an offline train-guard runtime and local phone access. It is not yet notarized by Apple.

## Find a guide

| Task | Guide |
| --- | --- |
| Install and connect your first session | [Getting started](getting-started.md) |
| Set up alerts, inspect usage or answer prompts | [Using Warden](usage.md) |
| Understand local data and provider access | [Data and privacy](usage.md#data-and-limits) |
| Build the app or contribute a fix | [Build and contribute](development.md) |
| Package a release and check it on another Mac | [Releasing Warden](releasing.md) |

## Long jobs and phone access

Install train-guard from Warden's settings to supervise long local jobs without installing Python. It can pause jobs on battery or adjust their scheduling according to your policy. It does not replace checkpoints or the Mac's hardware protections.

Phone access in this beta uses the same local network. A hosted relay is not included. The [relay source and deployment instructions](https://github.com/fus3r/warden/tree/main/Relay) are available for self-hosting.
