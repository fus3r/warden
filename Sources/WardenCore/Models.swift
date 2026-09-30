import Foundation

public enum AgentProvider: String, Codable, CaseIterable, Identifiable, Sendable {
    case codex = "Codex"
    case claude = "Claude"

    public var id: String { rawValue }
}

public enum AgentPhase: String, Codable {
    case working
    case needsAttention
    case finished
    case idle
    case unknown
}

public enum AttentionKind: String, Codable {
    case question
    case permission
    case failure
    case notification
    /// Stopped with Esc or a declined tool; the agent waits for what to do instead.
    case interrupted
    /// Claude's AskUserQuestion prompt, which holds the turn until you pick an answer.
    case choice
}

public enum Evidence: String, Codable {
    case provider
    case localLog
    case inferred
}

public struct UsageWindow: Codable, Equatable, Identifiable {
    public var id: String
    public var provider: AgentProvider
    public var label: String
    public var usedPercent: Double
    public var resetsAt: Date?
    public var observedAt: Date
    public var evidence: Evidence
    public var minutes: Int?
    /// The model a limit applies to, such as Claude's weekly limit on one model. Nil for a plan-wide window.
    public var scope: String?
    /// The account the limit belongs to, such as "work". Nil for the default account.
    public var account: String?

    public init(id: String, provider: AgentProvider, label: String, usedPercent: Double,
                resetsAt: Date?, observedAt: Date, evidence: Evidence, minutes: Int? = nil, scope: String? = nil,
                account: String? = nil) {
        self.id = id
        self.provider = provider
        self.label = label
        self.usedPercent = usedPercent
        self.resetsAt = resetsAt
        self.observedAt = observedAt
        self.evidence = evidence
        self.minutes = minutes
        self.scope = scope
        self.account = account
    }

    /// The id of a provider's window for an account: "Claude-five_hour", or "Claude-work-five_hour".
    public static func id(_ provider: AgentProvider, _ key: String, account: String?) -> String {
        ([provider.rawValue, account, key].compactMap { $0 }).joined(separator: "-")
    }

    /// "Claude 5h", or "Fable 7d" for a limit on one model, whose name already says which provider it is.
    /// Another account's limits start with its name: "work 5h", "work Fable 7d".
    public var rowLabel: String {
        ([account ?? scope ?? provider.rawValue, account == nil ? nil : scope, shortLabel].compactMap { $0 }).joined(separator: " ")
    }

    /// Full name for sentences and alerts: "Claude 5h", "Claude Fable 7d", "Claude (work) 5h".
    public var name: String {
        ([provider.rawValue + (account.map { " (\($0))" } ?? "")] + [scope, shortLabel].compactMap { $0 }).joined(separator: " ")
    }

    /// Window length from the provider log, or from Claude's documented window names.
    public var durationMinutes: Int? {
        if let minutes, minutes > 0 { return minutes }
        if id.hasSuffix("five_hour") { return 300 }
        if id.hasSuffix("seven_day") { return 10_080 }
        return nil
    }

    public var shortLabel: String {
        guard let minutes = durationMinutes else { return label }
        if minutes % 1440 == 0 { return "\(minutes / 1440)d" }
        if minutes % 60 == 0 { return "\(minutes / 60)h" }
        return "\(minutes)m"
    }
}

/// What an account's plan holds besides its limit windows, as its provider's CLI reports it.
public struct PlanDetails: Equatable {
    public var provider: AgentProvider
    /// The plan's name as reported, such as "max" or "prolite".
    public var plan: String?
    /// Codex credits left, as reported, when the account has any.
    public var credits: String?
    public var unlimitedCredits = false
    /// Codex limit resets the account holds, which Codex can spend to reset a limit early.
    public var resets = 0
    /// When each of those resets expires unused, soonest first.
    public var resetsExpire: [Date] = []
    /// The account, such as "work". Nil for the default account.
    public var account: String?

    public init(provider: AgentProvider, plan: String?, credits: String? = nil, unlimitedCredits: Bool = false, resets: Int = 0) {
        self.provider = provider
        self.plan = plan
        self.credits = credits
        self.unlimitedCredits = unlimitedCredits
        self.resets = resets
    }

    /// "Max", "Pro Lite".
    public var planName: String? {
        guard let plan, !plan.isEmpty else { return nil }
        let spaced = plan.replacingOccurrences(of: "prolite", with: "pro lite").replacingOccurrences(of: "_", with: " ")
        return spaced.split(separator: " ").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }
}

