# Build and contribute

## Build

Requires Xcode command-line tools with Swift 5.10 or later, and a universal Python installation to package train-guard. The runtime build uses PyInstaller 6.22.3 and psutil 7.2.2; Python 3.13.7 from python.org was used for this release.

Use the exact train-guard wheel published with this beta. It contains the Python source and MIT license; its SHA-256 is recorded in `SHA256SUMS.txt` and `manifest.json`.

```sh
mkdir -p build/dependencies
curl -fL https://github.com/fus3r/warden/releases/download/v0.4.0-beta.6/train_guard-0.5.0.dev0-py3-none-any.whl \
  -o build/dependencies/train_guard-0.5.0.dev0-py3-none-any.whl
export WARDEN_TRAIN_GUARD_WHEEL="$PWD/build/dependencies/train_guard-0.5.0.dev0-py3-none-any.whl"
./Scripts/build-app.sh
open build/Warden.app
```

Alternatively, set `WARDEN_TRAIN_GUARD_SOURCE` to a compatible train-guard checkout with Python's `build` module installed. To reuse a matching frozen runtime, set `WARDEN_TRAIN_GUARD_RUNTIME` to its directory. Local builds use an available Apple Development identity or ad-hoc signing; `WARDEN_SIGN_IDENTITY=-` selects ad-hoc signing explicitly.

## Test and contribute

```sh
swift test
node --test Extensions/warden-terminal/extension.test.js
npm ci --prefix Relay
npm test --prefix Relay
```

Use `./Scripts/build-app.sh debug` for a separate preview app. `WARDEN_FIXTURE=1 WARDEN_SHOW=tutorial build/WardenPreview.app/Contents/MacOS/Warden` opens the guide with sample sessions and isolated preview storage. The [release guide](releasing.md) covers packaging and checks on another Mac.

Bug reports and focused pull requests are welcome. Include steps to reproduce and the Warden/macOS versions. Remove private conversation content, paths and pairing links from reports and screenshots.
