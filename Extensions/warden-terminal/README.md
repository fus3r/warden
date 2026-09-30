# Warden Terminal Focus

Select a session in Warden to bring forward its existing VS Code terminal, including terminals in editor tabs and terminals whose working folder differs from their VS Code window.

This macOS companion uses VS Code's `Terminal.processId`, `Terminal.name`, `Terminal.show`, and `workbench.action.focusWindow`. It exchanges process IDs and terminal tab names with Warden through a private local folder. It does not read terminal output, send keystrokes, execute shell commands, or use the network. Remote terminals are not supported.

Codex terminals backed by the shared app-server daemon are matched by their full session title and working folder. Warden checks all candidate terminals before choosing one. If the match is missing or ambiguous, it brings the host app forward without launching another agent.

Build and install from the Warden checkout:

```sh
./Scripts/install-editor-extension.sh
```

If VS Code requests a window reload, wait until your agents can safely be interrupted before reloading. Without the companion, Warden can still activate the host app and resume saved sessions in Terminal.
