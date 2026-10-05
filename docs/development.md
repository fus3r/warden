# Build and contribute

## Build

Requires Xcode command-line tools with Swift 5.10 or later, and a universal Python installation to package train-guard. The runtime build uses PyInstaller 6.22.3 and psutil 7.2.2; Python 3.13.7 from python.org was used for this release.

For the current source checkout, build the compatible train-guard version from [its public repository](https://github.com/fus3r/train-guard). Python's `build` module must be installed. The checkout must declare the version in `Sources/WardenCore/TrainGuardInstall.swift`, currently `0.5.1.dev0`.

```sh
git clone https://github.com/fus3r/train-guard.git ../train-guard-source
export WARDEN_TRAIN_GUARD_SOURCE="$PWD/../train-guard-source"
train-guard run --name warden-build -- ./Scripts/build-app.sh
open build/Warden.app
```

For the released **v0.4.0-beta.11** source tag, use its published wheel. It contains the Python source and MIT license; its SHA-256 is recorded in `SHA256SUMS.txt` and `manifest.json`.

```sh
mkdir -p build/dependencies
curl -fL https://github.com/fus3r/warden/releases/download/v0.4.0-beta.11/train_guard-0.5.1.dev0-py3-none-any.whl \
  -o build/dependencies/train_guard-0.5.1.dev0-py3-none-any.whl
export WARDEN_TRAIN_GUARD_WHEEL="$PWD/build/dependencies/train_guard-0.5.1.dev0-py3-none-any.whl"
./Scripts/build-app.sh
open build/Warden.app
```

Alternatively, set `WARDEN_TRAIN_GUARD_SOURCE` to a compatible train-guard checkout with Python's `build` module installed. To reuse a matching frozen runtime, set `WARDEN_TRAIN_GUARD_RUNTIME` to its directory. Local builds use an available Apple Development identity or ad-hoc signing; `WARDEN_SIGN_IDENTITY=-` selects ad-hoc signing explicitly.

## Test and contribute

```sh
swift test
python3 -m unittest discover -s Tests/RemoteCollectorTests -v
node --test Extensions/warden-terminal/extension.test.js
npm ci --prefix Relay
npm test --prefix Relay
```

Use `./Scripts/build-app.sh debug` for a separate preview app. `WARDEN_FIXTURE=1 WARDEN_SHOW=tutorial build/WardenPreview.app/Contents/MacOS/Warden` opens the guide with sample sessions and isolated preview storage. The [release guide](releasing.md) covers packaging and checks on another Mac.

The SSH integration test needs Docker. `train-guard run --name warden-ssh-qa -- python3 Scripts/verify-remote-ssh.py` builds an isolated Ubuntu OpenSSH server with disposable keys and fixture agents. It checks snapshots, privacy filtering, tmux/screen navigation, an independently closed terminal client, Swift reconnection, shared authentication with the fixture key revoked, expired access and manual sign-in recovery. It never changes owner SSH configuration. `--keep` retains the fixture for native preview checks; `--reuse --keep` reruns it, and `--cleanup` removes it. Native QA can pass its `ssh-config` with `WARDEN_SSH_CONFIG_FILE` only alongside an isolated `WARDEN_SUPPORT_DIR` in a debug build. No live provider subscription, phone approval service or external cluster is exercised by the fixture.

For memory-only HTTPS monitoring, install the Mac-side development dependencies with `npm ci --prefix Relay/Worker --ignore-scripts`, then leave `npm --prefix Relay/Worker run dev` running. Use `WARDEN_FEED_RELAY_URL=http://127.0.0.1:8788 npm test --prefix Relay` to test the Worker protocol, followed by `train-guard run --name warden-feed-qa -- python3 Scripts/verify-remote-ssh.py --feed`. The additional Linux test rejects new SSH logins, receives a completion over the local Cloudflare Worker, checks alert generation and stale-packet liveness, then removes its temporary collector while keeping the fixture agents alive. There is no installation of Warden code or packages on the monitored host.

Bug reports and focused pull requests are welcome. Include steps to reproduce and the Warden/macOS versions. Remove private conversation content, paths and pairing links from reports and screenshots.

## Documentation

The Read the Docs site builds from `docs/` and `mkdocs.yml` with the pinned dependencies in `docs/requirements.txt`.

```sh
python3 -m venv build/docs-venv
build/docs-venv/bin/python -m pip install -r docs/requirements.txt
build/docs-venv/bin/python -m mkdocs serve
```

Before submitting a documentation change, run `build/docs-venv/bin/python -m mkdocs build --strict`. Check the affected pages in light and dark themes and at a narrow viewport. The previous `/usage/` headings remain as links to the dedicated guides so existing bookmarks still work.

### Update screenshots

Screenshots live in `docs/assets/screenshots`. They use the debug app's sample data, not personal sessions. After building the preview, render a report with an existing debug entry point:

```sh
WARDEN_FIXTURE=1 WARDEN_APPEARANCE=light \
  WARDEN_SUPPORT_DIR="$PWD/build/docs-capture-state" \
  WARDEN_RENDER_HISTORY="$PWD/docs/assets/screenshots/history.png" \
  build/WardenPreview.app/Contents/MacOS/Warden -showAPIEquivalent NO
```

Other report entry points are `WARDEN_RENDER_LIMITS`, `WARDEN_RENDER_ACTIVITY`, and `WARDEN_RENDER_PLANNER`. `WARDEN_RENDER_TUTORIAL` selects a guide chapter with `-tutorialChapter menu`, `decisions`, or `jobs`. `WARDEN_RENDER_SETTINGS` selects a tab with `-settingsTab setup`, `general`, `ssh`, `sounds`, `usage`, `power`, `automations`, or `phone`.

The renderer briefly displays a native window and captures its backing store at the display's best resolution. On a Retina display, a 900-point guide produces a 1,800-pixel-wide PNG. Avoid the offscreen view cache: it can smooth text even in a nominally 2× bitmap. Keep the PNG at its captured dimensions. `WARDEN_RENDER_HEIGHT` can adjust the window height; long forms still scroll when the display limits the window's size.

For the native menu, launch with `WARDEN_FIXTURE=1` and `WARDEN_CAPTURE=/path/prefix`, then open the preview's lantern. The app captures its own menu window. Keep phone access and Keep Awake off during captures, inspect every image for clipping and private data, and label sample readings in its caption.
