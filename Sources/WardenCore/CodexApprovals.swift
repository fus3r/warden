import Foundation

/// Codex prompts that Warden can answer through Codex's shared app-server daemon, where the `codex` terminal app runs
/// its threads since 0.157. The daemon sends a thread's prompts to every client of the thread and takes the first
/// answer; the others see the request resolved, so the terminal keeps its own prompt. Warden answers command
/// approvals, file changes, and questions, and never replies to any other request, since a reply would count as the
/// answer of the client it was meant for.
public enum CodexApprovals {
    public static let command = "item/commandExecution/requestApproval"
    public static let fileChange = "item/fileChange/requestApproval"
    public static let userInput = "item/tool/requestUserInput"

    /// What a waiting thread asks of you, for its session.
    public struct Wait: Equatable {
        public var kind: AttentionKind
        public var detail: String?

        public init(kind: AttentionKind, detail: String? = nil) {
            self.kind = kind
            self.detail = detail
        }
    }

    /// The daemon's socket for an account folder, such as `~/.codex`.
    public static func socket(in folder: URL) -> URL {
        folder.appendingPathComponent("app-server-control/app-server-control.sock")
    }

    /// Streamed text and output, usage updates, and realtime audio, which Warden has no use for. Codex leaves them out
    /// of the connection, so less crosses it while Warden follows a waiting thread.
    public static let ignoredNotifications = [
        "item/agentMessage/delta", "item/plan/delta", "item/reasoning/summaryTextDelta",
        "item/reasoning/summaryPartAdded", "item/reasoning/textDelta", "item/commandExecution/outputDelta",
        "item/commandExecution/terminalInteraction", "item/fileChange/outputDelta", "item/fileChange/patchUpdated",
        "item/mcpToolCall/progress", "command/exec/outputDelta", "process/outputDelta", "turn/diff/updated",
        "turn/plan/updated", "thread/tokenUsage/updated", "account/rateLimits/updated", "rawResponseItem/completed",
        "rawResponse/completed", "mcpServer/event/stream/notification", "model/safetyBuffering/updated",
        "thread/realtime/outputAudio/delta", "thread/realtime/transcript/delta", "thread/realtime/item/transcript/delta"
    ]

    /// `experimentalApi` brings each command prompt's own list of answers, as the terminal shows them.
    public static func initializeParams(version: String) -> [String: Any] {
        ["clientInfo": ["name": "warden", "title": "Warden", "version": version],
         "capabilities": ["experimentalApi": true, "requestAttestation": false,
                          "optOutNotificationMethods": ignoredNotifications]]
    }

    /// Whether the daemon is 0.157 or later, from the user agent in its `initialize` answer, such as
    /// "codex-tui/0.157.1 (Mac OS 15.7.7; arm64) vscode/1.138.0 (warden; 1.0)".
    public static func isSupported(userAgent: String) -> Bool {
        guard let product = userAgent.split(separator: " ").first, let version = product.split(separator: "/").last,
              product.contains("/") else { return false }
        let numbers = version.split(separator: ".").prefix(2).map { Int($0.prefix(while: \.isNumber)) }
        guard numbers.count == 2, let major = numbers[0], let minor = numbers[1] else { return false }
        return major > 0 || minor >= 157
    }

    /// What a thread waits for, from the `status` of a thread or of a `thread/status/changed` notification.
    public static func waits(inStatus status: [String: Any]?) -> AttentionKind? {
        guard status?["type"] as? String == "active", let flags = status?["activeFlags"] as? [String] else { return nil }
        if flags.contains("waitingOnApproval") { return .permission }
        if flags.contains("waitingOnUserInput") { return .choice }
        return nil
    }

    /// The files a file change would touch, by item id, from a thread item. A file change request names only its
    /// item, whose edits the item itself carries.
    public static func fileChange(_ item: [String: Any]) -> (id: String, paths: [String])? {
        guard item["type"] as? String == "fileChange", let id = item["id"] as? String else { return nil }
        return (id, (item["changes"] as? [[String: Any]] ?? []).compactMap { $0["path"] as? String })
    }

    /// The file changes of a turns page, such as the current turn `thread/resume` returns when asked for it.
    public static func fileChanges(inPage page: [String: Any]?) -> [String: [String]] {
        var changes: [String: [String]] = [:]
        for turn in page?["data"] as? [[String: Any]] ?? [] {
            for item in turn["items"] as? [[String: Any]] ?? [] {
                if let change = fileChange(item) { changes[change.id] = change.paths }
            }
        }
        return changes
    }

