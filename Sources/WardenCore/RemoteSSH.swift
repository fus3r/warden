import Foundation

/// An existing OpenSSH destination, including aliases with ProxyJump in the owner's SSH configuration.
public struct RemoteSSHHost: Codable, Equatable, Identifiable {
    public var id: String
    public var destination: String
    public var name: String
    public var enabled: Bool

    public init(id: String = UUID().uuidString, destination: String, name: String? = nil, enabled: Bool = true) {
        self.id = id
        self.destination = destination
        self.name = name.flatMap { $0.isEmpty ? nil : $0 } ?? destination
        self.enabled = enabled
    }

    public static func validDestination(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 256, value.first != "-" else { return false }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_.-@:/[]")
        return value.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    public var monitoringArguments: [String] {
        ["-T", "-x", "-o", "ClearAllForwardings=yes", "-o", "RemoteCommand=none",
         "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes", "-o", "ConnectTimeout=8",
         "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=2", "-o", "ControlMaster=no",
         "-o", "ForwardAgent=no", destination, "python3 -u -"]
    }
}

public struct RemoteTmuxTarget: Codable, Equatable {
    public var session: String
    public var window: String
    public var pane: String

    public init(session: String, window: String, pane: String) {
        self.session = session; self.window = window; self.pane = pane
    }

    public var valid: Bool {
        zip([session, window, pane], ["$", "@", "%"]).allSatisfy { value, prefix in
            value.hasPrefix(prefix) && value.count > 1 && value.dropFirst().allSatisfy { "0123456789".contains($0) }
        }
    }
}

public struct RemoteScreenTarget: Codable, Equatable {
    public var session: String

    public init(session: String) { self.session = session }

    public var valid: Bool {
        let parts = session.split(separator: ".", maxSplits: 1)
        return session.utf8.count <= 200 && parts.count == 2 && parts[0].allSatisfy { "0123456789".contains($0) }
            && parts[1].allSatisfy { "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_.-".contains($0) }
    }
}

public struct RemoteSessionOrigin: Codable, Equatable {
    public var hostID: String
    public var destination: String
    public var label: String
    public var sessionID: String
    public var accountFolder: String
    public var tmux: RemoteTmuxTarget?
    public var screen: RemoteScreenTarget?
    public var connected: Bool = true

    public init(host: RemoteSSHHost, sessionID: String, accountFolder: String, tmux: RemoteTmuxTarget? = nil, screen: RemoteScreenTarget? = nil) {
        hostID = host.id; destination = host.destination; label = host.name
        self.sessionID = sessionID; self.accountFolder = accountFolder; self.tmux = tmux; self.screen = screen
    }
}

/// Only metadata and redacted log events cross SSH. The existing parsers determine agent states.
public struct RemoteSnapshot: Decodable {
    public struct File: Decodable {
        public var provider: AgentProvider
        public var filename: String
        public var account: String?
        public var accountFolder: String
        public var modifiedAt: Date
        public var head: String
        public var tail: String
        public var title: String?
        public var pid: Int32?
        public var tmux: RemoteTmuxTarget?
        public var screen: RemoteScreenTarget?
        public var inputPending: Bool?
        public var parentID: String?
    }
    public struct LiveProcess: Decodable {
        public var pid: Int
        public var provider: AgentProvider
        public var cwd: String?
    }
    public struct Usage: Decodable {
        public var provider: AgentProvider
        public var account: String?
        public var observedAt: Date
        public var result: String
    }
    public struct AgentViews: Decodable {
        public var account: String?
        public var observedAt: Date
        public var entries: String
    }
    public var version: Int
    public var observedAt: Date
    public var files: [File]
    public var processes: [LiveProcess]
    public var usage: [Usage]
    public var agentViews: [AgentViews]?

