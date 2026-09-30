<div align="center">
  <img src="docs/assets/warden_logo.png" width="96" height="96" alt="Warden lantern logo">
  <h1>Warden</h1>
  <p>Your Claude Code and Codex sessions, in the macOS menu bar.</p>
  <p>
    <a href="https://github.com/fus3r/warden/releases"><strong>Download for macOS</strong></a> ·
    <a href="https://warden.readthedocs.io/en/latest/">Documentation</a> ·
    <a href="CHANGELOG.md">Changelog</a>
  </p>
  <p>macOS 14+ · Apple silicon and Intel · <a href="LICENSE">MIT</a></p>
</div>

![Warden product illustration: a glowing lantern, coding terminals and a menu bar preview.](docs/assets/warden_banner.png)

<p align="center"><sub>Product illustration. <a href="docs/guide/sessions.md">See the native menu →</a></sub></p>

## Features

- **Know when you're needed.** Get alerts for approvals, questions, failures and completed turns. Answer supported prompts from the menu.
- **Return to your session.** Open the right terminal or resume where you left off.
- **Follow context and usage.** Check quotas, reset readings, local history and work planning. Sources and estimates are clearly labeled.
- **Supervise long jobs.** Built-in [train-guard](https://github.com/fus3r/train-guard) pauses supervised jobs on battery and lowers their priority when the battery is warm.

Optional extras: [Keep Awake](docs/guide/power.md), [local phone access](docs/guide/phone.md) and [widgets](docs/guide/sessions.md#widgets).

Monitoring and history stay on your Mac. Warden does not read provider credentials. [Sources and privacy →](docs/reference/privacy.md)

## Install

1. Download the **Warden DMG** from [Releases](https://github.com/fus3r/warden/releases).
2. Drag Warden into Applications and open it.
3. Follow the interactive guide from the lantern in your menu bar.

No Python or Xcode installation is needed. **This beta is not yet notarized**; macOS may require **Privacy & Security → Open Anyway**. See the [installation guide](docs/getting-started.md).

## Contributing

[Report a bug](https://github.com/fus3r/warden/issues/new?template=bug.yml) or see the [development guide](docs/development.md) to build, test and contribute.

[MIT license](LICENSE). Bundled sounds and dependencies retain their [own licenses and credits](NOTICE.md).
