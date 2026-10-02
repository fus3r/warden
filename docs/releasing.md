# Releasing Warden

Build from a clean, committed checkout. Keep signing keys, user settings and test data outside the repository. Run long builds under train-guard when it is available.

## Public beta

Set the tested wheel and, optionally, a matching frozen runtime:

```sh
export WARDEN_TRAIN_GUARD_WHEEL='/path/to/train_guard-0.5.1.dev0-py3-none-any.whl'
export WARDEN_TRAIN_GUARD_RUNTIME='/path/to/runtime'
train-guard run --name warden-beta -- ./Scripts/package-beta.sh
```

The runtime path must contain `source.json` and `TrainGuard.app`. Omit it to build the runtime from the wheel. Increment `CFBundleVersion` before preparing another candidate; existing output is not overwritten.

`package-beta.sh` runs the Swift and extension tests, builds the universal app, packages the VS Code companion and makes a DMG and ZIP. It verifies the signatures after extraction and records the source revision, executable hashes and train-guard wheel digest in `manifest.json`. Output goes to `build/downloads/<version>-<build>/`.

The beta is **not notarized**. Its guide describes Apple's per-app opening procedure. The script never uploads or publishes. Create a GitHub prerelease for the matching source commit and upload the files in the output directory. Confirm the release downloads work without a GitHub account. The English download page in `website/index.html` is ready for separate hosting; no site deployment is configured.

## Notarized distribution

Requires an Apple Developer Program membership, a Developer ID Application identity and a named `notarytool` Keychain profile.

```sh
export WARDEN_SIGN_IDENTITY='Developer ID Application: Your Name (TEAMID)'
export WARDEN_NOTARY_PROFILE='warden-notary'
export WARDEN_TRAIN_GUARD_WHEEL='/path/to/train_guard-0.5.1.dev0-py3-none-any.whl'
./Scripts/release.sh --check
train-guard run --name warden-release -- ./Scripts/release.sh
```

The check does not upload to Apple. The release command requires accepted notarization, stapled tickets and Gatekeeper acceptance before writing `build/releases/<version>/`. It publishes nothing to GitHub. See [Apple's notarization workflow](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow).

## Device checks

Use the downloaded archive with quarantine intact. Do not disable Gatekeeper or strip quarantine to make a check pass.

- Install without Xcode or Python. Confirm the first-run guide, session discovery, navigation and notifications on the target Mac.
- Quit and reopen; check that settings and provider hook configuration survive an update.
- If using train-guard, run a disposable job, unplug and reconnect power, verify pause/resume and the final result. Restore any test override.
- For local phone access, pair a physical phone, answer a disposable prompt, unpair and verify that access is revoked.
- For closed-lid work, verify administrator approval, continuation with the lid closed and restoration of normal sleep after work or app exit. An idle-sleep assertion alone does not establish this behavior.
- For a self-hosted relay, test mobile-data access, reconnection and locked-screen notifications on the physical phone.

Record hardware, macOS version and actual outcomes. Universal binaries and local tests do not establish every device behavior.
