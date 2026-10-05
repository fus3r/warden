import AppKit
import WardenCore

/// Brings forward the app, window, or terminal tab that runs a session.
@MainActor
enum SessionNavigator {
    private static let editors: Set<String> = [
        "com.microsoft.VSCode", "com.microsoft.VSCodeInsiders", "com.vscodium",
        "com.todesktop.230313mzl4w4u92", "com.exafunction.windsurf", "dev.zed.Zed"
    ]
    private static let knownNames = [
        "com.microsoft.VSCode": "VS Code", "com.microsoft.VSCodeInsiders": "VS Code Insiders",
        "com.apple.Terminal": "Terminal", "com.googlecode.iterm2": "iTerm", "dev.warp.Warp-Stable": "Warp",
        "com.mitchellh.ghostty": "Ghostty", "com.todesktop.230313mzl4w4u92": "Cursor",
        "com.anthropic.claudefordesktop": "Claude", "com.openai.chat": "ChatGPT", "com.openai.codex": "ChatGPT"
    ]

    /// Host app of the session: recorded by the bridge, found through its process, or implied by the surface.
    static func hostBundleID(for session: AgentSession, processes: [AgentProcess]) -> String? {
        guard session.remote == nil else { return nil }
        if let bundleID = session.host?.bundleID { return bundleID }
        if let pid = session.host?.pid, let process = processes.first(where: { $0.id == Int(pid) }) {
            return process.hostBundleID
        }
        let hosts = Set(matchingProcesses(session, processes).compactMap(\.hostBundleID))
        if hosts.count == 1 { return hosts.first }
        let candidates: [String]
        switch session.surface {
        case "VS Code": candidates = ["com.microsoft.VSCode"]
        case "Claude Desktop": candidates = ["com.anthropic.claudefordesktop"]
        // The ChatGPT app that hosts Codex uses the Codex identifier; older builds use the chat one.
        case "ChatGPT": candidates = ["com.openai.codex", "com.openai.chat"]
        default: candidates = []
        }
        return candidates.first { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil }
    }

    static func hostName(_ bundleID: String?) -> String? {
        guard let bundleID else { return nil }
        if let name = knownNames[bundleID] { return name }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }

    static func open(_ session: AgentSession, processes: [AgentProcess], accounts: [AgentAccount]) {
        if session.remote != nil { RemoteSessionNavigator.open(session); return }
        Task {
            // Check the live owner at click time; a folder can outlive several unrelated conversations.
            let files = session.host?.pid == nil ? await Task.detached {
                openTranscripts(processes.filter { $0.provider == session.provider })
            }.value : ""
            var process = SessionNavigation.process(for: session, in: processes, openFiles: files)
            let editorProcesses = processes.filter {
                $0.provider == session.provider && $0.cwd == session.cwd && $0.tty != nil
                    && $0.hostBundleID.map(editors.contains) == true && ProcessDetails.isAlive(Int32($0.id), name: nil)
            }
            if process == nil, session.provider == .codex, !session.ended, session.host?.pid == nil {
                let names = await EditorTerminalBridge.terminalNames(for: editorProcesses)
                process = SessionNavigation.process(for: session, in: editorProcesses, terminalNames: names)
            }
            let pid = process.map { Int32($0.id) } ?? (session.ended ? nil : session.host?.pid)
            if let pid, ProcessDetails.isAlive(pid, name: session.host?.processName) {
                let bundleID = process?.hostBundleID ?? liveHost(of: pid) ?? session.host?.bundleID
                let tty = process?.tty ?? ProcessDetails.tty(of: pid) ?? session.host?.tty
                if session.backgroundID != nil, tty == nil {
                    resume(session, accounts: accounts)
                    return
                }
                if let bundleID {
                    if editors.contains(bundleID) {
                        if tty != nil, await EditorTerminalBridge.focus(pid: pid) { return }
                        showMissingTerminal(session)
                        return
                    }
                    if let tty, selectTab(tty: tty, bundleID: bundleID) { return }
                    if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
                        let configuration = NSWorkspace.OpenConfiguration()
                        configuration.activates = true
                        if (try? await NSWorkspace.shared.openApplication(at: app, configuration: configuration)) != nil { return }
                    }
                }
            }
            // Not finding a terminal is not proof that the session stopped. In particular, a shared
            // Codex daemon can still be waiting for the user in an existing editor terminal.
            if !session.ended, !editorProcesses.isEmpty || session.phase == .working || session.phase == .needsAttention {
                if let bundleID = hostBundleID(for: session, processes: processes),
                   !editors.contains(bundleID),
                   let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first {
                    app.activate()
                } else {
                    showMissingTerminal(session)
                }
                return
            }
            resume(session, accounts: accounts)
        }
    }

    /// Find a transcript owner only when clicked, never on each telemetry refresh. No file contents are read.
    nonisolated private static func openTranscripts(_ processes: [AgentProcess]) -> String {
        guard !processes.isEmpty else { return "" }
        let task = Process()
        let pipe = Pipe()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        task.arguments = ["-n", "-P", "-a", "-p", processes.map { String($0.id) }.joined(separator: ","), "-Fpn"]
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        guard (try? task.run()) != nil else { return "" }
        let timeout = DispatchWorkItem { if task.isRunning { task.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 1, execute: timeout)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        timeout.cancel()
        return String(data: data, encoding: .utf8) ?? ""
    }

    static func liveHost(of pid: Int32) -> String? {
        var current = pid
        for _ in 0..<16 where current > 1 {
            if let app = NSRunningApplication(processIdentifier: current), app.activationPolicy == .regular {
                return app.bundleIdentifier
            }
            guard let parent = ProcessDetails.parent(of: current), parent != current else { break }
            current = parent
        }
        return nil
    }

    /// A new Terminal tab opens the saved conversation, or attaches to its existing background process.
    private static func resume(_ session: AgentSession, accounts: [AgentAccount]) {
        let name = session.provider == .claude ? "claude" : "codex"
        guard let executable = AccountUsage.executable(name),
              let account = accounts.first(where: { $0.provider == session.provider && $0.name == session.account }),
              let command = SessionNavigation.command(for: session, executable: executable, account: account) else {
            showError("The \(session.provider.rawValue) command or this session's account could not be found.")
            return
        }
        runInTerminal(command)
    }

    static func runInTerminal(_ command: String) {
        let source = """
        tell application "Terminal"
            do script \(SessionNavigation.appleScriptLiteral(command))
            activate
        end tell
        """
        var error: NSDictionary?
        let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
        if result == nil || error != nil {
            // An explicit failure keeps the user in the session workflow and makes permission denial recoverable.
            let alert = NSAlert()
            alert.messageText = "Open in Terminal"
            alert.informativeText = "Warden could not open Terminal. You can paste this command into a terminal yourself."
            alert.addButton(withTitle: "Copy Command")
            alert.addButton(withTitle: "Cancel")
            NSApp.activate(ignoringOtherApps: true)
            if alert.runModal() == .alertFirstButtonReturn {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(command, forType: .string)
            }
        }
    }

    private static func showError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Could not open this conversation"
        alert.informativeText = message
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    private static func showMissingTerminal(_ session: AgentSession) {
        showError("Warden could not locate the terminal for “\(session.title ?? session.project)”. Open its existing terminal to continue. For VS Code, check that Warden Terminal Focus is enabled in that window.")
    }

    /// True when the session's own Terminal or iTerm tab is the one in front, so you already see what it does.
    /// Warden asks only a terminal it may already script, and never raises the Automation prompt for this.
    static func isInFront(_ session: AgentSession, processes: [AgentProcess]) -> Bool {
        guard session.remote == nil else { return false }
        // A locked screen shows nothing, whatever app was in front.
        let locked = (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool ?? false
        guard !locked, let bundleID = hostBundleID(for: session, processes: processes),
              NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundleID,
              let tty = terminalDevice(session, processes: processes), mayScript(bundleID) else { return false }
        let source: String
        switch bundleID {
        case "com.apple.Terminal": source = #"tell application "Terminal" to return tty of selected tab of front window"#
        case "com.googlecode.iterm2": source = #"tell application "iTerm2" to return tty of current session of current window"#
        default: return false
        }
        var error: NSDictionary?
        let front = NSAppleScript(source: source)?.executeAndReturnError(&error).stringValue
        return error == nil && front == "/dev/" + tty.replacingOccurrences(of: "/dev/", with: "")
    }

    /// Whether macOS already lets Warden send Apple events to an app, asked without prompting.
    private static func mayScript(_ bundleID: String) -> Bool {
        var target = AEAddressDesc()
        let created = bundleID.withCString { AECreateDesc(typeApplicationBundleID, $0, strlen($0), &target) }
        guard created == noErr else { return false }
        defer { AEDisposeDesc(&target) }
        return AEDeterminePermissionToAutomateTarget(&target, typeWildCard, typeWildCard, false) == noErr
    }

    private static func matchingProcesses(_ session: AgentSession, _ processes: [AgentProcess]) -> [AgentProcess] {
        guard !session.cwd.isEmpty else { return [] }
        return processes.filter { $0.provider == session.provider && $0.cwd == session.cwd }
    }

    private static func terminalDevice(_ session: AgentSession, processes: [AgentProcess]) -> String? {
        if let tty = session.host?.tty { return tty }
        let ttys = Set(matchingProcesses(session, processes).compactMap(\.tty))
        return ttys.count == 1 ? ttys.first : nil
    }

    /// Selects the Terminal or iTerm tab attached to the session's terminal device. macOS asks once for permission.
    static func selectTab(tty: String, bundleID: String) -> Bool {
        let device = "/dev/" + tty.replacingOccurrences(of: "/dev/", with: "")
        guard device.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "/" }) else { return false }
        let source: String
        switch bundleID {
        case "com.apple.Terminal":
            source = """
            tell application "Terminal"
                repeat with w in windows
                    repeat with t in tabs of w
                        if tty of t is "\(device)" then
                            set selected of t to true
                            set index of w to 1
                            activate
                            return true
                        end if
                    end repeat
                end repeat
            end tell
            return false
            """
        case "com.googlecode.iterm2":
            source = """
            tell application "iTerm2"
                repeat with w in windows
                    repeat with t in tabs of w
                        repeat with s in sessions of t
                            if tty of s is "\(device)" then
                                select w
                                select t
                                select s
                                activate
                                return true
                            end if
                        end repeat
                    end repeat
                end repeat
            end tell
            return false
            """
        default:
            return false
        }
        var error: NSDictionary?
        let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
        return error == nil && result?.booleanValue == true
    }
}