/// The process that runs an agent session and the app that hosts its terminal.
public struct SessionHost: Codable, Equatable {
    public var pid: Int32?
    public var processName: String?
    public var tty: String?
    public var bundleID: String?
    public var termProgram: String?

    public init(pid: Int32? = nil, processName: String? = nil, tty: String? = nil,
                bundleID: String? = nil, termProgram: String? = nil) {
        self.pid = pid
        self.processName = processName
        self.tty = tty
        self.bundleID = bundleID
        self.termProgram = termProgram
    }
}

public struct AgentSession: Codable, Equatable, Identifiable {
    public var id: String
    public var provider: AgentProvider
    public var surface: String
    public var cwd: String
    public var model: String?
    public var phase: AgentPhase
    public var phaseEvidence: Evidence
    public var attention: AttentionKind?
    public var updatedAt: Date
    public var contextPercent: Double?
    public var contextEvidence: Evidence?
    public var lastInputTokens: Int?
    public var totalTokens: Int?
    public var windows: [UsageWindow]
    public var title: String?
    /// Question excerpt, tool awaiting approval, or failure type. Kept in memory only.
    public var detail: String?
    public var host: SessionHost?
    public var turnStartedAt: Date?
    public var ended = false
    /// Subagents of this session still working, such as Claude background agents or threads Codex spawned.
    public var activeSubagents = 0
    /// A Codex thread that works for another session, such as a spawned subagent or a review. Listed with its parent.
    public var isSubagent = false
    public var parentID: String?
    /// When a session stopped by a usage limit continues on its own, as Claude Code does after the reset.
    public var resumesAt: Date?
    /// How long the provider keeps the session's prompt cache, from its last cache write: an hour or five minutes.
    public var cacheMinutes: Int?
    /// When the session's last model request was answered. Each request that reads the cache renews it from then.
    public var lastRequestAt: Date?
    /// The model id from the session's log, such as "claude-opus-5-5". `model` may hold a display name instead.
    public var modelID: String?
    /// The prompt cache as Claude Code last reported it in its status line, with when it reported it.
    public var statusCache: StatusCache?
    public var statusCacheAt: Date?
    /// A request Claude Code is retrying after an error, as its log records each attempt. Nil once a reply arrives.
    public var retry: RequestRetry?
    /// The prompt id of the Claude turn the log's tail ends in, so a turn keeps its start once its prompt leaves the tail.
    public var turnPromptID: String?
    /// A Claude background session's short id, which `claude attach` takes.
    public var backgroundID: String?
    /// The account the session runs in, such as "work". Nil for the default account.
    public var account: String?
    /// Run by a program rather than a person at a prompt, as Claude Code's SDK and `codex exec` do. Such a run ends
    /// when its turn ends, so it can wait for you only while its process lives.
    public var isHeadless = false
    /// Claude Code calls the session busy although its log shows the turn ended, as it does while a command the
    /// session started in the background still runs. Claude goes on when that command ends.
    public var busyInBackground = false

    public var project: String {
        if cwd.isEmpty { return provider.rawValue }
        let name = URL(fileURLWithPath: cwd).lastPathComponent
        return name.isEmpty ? provider.rawValue : name
    }

    public init(id: String, provider: AgentProvider, surface: String, cwd: String,
                model: String? = nil, phase: AgentPhase = .unknown,
                phaseEvidence: Evidence = .localLog,
                attention: AttentionKind? = nil, updatedAt: Date,
                contextPercent: Double? = nil, contextEvidence: Evidence? = nil,
                lastInputTokens: Int? = nil, totalTokens: Int? = nil,
                windows: [UsageWindow] = [], title: String? = nil, detail: String? = nil,
                host: SessionHost? = nil, turnStartedAt: Date? = nil) {
        self.id = id
        self.provider = provider
        self.surface = surface
        self.cwd = cwd
        self.model = model
        self.phase = phase
        self.phaseEvidence = phaseEvidence
        self.attention = attention
        self.updatedAt = updatedAt
        self.contextPercent = contextPercent
        self.contextEvidence = contextEvidence
        self.lastInputTokens = lastInputTokens
        self.totalTokens = totalTokens
        self.windows = windows
        self.title = title
        self.detail = detail
        self.host = host
        self.turnStartedAt = turnStartedAt
    }
}

