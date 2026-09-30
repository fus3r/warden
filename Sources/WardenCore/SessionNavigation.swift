import Foundation

/// The evidence needed to return to a session, without guessing among agents in the same folder.
public enum SessionNavigation {
    public static func process(for session: AgentSession, in processes: [AgentProcess],
                               openFiles: String = "", terminalNames: [Int: String] = [:]) -> AgentProcess? {
        guard !session.ended else { return nil }
        if let pid = session.host?.pid {
            return processes.first { $0.id == Int(pid) && $0.provider == session.provider }
        }
        // lsof's machine format gives the owning PID, then one line per open file. Matching the
        // transcript avoids confusing two sessions in a folder, or an old session with a new one.
        guard UUID(uuidString: session.id) != nil else { return nil }
        var pid: Int?
        var owners = Set<Int>()
        for line in openFiles.split(separator: "\n") {
            if line.first == "p" { pid = Int(line.dropFirst()) }
            if line.first == "n", let pid {
                let name = URL(fileURLWithPath: String(line.dropFirst())).lastPathComponent
                if name == "\(session.id).jsonl" || name.hasSuffix("-\(session.id).jsonl") { owners.insert(pid) }
            }
        }
        let matches = processes.filter { $0.provider == session.provider && owners.contains($0.id) }
        if !matches.isEmpty { return matches.count == 1 ? matches[0] : nil }

        // Codex's shared daemon owns the transcripts, not the TUI processes. The editor can instead
        // identify their terminals by the session title Codex puts in the tab, with an optional status
        // symbol in front. Require the same working directory and a unique full title; never pick a
        // terminal merely because it is the only agent in a folder.
        guard session.provider == .codex, !session.cwd.isEmpty,
              let title = session.title, !title.isEmpty else { return nil }
        let label = "\(title) | \(session.project)"
        let named = processes.filter { process in
            guard process.provider == .codex, process.cwd == session.cwd, process.tty != nil,
                  let name = terminalNames[process.id] else { return false }
            if name == label { return true }
            let parts = name.split(separator: " ", maxSplits: 1)
            return parts.count == 2 && parts[1] == label
                && parts[0].allSatisfy { !$0.isLetter && !$0.isNumber }
        }
        return named.count == 1 ? named[0] : nil
    }

    /// A specific conversation, never the CLI's most recent session or a new prompt.
    public static func command(for session: AgentSession, executable: URL, account: AgentAccount) -> String? {
        guard account.provider == session.provider, account.name == session.account else { return nil }
        let arguments: [String]
        if session.provider == .claude, let id = session.backgroundID {
            guard !id.isEmpty, id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }) else { return nil }
            arguments = ["attach", id]
        } else {
            guard UUID(uuidString: session.id) != nil else { return nil }
            arguments = session.provider == .claude ? ["--resume", session.id] : ["resume", session.id]
        }
        let variable = session.provider == .claude ? "CLAUDE_CONFIG_DIR" : "CODEX_HOME"
        let words = ["/usr/bin/env", "\(variable)=\(account.folder.path)", executable.path] + arguments
        let invocation = words.map(shellQuote).joined(separator: " ")
        return session.cwd.isEmpty ? invocation : "cd -- \(shellQuote(session.cwd)) && \(invocation)"
    }

    public static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// A shell command is data inside AppleScript, so it needs a separate layer of quoting.
    public static func appleScriptLiteral(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\n", with: "\\n") + "\""
    }
}