    public func sessions(host: RemoteSSHHost, receivedAt: Date = Date()) -> [AgentSession] {
        var filesBySession: [String: File] = [:]
        var sessionsByID: [String: AgentSession] = [:]
        for file in files {
            let head = Data(file.head.utf8), tail = Data(file.tail.utf8)
            let value = file.provider == .codex
                ? TelemetryParser.codex(head: head, tail: tail, filename: file.filename, modifiedAt: file.modifiedAt, account: file.account)
                : TelemetryParser.claude(head: head, tail: tail, filename: file.filename, modifiedAt: file.modifiedAt, account: file.account)
            guard var session = value else { continue }
            session.title = file.title ?? session.title
            if let parent = file.parentID {
                // Claude worker logs carry their parent's sessionId. Keep the parent's own row and state.
                session.isSubagent = true; session.parentID = parent
                session.id = "\(parent):\(file.filename)"
            }
            if file.inputPending == true {
                session.phase = .needsAttention; session.attention = .choice; session.detail = "Question awaiting your answer"
            }
            if session.provider == .claude {
                for views in agentViews ?? [] where views.account == file.account && observedAt.timeIntervalSince(views.observedAt) < 45 {
                    if let entry = ClaudeAgentView.entries(Data(views.entries.utf8)).first(where: { $0.sessionID == session.id }) {
                        session = ClaudeAgentView.merge(session, entry: entry, readAt: views.observedAt)
                    }
                }
            }
            if let pid = file.pid, processes.contains(where: { $0.pid == Int(pid) && $0.provider == file.provider }) {
                session.host = SessionHost(pid: pid)
            }
            let key = "\(file.provider.rawValue):\(session.id)"
            if let previous = sessionsByID[key], previous.updatedAt > session.updatedAt { continue }
            filesBySession[key] = file
            sessionsByID[key] = session
        }
        var parsed = Array(sessionsByID.values)
        let live = processes.map { AgentProcess(id: $0.pid, provider: $0.provider, surface: "SSH", cwd: $0.cwd, tty: nil) }
        let running = SessionLiveness.running(parsed, processes: live)
        let subagents = Dictionary(grouping: parsed.filter {
            $0.isSubagent && $0.phase == .working && (running.contains($0.id) || observedAt.timeIntervalSince($0.updatedAt) < 1800)
        }, by: { $0.parentID ?? "" })
        parsed.removeAll { $0.isSubagent }
        let clockOffset = receivedAt.timeIntervalSince(observedAt)
        return parsed.compactMap { value in
            var session = value
            guard let file = filesBySession["\(session.provider.rawValue):\(session.id)"] else { return nil }
            session.activeSubagents = subagents[session.id]?.count ?? 0
            let isRunning = running.contains(session.id) || session.activeSubagents > 0
            if session.activeSubagents > 0, session.phase != .needsAttention { session.phase = .working; session.phaseEvidence = .inferred }
            if session.phase == .working, !isRunning, observedAt.timeIntervalSince(session.updatedAt) > 120 {
                session.phase = .unknown
                session.phaseEvidence = .inferred
            }
            if session.attention == .interrupted, !isRunning {
                session.phase = .idle; session.attention = nil
            }
            if session.isHeadless, session.phase == .needsAttention, !isRunning {
                session.phase = .idle; session.attention = nil
            }
            session.remote = RemoteSessionOrigin(host: host, sessionID: session.id, accountFolder: file.accountFolder, tmux: file.tmux, screen: file.screen)
            session.id = "ssh:\(host.id):\(session.provider.rawValue):\(session.id)"
            session.host = nil
            session.surface = "SSH · \(host.name)"
            session.account = accountLabel(host: host, account: session.account)
            session.updatedAt = session.updatedAt.addingTimeInterval(clockOffset)
            session.turnStartedAt = session.turnStartedAt?.addingTimeInterval(clockOffset)
            session.lastRequestAt = session.lastRequestAt?.addingTimeInterval(clockOffset)
            session.resumesAt = session.resumesAt?.addingTimeInterval(clockOffset)
            session.windows = session.windows.map { scoped($0, host: host, offset: clockOffset) }
            return session
        }
    }

    public func windows(host: RemoteSSHHost, receivedAt: Date = Date()) -> [UsageWindow] {
        let offset = receivedAt.timeIntervalSince(observedAt)
        var windows = sessions(host: host, receivedAt: receivedAt).flatMap(\.windows)
        for item in usage {
            guard let result = (try? JSONSerialization.jsonObject(with: Data(item.result.utf8))) as? [String: Any] else { continue }
            let values = item.provider == .codex
                ? TelemetryParser.codexAccountWindows(result, observedAt: item.observedAt, account: item.account)
                : TelemetryParser.claudeAccountWindows(result, observedAt: item.observedAt, account: item.account)
            windows += values.map { scoped($0, host: host, offset: offset) }
        }
        return Dictionary(grouping: windows, by: \.id).values.compactMap { $0.max { $0.observedAt < $1.observedAt } }
    }