/// The health of a session's prompt cache as Claude Code reports it in its status line, since 2.1.251.
public struct StatusCache: Codable, Equatable {
    /// The cached prefix is still inside its lifetime.
    public var warm: Bool
    /// The lifetime the last request wrote, in minutes: 5 or 60.
    public var minutes: Int?
    public var expiresAt: Date?
    /// Tokens the next request writes to the cache again if it comes after the cache expired.
    public var recacheTokens: Int?
    /// Cache reads over all input this session, from 0 to 1.
    public var hitRatio: Double?
    /// Requests whose cached prefix shrank without a compaction to explain it, and the tokens they wrote again.
    public var misses: Int?
    public var missTokens: Int?
    /// Claude Code's likely causes of the latest miss, such as "tools_changed" or "ttl_expired_1h".
    public var lastMissCauses: [String]?
    public var lastMissAt: Date?

    public init(warm: Bool, minutes: Int? = nil, expiresAt: Date? = nil, recacheTokens: Int? = nil, hitRatio: Double? = nil,
                misses: Int? = nil, missTokens: Int? = nil, lastMissCauses: [String]? = nil, lastMissAt: Date? = nil) {
        self.warm = warm
        self.minutes = minutes
        self.expiresAt = expiresAt
        self.recacheTokens = recacheTokens
        self.hitRatio = hitRatio
        self.misses = misses
        self.missTokens = missTokens
        self.lastMissCauses = lastMissCauses
        self.lastMissAt = lastMissAt
    }

    /// Reads the status line's `prompt_cache` object. Nil when absent or when no response reported cache tokens.
    public init?(statusLine object: [String: Any]?) {
        guard let object, object["caching_observed"] as? Bool != false, let warm = object["warm"] as? Bool else { return nil }
        func number(_ key: String) -> Double? { (object[key] as? NSNumber)?.doubleValue }
        self.init(warm: warm,
                  minutes: (object["ttl"] as? String).flatMap { $0 == "1h" ? 60 : $0 == "5m" ? 5 : nil },
                  expiresAt: number("expires_at").map(Date.init(timeIntervalSince1970:)),
                  recacheTokens: number("recache_tokens_if_cold").map { Int($0) },
                  hitRatio: number("hit_ratio"),
                  misses: number("misses").map { Int($0) },
                  missTokens: number("miss_recache_tokens").map { Int($0) },
                  lastMissCauses: ((object["last_miss_cause"] as? [String: Any])?["causes"] as? [String]).map { Array($0.prefix(4)) },
                  lastMissAt: number("last_miss_at").map(Date.init(timeIntervalSince1970:)))
    }
}

/// Claude Code retrying a request that failed, such as when the network is down.
public struct RequestRetry: Codable, Equatable {
    public var attempt: Int
    public var maxAttempts: Int
    public var networkDown: Bool
    public var at: Date

    public init(attempt: Int, maxAttempts: Int, networkDown: Bool, at: Date) {
        self.attempt = attempt
        self.maxAttempts = maxAttempts
        self.networkDown = networkDown
        self.at = at
    }
}

public struct BridgeStatus: Codable {
    public var sessionID: String
    public var cwd: String
    public var projectDir: String?
    public var sessionName: String?
    public var model: String?
    public var contextPercent: Double?
    public var totalTokens: Int?
    public var windows: [UsageWindow]
    public var host: SessionHost?
    public var updatedAt: Date
    /// The account the session runs in, from `CLAUDE_CONFIG_DIR`. Nil for the default account.
    public var account: String?
    /// The model id, such as "claude-opus-5-5", beside `model`, its display name.
    public var modelID: String?
    public var cache: StatusCache?

    public init(sessionID: String, cwd: String, projectDir: String? = nil, sessionName: String? = nil,
                model: String?, contextPercent: Double?, totalTokens: Int?,
                windows: [UsageWindow], host: SessionHost? = nil, updatedAt: Date, account: String? = nil,
                modelID: String? = nil, cache: StatusCache? = nil) {
        self.sessionID = sessionID
        self.cwd = cwd
        self.projectDir = projectDir
        self.sessionName = sessionName
        self.model = model
        self.contextPercent = contextPercent
        self.totalTokens = totalTokens
        self.windows = windows
        self.host = host
        self.updatedAt = updatedAt
        self.account = account
        self.modelID = modelID
        self.cache = cache
    }
}

public struct BridgeEvent: Codable, Identifiable {
    public var id: String
    public var sessionID: String
    public var cwd: String
    public var kind: String
    public var at: Date
    /// Tool name for an approval or error type for a failure. Never prompt or reply text.
    public var detail: String?
    public var host: SessionHost?

    public init(id: String, sessionID: String, cwd: String, kind: String, at: Date,
                detail: String? = nil, host: SessionHost? = nil) {
        self.id = id
        self.sessionID = sessionID
        self.cwd = cwd
        self.kind = kind
        self.at = at
        self.detail = detail
        self.host = host
    }
}

