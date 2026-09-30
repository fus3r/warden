import Foundation

public enum TelemetryParser {
    private static let codexMarkers = ["\"session_meta\"", "\"turn_context\"", "\"task_started\"",
                                       "\"task_complete\"", "\"turn_aborted\"", "\"token_count\"",
                                       "\"request_user_input_async\""].map { Data($0.utf8) }
    private static let responseMarker = Data("\"response_item\"".utf8)
    private static let assistantMarker = Data("\"assistant\"".utf8)
    private static let userMarker = Data("\"role\":\"user\"".utf8)

    public static func codex(head: Data, tail: Data, filename: String, modifiedAt: Date, account: String? = nil) -> AgentSession? {
        var session = AgentSession(
            id: URL(fileURLWithPath: filename).deletingPathExtension().lastPathComponent,
            provider: .codex, surface: "Terminal", cwd: "", updatedAt: modifiedAt
        )
        session.account = account
        var sawMetadata = false
        var lastAssistant = ""
        /// A question Codex asked with its input tool. Codex acknowledges the call at once and keeps working; the
        /// question stays open until you send a message, the turn is stopped, or a new turn starts. Only a turn that
        /// ends with the question unanswered needs attention; the active turn still works.
        var openQuestion: String?
        /// Whether the lines read hold a turn's start or end. A turn longer than the tail read shows only its
        /// token counts.
        var sawTurnEvent = false
        var sawTokenCount = false

        for line in rawLines(head: head, tail: tail) {
            // Lines are filtered by bytes first.
            guard isRelevantCodexLine(line),
                  let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
                  let type = object["type"] as? String,
                  let payload = object["payload"] as? [String: Any] else { continue }
            switch type {
            case "session_meta":
                // A fork copies its parent's history, metadata included; the log's own identity is its first.
                guard !sawMetadata else { break }
                sawMetadata = true
                session.id = (payload["id"] as? String) ?? (payload["session_id"] as? String) ?? session.id
                session.cwd = (payload["cwd"] as? String) ?? session.cwd
                // Spawned threads and reviews work for another session and name it as their parent.
                if let source = payload["source"] as? [String: Any] {
                    session.isSubagent = true
                    let spawn = (source["subagent"] as? [String: Any])?["thread_spawn"] as? [String: Any]
                    session.parentID = spawn?["parent_thread_id"] as? String
                }
                if ["subagent", "guardian_review"].contains(payload["thread_source"] as? String) { session.isSubagent = true }
                let origin = (payload["originator"] as? String ?? "").lowercased()
                let source = (payload["source"] as? String ?? "").lowercased()
                // `codex exec` runs one task and exits.
                session.isHeadless = source == "exec" || origin.contains("exec")
                // The originator names the client. The desktop app, part of the ChatGPT app, reports the VS Code source,
                // and so does the terminal app since 0.157, which runs its threads in Codex's shared daemon.
                let terminal = origin.contains("tui") || origin.contains("exec")
                if !terminal, origin.contains("desktop") || origin.contains("app") || source.contains("app") || source.contains("desktop") {
                    session.surface = "ChatGPT"
                } else if !terminal, origin.contains("vscode") || source.contains("vscode") || source.contains("ide") {
                    session.surface = "VS Code"
                }
            case "turn_context":
                session.model = (payload["model"] as? String) ?? session.model
                session.cwd = (payload["cwd"] as? String) ?? session.cwd
            case "response_item":
                switch payload["type"] as? String {
                case "message" where payload["role"] as? String == "assistant":
                    if let content = payload["content"] as? [[String: Any]] {
                        let parts = content.compactMap { $0["text"] as? String }
                        if !parts.isEmpty { lastAssistant = parts.joined(separator: "\n") }
                    }
                case "function_call" where payload["name"] as? String == "request_user_input_async":
                    // This input tool is nonblocking: keep the question visible without reporting a stopped turn.
                    let arguments = (payload["arguments"] as? String).flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) }
                    let first = ((arguments as? [String: Any])?["questions"] as? [[String: Any]])?.first
                    let question = (first?["title"] as? String ?? first?["question"] as? String ?? "")
                        .split(whereSeparator: \.isWhitespace).joined(separator: " ")
                    openQuestion = String(question.prefix(200))
                    session.phase = .working
                    session.attention = .choice
                    session.detail = question.isEmpty ? nil : openQuestion
                case "message" where payload["role"] as? String == "user" && openQuestion != nil:
                    // Your message answers the open question, and the turn goes on.
                    openQuestion = nil
                    session.phase = .working
                    session.attention = nil
                    session.detail = nil
                default: break
                }
            case "event_msg":
                switch payload["type"] as? String {
                case "task_started":
                    sawTurnEvent = true
                    openQuestion = nil
                    session.phase = .working
                    session.attention = nil
                    session.detail = nil
                    session.turnStartedAt = double(payload["started_at"]).map(Date.init(timeIntervalSince1970:))
                        ?? timestamp(object)
                    lastAssistant = ""
                case "task_complete":
                    sawTurnEvent = true
                    if let error = payload["error"] as? [String: Any] {
                        // A turn that ended on an error, such as a usage limit or an overloaded server.
                        session.phase = .needsAttention
                        session.attention = .failure
                        let info = error["codex_error_info"]
                        session.detail = (info as? String) ?? (info as? [String: Any])?.keys.first ?? "other"
                        break
                    }
                    if let asked = openQuestion {
                        // The turn ended with its question still open.
                        session.phase = .needsAttention
                        session.attention = .choice
                        session.detail = asked.isEmpty ? nil : asked
                        break
                    }
                    let question = PromptAdvice.questionExcerpt(payload["last_agent_message"] as? String ?? lastAssistant)
                    session.phase = question == nil ? .finished : .needsAttention
                    session.attention = question == nil ? nil : .question
                    session.detail = question
                case "turn_aborted":
                    // Esc stops the turn, and Codex waits for what to do differently.
                    sawTurnEvent = true
                    openQuestion = nil
                    session.phase = .needsAttention
                    session.attention = .interrupted
                    session.detail = nil
                case "token_count":
                    sawTokenCount = true
                    if let info = payload["info"] as? [String: Any] {
                        let last = info["last_token_usage"] as? [String: Any] ?? [:]
                        let total = info["total_token_usage"] as? [String: Any] ?? [:]
                        let input = int(last["input_tokens"])
                        let capacity = int(info["model_context_window"])
                        if input > 0 { session.lastInputTokens = input }
                        if capacity > 0 && input > 0 {
                            session.contextPercent = min(100, Double(input) / Double(capacity) * 100)
                            session.contextEvidence = .inferred
                        }
                        if int(total["total_tokens"]) > 0 { session.totalTokens = int(total["total_tokens"]) }
                    }
                    if let rate = payload["rate_limits"] as? [String: Any] {
                        // Each limit bucket, such as a model's own limit, reports only on its turns: keep the latest of each.
                        for window in codexWindows(rate, observedAt: timestamp(object) ?? modifiedAt, account: account) {
                            session.windows.removeAll { $0.id == window.id }
                            session.windows.append(window)
                        }
                    }
                default: break
                }
            default: break
            }
        }
        // A turn longer than the tail shows no start or end, only the token counts of its replies: it still runs.
        if !sawTurnEvent, sawTokenCount, session.phase == .unknown { session.phase = .working }
        return sawMetadata || !session.cwd.isEmpty ? session : nil
    }

    public static func claude(head: Data, tail: Data, filename: String, modifiedAt: Date, account: String? = nil) -> AgentSession? {
        var session = AgentSession(
            id: URL(fileURLWithPath: filename).deletingPathExtension().lastPathComponent,
            provider: .claude, surface: "Terminal", cwd: "", updatedAt: modifiedAt
        )
        session.account = account
        var sawConversation = false
        var lastActivity: String?
        var promptID: String?
        var lastPrompt: String?
        /// The reset of the limit a request just hit, which Claude Code may wait for before continuing.
        var limitReset: Date?
        /// Claude Code writes its session's cost when it exits. Nothing after it means the session was closed.
        var closed = false
        for object in jsonLines(head: head, tail: tail) {
            guard let type = object["type"] as? String else { continue }
            if type == "cost-state" { closed = true }
            if type == "user" || type == "assistant" { closed = false }
            if type == "user" || type == "assistant", let time = object["timestamp"] as? String {
                lastActivity = time
                session.retry = nil
            }
            if type == "system", object["subtype"] as? String == "api_error", let attempt = object["retryAttempt"] as? Int,
               let time = timestamp(object) {
                // Claude Code retries a failed request by itself, up to its limit, before the turn fails.
                session.retry = RequestRetry(attempt: attempt, maxAttempts: object["maxRetries"] as? Int ?? attempt,
                                             networkDown: (object["error"] as? [String: Any])?["isNetworkDown"] as? Bool == true,
                                             at: time)
            }
            if let id = object["sessionId"] as? String { session.id = id }
            if let cwd = object["cwd"] as? String { session.cwd = cwd }
            if let entrypoint = (object["entrypoint"] as? String)?.lowercased() {
                if entrypoint.contains("desktop") { session.surface = "Claude Desktop" }
                else if entrypoint.contains("vscode") { session.surface = "VS Code" }
                // "sdk-cli" for `claude -p`, "sdk-ts" and "sdk-py" for programs built on the Agent SDK.
                session.isHeadless = entrypoint.hasPrefix("sdk")
            }
            if type == "ai-title", let title = object["aiTitle"] as? String, !title.isEmpty {
                session.title = title
            }
            if type == "last-prompt", let prompt = object["lastPrompt"] as? String { lastPrompt = prompt }
            if type == "system", object["subtype"] as? String == "informational", let reset = limitReset,
               (object["content"] as? String)?.contains("continuing automatically") == true {
                // "Usage limit reached · continuing automatically at 1:40am": the turn resumes after the reset.
                session.phase = .working
                session.attention = nil
                session.detail = nil
                session.resumesAt = reset
            }
            if type == "user" && object["isMeta"] as? Bool != true && !isLocalCommand(object) {
                sawConversation = true
                session.attention = nil
                session.detail = nil
                session.resumesAt = nil
                limitReset = nil
                if isInterruption(object) {
                    // Esc or a declined tool ends the turn without a hook, and Claude Code asks what to do instead.
                    session.phase = .needsAttention
                    session.attention = .interrupted
                } else {
                    session.phase = .working
                    if let id = object["promptId"] as? String {
                        // Tool results carry the prompt's id, so the first entry with a new id starts the turn.
                        if id != promptID { promptID = id; session.turnStartedAt = timestamp(object) }
                    } else if isPrompt(object) {
                        session.turnStartedAt = timestamp(object) ?? session.turnStartedAt
                    }
                }
            }
            if type == "assistant", object["isApiErrorMessage"] as? Bool == true {
                // A request that failed after its retries, such as a usage limit or a lost connection, ends the turn.
                // The error type matches the one the StopFailure hook reports.
                sawConversation = true
                session.phase = .needsAttention
                session.attention = .failure
                session.detail = object["error"] as? String
                session.resumesAt = nil
                let quota = object["quotaLimits"] as? [String: Any]
                limitReset = quota?["status"] as? String == "rejected" ? double(quota?["resetsAt"]).map(Date.init(timeIntervalSince1970:)) : nil
            } else if type == "assistant", let message = object["message"] as? [String: Any],
                      message["model"] as? String != "<synthetic>" {
                // Claude Code's own replies, such as "No response requested.", are no model turn and change nothing.
                sawConversation = true
                session.resumesAt = nil
                limitReset = nil
                session.model = (message["model"] as? String) ?? session.model
                let usage = message["usage"] as? [String: Any] ?? [:]
                let input = int(usage["input_tokens"]) + int(usage["cache_read_input_tokens"]) + int(usage["cache_creation_input_tokens"])
                if input > 0 {
                    session.lastInputTokens = input
                    session.lastRequestAt = timestamp(object) ?? session.lastRequestAt
                    session.modelID = session.model
                }
                let written = usage["cache_creation"] as? [String: Any] ?? [:]
                if int(written["ephemeral_1h_input_tokens"]) > 0 { session.cacheMinutes = 60 }
                else if int(written["ephemeral_5m_input_tokens"]) > 0 { session.cacheMinutes = 5 }
                let reason = message["stop_reason"] as? String
                if reason == "end_turn" {
                    let text = (message["content"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }.joined(separator: "\n")
                    let question = PromptAdvice.questionExcerpt(text)
                    session.phase = question == nil ? .finished : .needsAttention
                    session.attention = question == nil ? nil : .question
                    session.detail = question
                } else if reason == "refusal" {
                    // The model declined to go on; the turn ends and waits for what you do instead.
                    session.phase = .needsAttention
                    session.attention = .failure
                    session.detail = "refusal"
                } else if reason == "tool_use" {
                    // A turn can resume without a new prompt, as after a usage limit resets.
                    session.phase = .working
                    session.attention = nil
                    session.detail = nil
                    let blocks = message["content"] as? [[String: Any]] ?? []
                    if let ask = blocks.first(where: { $0["type"] as? String == "tool_use" && $0["name"] as? String == "AskUserQuestion" }) {
                        // The turn waits for your answer, which arrives as the tool result.
                        session.phase = .needsAttention
                        session.attention = .choice
                        let questions = (ask["input"] as? [String: Any])?["questions"] as? [[String: Any]] ?? []
                        let question = (questions.first?["question"] as? String ?? "").split(whereSeparator: \.isWhitespace).joined(separator: " ")
                        session.detail = question.isEmpty ? nil : String(question.prefix(200))
                    }
                }
            }
        }
        // Title and mode records are appended after a session ends, so activity comes from message timestamps.
        if let time = lastActivity.flatMap(parseDate) { session.updatedAt = min(time, modifiedAt) }
        if closed {
            // Nothing waits in a session that was closed, as when its process is gone.
            session.ended = true
            if session.phase == .working || session.phase == .needsAttention {
                session.phase = .idle
                session.attention = nil
                session.detail = nil
            }
        }
        session.turnPromptID = promptID
        // SDK sessions, and new ones before Claude Code names them, have no generated title. Their prompt names them.
        if session.title == nil, let prompt = lastPrompt {
            let line = prompt.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            if !line.isEmpty { session.title = String(line.prefix(120)) }
        }
        return sawConversation && !session.cwd.isEmpty ? session : nil
    }

    public static func merge(_ session: AgentSession, status: BridgeStatus?, event: BridgeEvent?) -> AgentSession {
        var result = session
        result.account = event?.account ?? result.account
        if let status {
            if let dir = status.projectDir, !dir.isEmpty { result.cwd = dir }
            else if !status.cwd.isEmpty { result.cwd = status.cwd }
            result.model = status.model ?? result.model
            result.contextPercent = status.contextPercent ?? result.contextPercent
            if status.contextPercent != nil { result.contextEvidence = .provider }
            result.totalTokens = status.totalTokens ?? result.totalTokens
            result.windows = status.windows.isEmpty ? result.windows : status.windows
            if let name = status.sessionName, !name.isEmpty { result.title = name }
            result.host = status.host ?? result.host
            result.account = status.account ?? result.account
            result.modelID = status.modelID ?? result.modelID
            if let cache = status.cache {
                result.statusCache = cache
                result.statusCacheAt = status.updatedAt
            }
            result.updatedAt = max(result.updatedAt, status.updatedAt)
        }
        // An event applies unless the session log shows conversation activity after it,
        // such as a tool result after an approval or a turn that continued without a new prompt.
        // Events are allowed two seconds of lag, except over a stop that no hook may report:
        // a prompt interrupted a second after it was sent must not look like it is still running.
        let stopped = session.attention == .interrupted || session.attention == .failure
        if let event, event.at >= session.updatedAt.addingTimeInterval(stopped ? 0 : -2) {
            result.updatedAt = max(result.updatedAt, event.at)
            result.phaseEvidence = .provider
            result.host = event.host ?? result.host
            switch event.kind {
            case "working":
                result.phase = .working
                result.attention = nil
                result.detail = nil
                result.turnStartedAt = event.at
                result.resumesAt = nil
            case "question", "finished":
                // The transcript holds the same final reply, so its reading decides between a question and a
                // finished task. This also discards Claude's idle reminder, which older bridges recorded as a question.
                let transcriptEnded = session.phase == .finished || session.attention == .question
                let asked = transcriptEnded ? session.attention == .question : event.kind == "question"
                result.phase = asked ? .needsAttention : .finished
                result.attention = asked ? .question : nil
                result.detail = asked ? session.detail : nil
            case "permission":
                result.phase = .needsAttention
                if event.detail == "AskUserQuestion" {
                    // Claude's question prompt also runs the permission hook; the log holds the question itself.
                    result.attention = .choice
                    result.detail = session.attention == .choice ? session.detail : nil
                } else {
                    result.attention = .permission
                    result.detail = event.detail
                }
            case "failure":
                // Claude continues by itself after a usage limit resets; its log says so and the hook does not.
                guard session.resumesAt == nil else { break }
                result.phase = .needsAttention
                result.attention = .failure
                result.detail = event.detail ?? (session.attention == .failure ? session.detail : nil)
            case "limit-wait":
                // Claude Code will not continue by itself after all, whatever its log said earlier.
                result.phase = .needsAttention
                result.attention = .failure
                result.detail = event.detail ?? "rate_limit"
                result.resumesAt = nil
            case "notification":
                result.phase = .needsAttention
                result.attention = .notification
                result.detail = nil
            case "idle":
                result.phase = .idle
                result.attention = nil
                result.detail = nil
            case "ended":
                result.phase = .idle
                result.attention = nil
                result.detail = nil
                result.ended = true
            default: break
            }
        }
        return result
    }

    /// Latest thread name per Codex session from the tail of `session_index.jsonl`.
    /// A partial first line fails to parse and is skipped.
    public static func codexTitles(_ data: Data) -> [String: String] {
        var titles: [String: String] = [:]
        for line in data.split(separator: 10) {
            guard let object = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any],
                  let id = object["id"] as? String,
                  let name = object["thread_name"] as? String, !name.isEmpty else { continue }
            titles[id] = name
        }
        return titles
    }

    /// Limits from `account/rateLimits/read` in the Codex app-server protocol, one set per limit bucket.
    public static func codexAccountWindows(_ result: [String: Any], observedAt: Date, account: String? = nil) -> [UsageWindow] {
        let buckets = (result["rateLimitsByLimitId"] as? [String: Any])?.values.compactMap { $0 as? [String: Any] }
            ?? [result["rateLimits"] as? [String: Any]].compactMap { $0 }
        return buckets.flatMap { limits -> [UsageWindow] in
            let bucket = codexBucket(id: limits["limitId"] as? String, name: limits["limitName"] as? String)
            return ["primary", "secondary"].compactMap { key in
                guard let window = limits[key] as? [String: Any], let percent = double(window["usedPercent"]) else { return nil }
                let minutes = int(window["windowDurationMins"])
                return UsageWindow(id: UsageWindow.id(.codex, bucket.prefix + key, account: account), provider: .codex,
                                   label: minutes > 0 ? "\(minutes) min" : "quota",
                                   usedPercent: percent, resetsAt: double(window["resetsAt"]).map(Date.init(timeIntervalSince1970:)),
                                   observedAt: observedAt, evidence: .provider, minutes: minutes > 0 ? minutes : nil,
                                   scope: bucket.scope, account: account)
            }
        }
        .sorted { $0.id < $1.id }
    }

    /// The plan, credits, and banked limit resets from `account/rateLimits/read`. Warden only reads them.
    public static func codexPlan(_ result: [String: Any]) -> PlanDetails? {
        guard let limits = result["rateLimits"] as? [String: Any] else { return nil }
        let credits = limits["credits"] as? [String: Any] ?? [:]
        let balance = (credits["balance"] as? String) ?? (credits["balance"] as? NSNumber)?.stringValue
        let banked = result["rateLimitResetCredits"] as? [String: Any]
        var plan = PlanDetails(provider: .codex, plan: limits["planType"] as? String,
                               credits: credits["hasCredits"] as? Bool == true ? balance : nil,
                               unlimitedCredits: credits["unlimited"] as? Bool == true,
                               resets: int(banked?["availableCount"]))
        // A banked reset that expires unused is lost, so the soonest expiry is worth showing.
        plan.resetsExpire = (banked?["credits"] as? [[String: Any]] ?? [])
            .filter { ($0["status"] as? String ?? "available") == "available" }
            .compactMap { double($0["expiresAt"]).map(Date.init(timeIntervalSince1970:)) }
            .sorted()
        return plan
    }

    /// The plan named by `get_usage`, such as "max".
    public static func claudePlan(_ result: [String: Any]) -> PlanDetails? {
        (result["subscription_type"] as? String).map { PlanDetails(provider: .claude, plan: $0) }
    }

    /// Plan limits from `get_usage` in Claude Code's control protocol, the data behind its `/usage` screen.
    /// Windows keep the status line's ids so the newer reading of each wins.
    public static func claudeAccountWindows(_ result: [String: Any], observedAt: Date, account: String? = nil) -> [UsageWindow] {
        guard let limits = result["rate_limits"] as? [String: Any] else { return [] }
        // The endpoint gives microseconds and the status line whole seconds. One value keeps alert keys stable.
        func reset(_ window: [String: Any]) -> Date? {
            ((window["resets_at"] as? String).flatMap(parseDate) ?? double(window["resets_at"]).map(Date.init(timeIntervalSince1970:)))
                .map { Date(timeIntervalSince1970: $0.timeIntervalSince1970.rounded()) }
        }
        var windows: [UsageWindow] = [("five_hour", "5h", 300), ("seven_day", "7d", 10_080)].compactMap { field, label, minutes in
            guard let window = limits[field] as? [String: Any], let percent = double(window["utilization"]) else { return nil }
            return UsageWindow(id: UsageWindow.id(.claude, field, account: account), provider: .claude, label: label,
                               usedPercent: percent, resetsAt: reset(window), observedAt: observedAt, evidence: .provider,
                               minutes: minutes, account: account)
        }
        // A weekly limit on one model can run out while the plan's own week has room, which stops that model only.
        // `/usage` lists these under `model_scoped`; older replies name Opus and Sonnet in their own fields.
        let week = windows.first { $0.id.hasSuffix("seven_day") }?.resetsAt
        var scoped: [(name: String, window: [String: Any], weekly: Bool)] = [("Opus", "seven_day_opus"), ("Sonnet", "seven_day_sonnet")]
            .compactMap { name, field in (limits[field] as? [String: Any]).map { (name, $0, true) } }
        for entry in limits["model_scoped"] as? [[String: Any]] ?? [] {
            guard let name = entry["display_name"] as? String, !name.isEmpty else { continue }
            // An entry gives no length. One that resets with the plan's week is weekly.
            var weekly = false
            if let resets = reset(entry), let week { weekly = abs(resets.timeIntervalSince(week)) < 3600 }
            scoped.append((name, entry, weekly))
        }
        for (name, window, weekly) in scoped {
            let id = UsageWindow.id(.claude, "model-\(name.lowercased())", account: account)
            guard let percent = double(window["utilization"]), !windows.contains(where: { $0.id == id }) else { continue }
            windows.append(UsageWindow(id: id, provider: .claude, label: weekly ? "7d" : "limit", usedPercent: percent,
                                       resetsAt: reset(window), observedAt: observedAt, evidence: .provider,
                                       minutes: weekly ? 10_080 : nil, scope: name, account: account))
        }
        // Extra usage, billed beyond the plan up to a monthly limit, when it is turned on.
        if let extra = limits["extra_usage"] as? [String: Any], extra["is_enabled"] as? Bool == true,
           let percent = double(extra["utilization"]) {
            windows.append(extraUsage(percent, resetsAt: nil, observedAt: observedAt, account: account))
        }
        return windows
    }

    /// The share of the extra usage spending limit used. The status line reports it as `rate_limits.spend_limit`.
    public static func extraUsage(_ percent: Double, resetsAt: Date?, observedAt: Date, account: String? = nil) -> UsageWindow {
        UsageWindow(id: UsageWindow.id(.claude, "extra_usage", account: account), provider: .claude, label: "extra",
                    usedPercent: percent, resetsAt: resetsAt, observedAt: observedAt, evidence: .provider, account: account)
    }

    private static func codexWindows(_ rate: [String: Any], observedAt: Date, account: String?) -> [UsageWindow] {
        let bucket = codexBucket(id: rate["limit_id"] as? String, name: rate["limit_name"] as? String)
        var output: [UsageWindow] = []
        for key in ["primary", "secondary"] {
            guard let window = rate[key] as? [String: Any], let percent = double(window["used_percent"]) else { continue }
            let minutes = int(window["window_minutes"])
            let label = minutes == 300 ? "5h" : minutes == 10080 ? "7d" : minutes > 0 ? "\(minutes) min" : "quota"
            let reset = double(window["resets_at"]).map { Date(timeIntervalSince1970: $0) }
            output.append(UsageWindow(id: UsageWindow.id(.codex, bucket.prefix + key, account: account), provider: .codex,
                                      label: label, usedPercent: percent, resetsAt: reset, observedAt: observedAt,
                                      evidence: .localLog, minutes: minutes > 0 ? minutes : nil, scope: bucket.scope,
                                      account: account))
        }
        return output
    }

    /// Codex reports the plan's limits under the `codex` bucket and a model's own limits under another, such as
    /// `codex_bengalfox` named "GPT-5.3-Codex-Spark". The plan keeps the older window ids; a model's limits are
    /// named after the model.
    private static func codexBucket(id: String?, name: String?) -> (prefix: String, scope: String?) {
        guard let id, id != "codex" else { return ("", nil) }
        let short = (name ?? id).split(whereSeparator: { $0 == "-" || $0 == " " || $0 == "_" }).last.map(String.init)
        return ("\(id)-", short.map { $0.prefix(1).uppercased() + $0.dropFirst() })
    }

    /// Commands such as /clear, /model, and /effort, and their output, are user entries that start no model turn.
    private static func isLocalCommand(_ object: [String: Any]) -> Bool {
        guard let message = object["message"] as? [String: Any] else { return false }
        let text = (message["content"] as? String)
            ?? (message["content"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }.joined()
        return ["<command-name>", "<command-message>", "<local-command-"].contains { text.hasPrefix($0) }
    }

    /// Claude Code records "[Request interrupted by user]", or "… for tool use" after a declined tool, as a user entry.
    private static func isInterruption(_ object: [String: Any]) -> Bool {
        if object["interruptedMessageId"] is String { return true }
        guard let message = object["message"] as? [String: Any] else { return false }
        let texts = (message["content"] as? String).map { [$0] }
            ?? (message["content"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }
        return texts.contains { $0.hasPrefix("[Request interrupted by user") }
    }

    private static func isPrompt(_ object: [String: Any]) -> Bool {
        guard let message = object["message"] as? [String: Any] else { return false }
        if message["content"] is String { return true }
        let blocks = message["content"] as? [[String: Any]] ?? []
        return blocks.contains { $0["type"] as? String == "text" } && !blocks.contains { $0["type"] as? String == "tool_result" }
    }

    /// The log's first line, then the complete lines of its tail. The tail's first line may be cut, unless the
    /// tail starts at a line break.
    private static func rawLines(head: Data, tail: Data) -> [Data] {
        var lines: [Data] = []
        if let first = head.split(separator: 10).first { lines.append(Data(first)) }
        let tailLines = tail.split(separator: 10)
        let start = tail.first == 10 ? 0 : 1
        if tailLines.count > start {
            for line in tailLines[start...] { lines.append(Data(line)) }
        }
        return lines
    }

    private static func jsonLines(head: Data, tail: Data) -> [[String: Any]] {
        rawLines(head: head, tail: tail).compactMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    }

    private static func isRelevantCodexLine(_ line: Data) -> Bool {
        if codexMarkers.contains(where: { line.range(of: $0) != nil }) { return true }
        return line.range(of: responseMarker) != nil
            && (line.range(of: assistantMarker) != nil || line.range(of: userMarker) != nil)
    }

    private static let fractionalDates: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private static let wholeDates = ISO8601DateFormatter()

    private static func timestamp(_ object: [String: Any]) -> Date? {
        (object["timestamp"] as? String).flatMap(parseDate)
    }

    private static func parseDate(_ string: String) -> Date? {
        fractionalDates.date(from: string) ?? wholeDates.date(from: string)
    }

    private static func int(_ value: Any?) -> Int {
        if let number = value as? NSNumber { return number.intValue }
        return 0
    }

    private static func double(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        return nil
    }
}
