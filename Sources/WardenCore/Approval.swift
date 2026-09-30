import Foundation

/// A permission request or question that Warden can answer. For Claude Code, the bridge holds the PermissionRequest
/// hook open while Warden shows the request; for Codex, the shared app-server daemon sends it to every client of the
/// thread. Either way the terminal keeps its own prompt, and the agent takes the first answer. Warden keeps requests
/// in memory only.
public struct ApprovalRequest: Codable, Equatable, Identifiable {
    public struct Question: Codable, Equatable {
        public var text: String
        public var options: [String]
        public var multiSelect: Bool
        /// Codex answers a question by its id. Claude Code's questions have none.
        public var id: String? = nil
    }

    public var id: String
    public var sessionID: String
    public var tool: String
    /// What the tool would do, trimmed for one line: a command, a file, a URL.
    public var summary: String?
    /// Claude Code offers a rule to allow this kind of call again, which Warden applies to the session only.
    public var canAllowForSession: Bool
    /// The questions of an AskUserQuestion prompt, answered with one of their options.
    public var questions: [Question]
    /// The rule Claude Code would keep in a settings file, as its "Yes, and don't ask again" does, such as
    /// "Bash(npm test *)". Nil when it offers none.
    public var alwaysRule: String?
    /// Where Claude Code keeps that rule: `localSettings`, `projectSettings`, or `userSettings`.
    public var alwaysIn: String?
    /// The session's folder, which names it before Warden has scanned the session.
    public var cwd: String?
    /// The bridge sends Claude Code's requests without it.
    public var provider: AgentProvider = .claude

    /// The file that holds a kept rule, for a sentence. Codex requests name their rules file in `alwaysIn`.
    public var alwaysFile: String? {
        switch alwaysIn {
        case "localSettings": return "this project's .claude/settings.local.json"
        case "projectSettings": return "this project's .claude/settings.json"
        case "userSettings": return "~/.claude/settings.json"
        default: return provider == .codex ? alwaysIn : nil
        }
    }

    public var isQuestion: Bool { tool == "AskUserQuestion" || !questions.isEmpty }
}

extension ApprovalRequest {
    /// Requests from a bridge built before Warden answered Codex carry no provider.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        sessionID = try container.decode(String.self, forKey: .sessionID)
        tool = try container.decode(String.self, forKey: .tool)
        summary = try container.decodeIfPresent(String.self, forKey: .summary)
        canAllowForSession = try container.decode(Bool.self, forKey: .canAllowForSession)
        questions = try container.decode([Question].self, forKey: .questions)
        alwaysRule = try container.decodeIfPresent(String.self, forKey: .alwaysRule)
        alwaysIn = try container.decodeIfPresent(String.self, forKey: .alwaysIn)
        cwd = try container.decodeIfPresent(String.self, forKey: .cwd)
        provider = try container.decodeIfPresent(AgentProvider.self, forKey: .provider) ?? .claude
    }
}

/// Warden's answer, sent back to the bridge. No behavior means Warden did not decide, and the terminal's prompt stays.
public struct ApprovalAnswer: Codable, Equatable {
    public var behavior: String?
    public var forSession = false
    /// Keep Claude Code's suggested rule where it suggests, so it no longer asks for this kind of call.
    public var always: Bool?
    /// Option chosen for each question, by question text.
    public var answers: [String: String]?

    public init(behavior: String? = nil, forSession: Bool = false, always: Bool? = nil, answers: [String: String]? = nil) {
        self.behavior = behavior
        self.forSession = forSession
        self.always = always
        self.answers = answers
    }

    public static let allow = ApprovalAnswer(behavior: "allow")
    public static let allowForSession = ApprovalAnswer(behavior: "allow", forSession: true)
    public static let allowAlways = ApprovalAnswer(behavior: "allow", always: true)
    public static let deny = ApprovalAnswer(behavior: "deny")
    public static let undecided = ApprovalAnswer()
}

public enum Approval {
    /// Socket where Warden takes requests, in a folder only the user can open.
    public static var socket: URL { WardenPaths.support.appendingPathComponent("ipc/approvals.sock") }

    /// The request Warden shows, from the PermissionRequest hook input.
    public static func request(from hook: [String: Any], id: String, sessionID: String) -> ApprovalRequest? {
        guard let tool = hook["tool_name"] as? String, !tool.isEmpty else { return nil }
        let input = hook["tool_input"] as? [String: Any] ?? [:]
        let suggestions = hook["permission_suggestions"] as? [[String: Any]] ?? []
        var questions: [ApprovalRequest.Question] = []
        if tool == "AskUserQuestion" {
            questions = (input["questions"] as? [[String: Any]] ?? []).compactMap { question in
                guard let text = question["question"] as? String else { return nil }
                let options = (question["options"] as? [[String: Any]] ?? []).compactMap { $0["label"] as? String }
                return ApprovalRequest.Question(text: text, options: options, multiSelect: question["multiSelect"] as? Bool ?? false)
            }
        }
        let persistent = persistentRules(suggestions)
        let kept = persistent.flatMap { $0["rules"] as? [[String: Any]] ?? [] }.compactMap { rule -> String? in
            guard let tool = rule["toolName"] as? String else { return nil }
            return (rule["ruleContent"] as? String).map { "\(tool)(\($0))" } ?? tool
        }
        return ApprovalRequest(id: id, sessionID: sessionID, tool: tool, summary: summary(tool: tool, input: input, cwd: hook["cwd"] as? String),
                               canAllowForSession: !suggestions.isEmpty, questions: questions,
                               alwaysRule: kept.isEmpty ? nil : kept.joined(separator: ", "),
                               alwaysIn: kept.isEmpty ? nil : persistent.first?["destination"] as? String,
                               cwd: hook["cwd"] as? String)
    }