    /// The prompt Warden shows for a daemon request, or nil for a request left to the terminal. `paths` are the
    /// files of a file change; `rules` is where Codex keeps an allow rule, such as `~/.codex/rules/default.rules`.
    public static func request(method: String, params: [String: Any], id: String, sessionID: String, cwd: String?,
                               paths: [String] = [], rules: String? = nil) -> ApprovalRequest? {
        let folder = (params["cwd"] as? String) ?? cwd
        switch method {
        case command:
            let decisions = params["availableDecisions"] as? [Any] ?? []
            let prefix = decisions.lazy.compactMap { decision in
                ((decision as? [String: Any])?["acceptWithExecpolicyAmendment"] as? [String: Any])?["execpolicy_amendment"] as? [String]
            }.first
            let host = (params["networkApprovalContext"] as? [String: Any])?["host"] as? String
            return ApprovalRequest(id: id, sessionID: sessionID, tool: "Command",
                                   summary: host.map { "Network access to \($0)" } ?? Approval.oneLine(commandLine(params["command"] as? String)),
                                   canAllowForSession: decisions.contains { $0 as? String == "acceptForSession" },
                                   questions: [],
                                   alwaysRule: prefix.map { "commands starting with \($0.joined(separator: " "))" },
                                   alwaysIn: prefix == nil ? nil : rules, cwd: folder, provider: .codex)
        case fileChange:
            let shown = paths.compactMap { Approval.shortPath($0, in: folder) }
            let summary = (params["grantRoot"] as? String).flatMap { Approval.shortPath($0, in: folder) }.map { "Write access to \($0)" }
                ?? shown.first.map { shown.count == 1 ? $0 : "\($0) and \(shown.count - 1) more" }
            return ApprovalRequest(id: id, sessionID: sessionID, tool: "Edit", summary: summary, canAllowForSession: true,
                                   questions: [], alwaysRule: nil, alwaysIn: nil, cwd: folder, provider: .codex)
        case userInput:
            let questions = (params["questions"] as? [[String: Any]] ?? []).compactMap { question -> ApprovalRequest.Question? in
                guard let text = question["question"] as? String, let key = question["id"] as? String else { return nil }
                // A secret answer is typed in the terminal.
                let options = question["isSecret"] as? Bool == true ? []
                    : (question["options"] as? [[String: Any]] ?? []).compactMap { $0["label"] as? String }
                return ApprovalRequest.Question(text: text, options: options, multiSelect: false, id: key)
            }
            guard !questions.isEmpty else { return nil }
            return ApprovalRequest(id: id, sessionID: sessionID, tool: "Question", summary: Approval.oneLine(questions[0].text),
                                   canAllowForSession: false, questions: questions, alwaysRule: nil, alwaysIn: nil,
                                   cwd: folder, provider: .codex)
        default:
            return nil
        }
    }

    /// The result Codex takes for Warden's answer, or nil when the prompt does not offer that answer. Deny answers
    /// as the terminal's "No, and tell Codex what to do differently" does, or declines when a command prompt does not
    /// offer that.
    public static func result(for answer: ApprovalAnswer, method: String, params: [String: Any]) -> [String: Any]? {
        switch method {
        case command:
            // Without its own list, the prompt offers what every command prompt does.
            let offered = params["availableDecisions"] as? [Any] ?? ["accept", "cancel"]
            func offers(_ name: String) -> Bool { offered.contains { $0 as? String == name } }
            switch answer.behavior {
            case "allow" where answer.forSession:
                return offers("acceptForSession") ? ["decision": "acceptForSession"] : nil
            case "allow" where answer.always == true:
                // The rule Codex proposed, exactly: commands that start with these words run without asking.
                return offered.first { ($0 as? [String: Any])?["acceptWithExecpolicyAmendment"] != nil }.map { ["decision": $0] }
            case "allow":
                return offers("accept") ? ["decision": "accept"] : nil
            case "deny":
                return offers("cancel") ? ["decision": "cancel"] : offers("decline") ? ["decision": "decline"] : nil
            default:
                return nil
            }
        case fileChange:
            switch answer.behavior {
            case "allow" where answer.always == true: return nil
            case "allow": return ["decision": answer.forSession ? "acceptForSession" : "accept"]
            case "deny": return ["decision": "cancel"]
            default: return nil
            }
        case userInput:
            // Answers come by question text from the menu, or by question id.
            guard answer.behavior == "allow", let chosen = answer.answers else { return nil }
            var answers: [String: Any] = [:]
            for question in params["questions"] as? [[String: Any]] ?? [] {
                guard let key = question["id"] as? String,
                      let pick = chosen[key] ?? (question["question"] as? String).flatMap({ chosen[$0] }) else { continue }
                answers[key] = ["answers": [pick]]
            }
            return answers.isEmpty ? nil : ["answers": answers]
        default:
            return nil
        }
    }

    /// Codex's logs never record a wait for approval or an answer; the daemon's thread status does. A session whose
    /// thread waits moves to Needs You, keyed by session id.
    public static func applying(_ waits: [String: Wait], to sessions: [AgentSession]) -> [AgentSession] {
        guard !waits.isEmpty else { return sessions }
        return sessions.map { session in
            guard session.provider == .codex, let wait = waits[session.id] else { return session }
            var waiting = session
            waiting.phase = .needsAttention
            waiting.phaseEvidence = .provider
            waiting.attention = wait.kind
            waiting.detail = wait.detail
            return waiting
        }
    }

    /// The command as the terminal shows it: Codex runs it through the login shell, as in `/bin/zsh -lc 'npm test'`.
    static func commandLine(_ command: String?) -> String? {
        guard let command else { return nil }
        for shell in ["/bin/zsh", "/bin/bash", "/bin/sh", "zsh", "bash", "sh"] {
            for flag in [" -lc '", " -c '"] {
                let prefix = shell + flag
                guard command.hasPrefix(prefix), command.hasSuffix("'"), command.count > prefix.count else { continue }
                return String(command.dropFirst(prefix.count).dropLast()).replacingOccurrences(of: #"'\''"#, with: "'")
            }
        }
        return command
    }
}
