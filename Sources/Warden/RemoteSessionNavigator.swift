import AppKit
import WardenCore

@MainActor
enum RemoteSessionNavigator {
    static func open(_ session: AgentSession) {
        guard let remote = session.remote else { return }
        if !remote.connected {
            show("Remote monitoring is disconnected from \(remote.label). Reconnect in Warden Settings, or return to your existing remote terminal.")
            return
        }
        let path = RemoteSSHAuthentication.controlPath(hostID: remote.hostID, destination: remote.destination)
        let controlPath = RemoteSSHAuthentication.socketIdentity(path) == nil ? nil : path.path
        if let command = RemoteNavigation.tmuxCommand(for: session, controlPath: controlPath)
            ?? RemoteNavigation.screenCommand(for: session, controlPath: controlPath) {
            SessionNavigator.runInTerminal(command)
            return
        }
        Task {
            let matches = await Task.detached { interactiveProcesses(destination: remote.destination) }.value
            if matches.count == 1, let pid = matches.first, let tty = ProcessDetails.tty(of: pid),
               let bundle = SessionNavigator.liveHost(of: pid), SessionNavigator.selectTab(tty: tty, bundleID: bundle) { return }
            show("Warden could not identify a single Terminal or iTerm SSH tab for \(remote.destination). Return to the agent's existing terminal. Use tmux or screen to return to a persistent session after disconnecting.")
        }
    }

    nonisolated private static func interactiveProcesses(destination: String) -> [Int32] {
        let task = Process(), pipe = Pipe()
        task.executableURL = URL(fileURLWithPath: "/bin/ps")
        task.arguments = ["-axo", "pid=,comm="]
        task.standardOutput = pipe; task.standardError = FileHandle.nullDevice
        guard (try? task.run()) != nil else { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        return String(decoding: data, as: UTF8.self).split(separator: "\n").compactMap { line in
            let parts = line.split(maxSplits: 1, whereSeparator: \.isWhitespace)
            guard parts.count == 2, let pid = Int32(parts[0]), URL(fileURLWithPath: String(parts[1])).lastPathComponent == "ssh",
                  ProcessDetails.tty(of: pid) != nil, let arguments = ProcessDetails.arguments(of: pid),
                  RemoteNavigation.interactiveDestination(arguments: arguments) == destination else { return nil }
            return pid
        }
    }

    private static func show(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Return to the remote agent"
        alert.informativeText = message
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}