public struct AgentProcess: Equatable, Identifiable {
    public var id: Int
    public var provider: AgentProvider
    public var surface: String
    public var cwd: String?
    public var tty: String?
    public var hostBundleID: String?

    public init(id: Int, provider: AgentProvider, surface: String, cwd: String? = nil,
                tty: String? = nil, hostBundleID: String? = nil) {
        self.id = id
        self.provider = provider
        self.surface = surface
        self.cwd = cwd
        self.tty = tty
        self.hostBundleID = hostBundleID
    }
}

public enum WardenPaths {
    public static var support: URL {
        #if DEBUG
        if let path = ProcessInfo.processInfo.environment["WARDEN_SUPPORT_DIR"] {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        let folder = "WardenPreview"
        #else
        let folder = "Warden"
        #endif
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/\(folder)", isDirectory: true)
    }

    public static var statusDirectory: URL { support.appendingPathComponent("status", isDirectory: true) }
    public static var eventDirectory: URL { support.appendingPathComponent("events", isDirectory: true) }
    public static var usageFile: URL { support.appendingPathComponent("usage.json") }
    /// Session counts for scripts, written by the app when they change. It holds no titles or folders.
    public static var stateFile: URL { support.appendingPathComponent("state.json") }
}

/// What `WardenBridge status` reports: session counts from the app, and the latest value of each limit.
public struct WardenState: Codable, Equatable {
    public var needsYou: Int
    public var working: Int
    public var updatedAt: Date

    public init(needsYou: Int, working: Int, updatedAt: Date) {
        self.needsYou = needsYou
        self.working = working
        self.updatedAt = updatedAt
    }

    /// One line for a status bar: "1 needs you · 2 working · Claude 5h 87% · Fable 7d 94%".
    public static func line(state: WardenState?, windows: [UsageWindow], now: Date = Date()) -> String {
        var parts: [String] = []
        if let state, now.timeIntervalSince(state.updatedAt) < 120 {
            if state.needsYou > 0 { parts.append(state.needsYou == 1 ? "1 needs you" : "\(state.needsYou) need you") }
            if state.working > 0 { parts.append("\(state.working) working") }
        }
        parts += windows.filter { $0.isCurrent(now: now) }
            .map { "\($0.rowLabel) \(Int($0.usedPercent.rounded()))%" }
        return parts.isEmpty ? "No agents" : parts.joined(separator: " · ")
    }
}

public enum PromptAdvice {
    public static func seemsToAskQuestion(_ text: String) -> Bool {
        // Replies often wrap the closing question in Markdown emphasis or quotes.
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "*_`\"')»”")))
        guard let last = trimmed.last, last == "?" || last == "？" else { return false }
        return trimmed.suffix(700).filter { $0 == "?" || $0 == "？" }.count <= 3
    }

    /// The closing question of a reply, trimmed for a one-line menu subtitle.
    public static func questionExcerpt(_ text: String) -> String? {
        guard seemsToAskQuestion(text) else { return nil }
        let line = text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .last { !$0.isEmpty } ?? ""
        var cleaned = line.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "")
        cleaned = cleaned.trimmingCharacters(in: CharacterSet(charactersIn: "#>-*• ").union(.whitespaces))
        if let range = cleaned.range(of: #"[.!:]\s+(?=[^.!:]*\?$)"#, options: .regularExpression) {
            cleaned = String(cleaned[range.upperBound...])
        }
        return cleaned.isEmpty ? nil : String(cleaned.prefix(200))
    }
}

/// Maps a Claude Code hook event to the state Warden records. Returns nil for events that change nothing.
public enum ClaudeHookEvent {
    public static func kind(event: String, notification: String? = nil, lastMessage: String? = nil) -> String? {
        switch event {
        case "UserPromptSubmit": return "working"
        case "PermissionRequest": return "permission"
        case "StopFailure": return "failure"
        case "SessionEnd": return "ended"
        case "Stop": return PromptAdvice.seemsToAskQuestion(lastMessage ?? "") ? "question" : "finished"
        case "Notification":
            switch notification {
            case "permission_prompt": return "permission"
            case "elicitation_dialog", "elicitation_url_dialog", "agent_needs_input": return "question"
            // Since 2.1.234 Claude Code continues a task by itself when a usage limit resets. It says when it did, and
            // when it will not: the reset came during a long sleep and it waits for Enter, or continuing is turned off.
            case "quota_auto_resume_fired": return "working"
            case "quota_auto_resume_stale", "quota_auto_resume_disabled": return "limit-wait"
            default: return nil
            }
        default: return nil
        }
    }
}