    /// Allow rules Claude Code offers to keep in a settings file rather than for the session only.
    static func persistentRules(_ suggestions: [[String: Any]]) -> [[String: Any]] {
        suggestions.filter { suggestion in
            suggestion["type"] as? String == "addRules" && suggestion["behavior"] as? String == "allow"
                && ["localSettings", "projectSettings", "userSettings"].contains(suggestion["destination"] as? String ?? "")
        }
    }

    /// The hook's output for Warden's answer, or nil to leave the decision to the terminal.
    public static func hookOutput(for answer: ApprovalAnswer, hook: [String: Any]) -> [String: Any]? {
        var decision: [String: Any]
        switch answer.behavior {
        case "allow":
            decision = ["behavior": "allow"]
            if answer.forSession {
                // The rule Claude Code offers, kept for this session only rather than saved to a settings file.
                let rules = (hook["permission_suggestions"] as? [[String: Any]] ?? []).map { suggestion -> [String: Any] in
                    var rule = suggestion
                    rule["destination"] = "session"
                    return rule
                }
                guard !rules.isEmpty else { return nil }
                decision["updatedPermissions"] = rules
            } else if answer.always == true {
                // As "Yes, and don't ask again" does in the terminal: Claude Code keeps its own rule where it says.
                let rules = persistentRules(hook["permission_suggestions"] as? [[String: Any]] ?? [])
                guard !rules.isEmpty else { return nil }
                decision["updatedPermissions"] = rules
            }
            if let answers = answer.answers {
                // AskUserQuestion takes its answers in the tool input, next to the questions.
                var input = hook["tool_input"] as? [String: Any] ?? [:]
                input["answers"] = answers
                decision["updatedInput"] = input
            }
        case "deny":
            // Like choosing No in the terminal: Claude stops and waits for what to do instead.
            decision = ["behavior": "deny", "message": "The user denied this from Warden.", "interrupt": true]
        default:
            return nil
        }
        return ["hookSpecificOutput": ["hookEventName": "PermissionRequest", "decision": decision]]
    }

    /// One line on what a tool call would do. Commands and paths stay in memory; the bridge's event file keeps
    /// only the tool name.
    static func summary(tool: String, input: [String: Any], cwd: String?) -> String? {
        let line = oneLine
        func path(_ value: Any?) -> String? {
            (value as? String).flatMap { shortPath($0, in: cwd) }
        }
        switch tool {
        case "Bash", "BashOutput": return line(input["command"])
        case "Edit", "MultiEdit", "Write", "Read", "NotebookEdit": return path(input["file_path"] ?? input["notebook_path"])
        case "WebFetch": return line(input["url"])
        case "WebSearch": return line(input["query"])
        case "Glob", "Grep": return line(input["pattern"])
        case "AskUserQuestion":
            return line(((input["questions"] as? [[String: Any]])?.first)?["question"])
        default:
            // MCP tools are named mcp__server__tool.
            let parts = tool.components(separatedBy: "__")
            return parts.count == 3 && parts[0] == "mcp" ? "\(parts[1]): \(parts[2])" : nil
        }
    }

    /// A command or text on one line, with ⏎ where it had line breaks, at most 240 characters.
    static func oneLine(_ value: Any?) -> String? {
        guard let text = value as? String else { return nil }
        let joined = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }.joined(separator: " ⏎ ")
        return joined.isEmpty ? nil : String(joined.prefix(240))
    }

    /// What a prompt asks, for a status line: "Wants to use Bash", or for Codex, "Wants to run a command".
    public static func wants(tool: String, provider: AgentProvider) -> String {
        switch (provider, tool) {
        case (.codex, "Command"): return "Wants to run a command"
        case (.codex, "Edit"): return "Wants to change files"
        default: return "Wants to use \(tool)"
        }
    }

    /// A path relative to the session's folder when it is inside it, otherwise from the home folder.
    static func shortPath(_ path: String, in cwd: String?) -> String? {
        guard !path.isEmpty else { return nil }
        if let cwd, !cwd.isEmpty, path.hasPrefix(cwd + "/") { return String(path.dropFirst(cwd.count + 1)) }
        return (path as NSString).abbreviatingWithTildeInPath
    }
}
