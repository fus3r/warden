# Getting started

## Install on your Mac

Requires macOS 14 or later, on Apple silicon or Intel.

1. Download the **Warden DMG** from [GitHub Releases](https://github.com/fus3r/warden/releases).
2. Open the DMG and drag **Warden** into **Applications**.
3. Open Warden. Look for the lantern in your menu bar.

The ZIP is an alternative to the DMG. Both contain the app and its train-guard runtime. No Python, Xcode or personal server is needed.

### First launch of this beta

This beta is not notarized by Apple. If macOS says it cannot verify the developer or check the app for malicious software, dismiss that message. For the copy downloaded from the official release, go to **System Settings → Privacy & Security → Open Anyway**, then confirm Warden. Follow [Apple's instructions](https://support.apple.com/102445).

Do not disable Gatekeeper or remove quarantine in Terminal. If macOS says the app is damaged or will damage your computer, stop installing and report the message.

## Connect a session

The interactive guide opens on a fresh installation. You can reopen it at any time with **Interactive Guide…** in the menu. Progress is saved; the approval exercise does not execute a command.

1. Start Claude Code or Codex in your usual terminal.
2. For Claude Code, choose **Connect…** in the guide. Warden shows the changes and backs up the existing settings before applying them. Codex monitoring needs no configuration.
3. Check that the session appears in Warden and clicking it brings you back to its terminal.
4. Choose notifications in **Settings → Setup** and try the notification test. macOS Focus and alert settings still determine whether a banner appears.

For precise selection of VS Code's integrated terminals, download `warden-terminal.vsix` from the release and use **Extensions → … → Install from VSIX…**. If VS Code requests a reload, wait until your sessions can be interrupted.

## Try train-guard

In **Settings → General**, install the bundled runtime. Open a new terminal and try a disposable job:

```sh
train-guard run --name warden-test -- /bin/sleep 30
train-guard status
```

On battery, the job may remain paused until you reconnect power. To end this test if needed:

```sh
train-guard stop warden-test --kill
```

Keep the usual backups and checkpoints for real computations. Warden preserves an existing train-guard policy and refuses to replace its runtime while guards are running.

## Phone access and sleep

The phone and Mac must be on the same local network, and the Mac must stay awake. **Settings → Phone** guides you through the HTTPS profile and QR pairing.

Configure **Keep Awake** in **Settings → Power**. Keep the lid open for a first test. Closed-lid work requires the optional macOS power service and verification on the target Mac. See the [device checks](releasing.md#device-checks).

## Update or uninstall

Quit Warden, replace the app in Applications, then reopen it. Settings and history are retained.

Before uninstalling, disconnect Claude Code and turn off **Open at Login**. If enabled, disable the closed-lid service in **Power**. To remove Warden's train-guard installation, wait for supervised jobs to finish and use **Remove…** in Settings; it can also remain installed separately. Remove Warden.app and the optional VS Code companion when ready.

For data locations and supported sources, see [Using Warden](usage.md).