    private func accountLabel(host: RemoteSSHHost, account: String?) -> String {
        account.map { "\(host.name) / \($0)" } ?? host.name
    }

    private func scoped(_ value: UsageWindow, host: RemoteSSHHost, offset: TimeInterval) -> UsageWindow {
        var window = value
        window.id = "ssh:\(host.id):\(window.id)"
        window.account = ([host.name, window.provider.rawValue, window.account].compactMap { $0 }).joined(separator: " / ")
        window.observedAt = window.observedAt.addingTimeInterval(offset)
        window.resetsAt = window.resetsAt?.addingTimeInterval(offset)
        return window
    }
}

public enum RemoteNavigation {
    /// The final destination, not a ProxyJump or forwarding argument. Noninteractive SSH jobs have no agent tab.
    public static func interactiveDestination(arguments: [String]) -> String? {
        guard let executable = arguments.first, URL(fileURLWithPath: executable).lastPathComponent == "ssh" else { return nil }
        let takesValue = Set("BbcDEeFIiJLlmOopQRSWw")
        var index = 1
        while index < arguments.count {
            let argument = arguments[index]
            if argument == "--" { return arguments.dropFirst(index + 1).first }
            if !argument.hasPrefix("-") { return argument }
            if ["-N", "-f", "-T", "-O"].contains(argument) || argument.hasPrefix("-W") { return nil }
            if argument.count == 2, let option = argument.last, takesValue.contains(option) { index += 1 }
            index += 1
        }
        return nil
    }

    public static func tmuxCommand(for session: AgentSession, controlPath: String? = nil) -> String? {
        guard let remote = session.remote, remote.connected, RemoteSSHHost.validDestination(remote.destination),
              let target = remote.tmux, target.valid else { return nil }
        let quote = SessionNavigation.shellQuote
        let command = "tmux select-window -t \(quote(target.session + ":" + target.window)) && tmux select-pane -t \(quote(target.pane)) && tmux attach-session -t \(quote(target.session))"
        return attachCommand(destination: remote.destination, command: command, controlPath: controlPath)
    }

    public static func screenCommand(for session: AgentSession, controlPath: String? = nil) -> String? {
        guard let remote = session.remote, remote.connected, RemoteSSHHost.validDestination(remote.destination),
              let target = remote.screen, target.valid else { return nil }
        // Reattach only this existing session. A window list avoids guessing which screen window hosts the agent.
        return attachCommand(destination: remote.destination,
                             command: "screen -x -p '=' " + SessionNavigation.shellQuote(target.session), controlPath: controlPath)
    }

    private static func attachCommand(destination: String, command: String, controlPath: String?) -> String {
        (["/usr/bin/ssh", "-t", "-o", "RemoteCommand=none", "-o", "ClearAllForwardings=yes"]
            + (controlPath.map { ["-S", $0] } ?? []) + [destination, command]).map(SessionNavigation.shellQuote).joined(separator: " ")
    }

    public static func authenticationCommand(host: RemoteSSHHost, controlPath: String, configuration: String? = nil) -> String? {
        guard RemoteSSHHost.validDestination(host.destination) else { return nil }
        return (["/usr/bin/ssh"] + (configuration.map { ["-F", $0] } ?? [])
            + ["-t", "-S", controlPath, "-o", "ControlMaster=auto", "-o", "ControlPersist=5m",
                "-o", "BatchMode=no", "-o", "ForwardAgent=no", "-o", "ClearAllForwardings=yes", "-o", "RemoteCommand=none",
                host.destination]).map(SessionNavigation.shellQuote).joined(separator: " ")
    }

    public static func loginCommand(host: RemoteSSHHost) -> String? {
        guard RemoteSSHHost.validDestination(host.destination) else { return nil }
        return ["/usr/bin/ssh", host.destination].map(SessionNavigation.shellQuote).joined(separator: " ")
    }
}
