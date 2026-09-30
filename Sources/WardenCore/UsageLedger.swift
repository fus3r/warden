import Foundation

/// Tokens an agent used, from its own session logs.
public struct TokenUsage: Codable, Equatable {
    /// Input read without the prompt cache.
    public var input = 0
    /// Input written to the prompt cache for five minutes, and for an hour. Claude prices them differently.
    public var cacheWrite = 0
    public var cacheWriteHour = 0
    public var cacheRead = 0
    /// Output, including reasoning.
    public var output = 0
    /// Model requests.
    public var requests = 0

    public init(input: Int = 0, cacheWrite: Int = 0, cacheWriteHour: Int = 0, cacheRead: Int = 0,
                output: Int = 0, requests: Int = 0) {
        self.input = input
        self.cacheWrite = cacheWrite
        self.cacheWriteHour = cacheWriteHour
        self.cacheRead = cacheRead
        self.output = output
        self.requests = requests
    }

    public var total: Int { input + cacheWrite + cacheWriteHour + cacheRead + output }

    public static func + (left: TokenUsage, right: TokenUsage) -> TokenUsage {
        TokenUsage(input: left.input + right.input, cacheWrite: left.cacheWrite + right.cacheWrite,
                   cacheWriteHour: left.cacheWriteHour + right.cacheWriteHour, cacheRead: left.cacheRead + right.cacheRead,
                   output: left.output + right.output, requests: left.requests + right.requests)
    }

    public static func - (left: TokenUsage, right: TokenUsage) -> TokenUsage {
        TokenUsage(input: left.input - right.input, cacheWrite: left.cacheWrite - right.cacheWrite,
                   cacheWriteHour: left.cacheWriteHour - right.cacheWriteHour, cacheRead: left.cacheRead - right.cacheRead,
                   output: left.output - right.output, requests: left.requests - right.requests)
    }
}

/// Usage for one day, agent, model, and project folder.
public struct UsageRecord: Codable, Equatable {
    /// Local calendar day, "2026-09-24".
    public var day: String
    public var provider: AgentProvider
    public var model: String
    public var project: String
    public var usage: TokenUsage
    /// The account, such as "work". Nil for the default account.
    public var account: String?

    public init(day: String, provider: AgentProvider, model: String, project: String, usage: TokenUsage, account: String? = nil) {
        self.day = day
        self.provider = provider
        self.model = model
        self.project = project
        self.usage = usage
        self.account = account
    }
}

/// How far one session log has been read, and the usage found so far. Logs only grow, so each read starts
/// where the last one stopped and no line is read twice.
public struct LedgerCursor: Codable, Equatable {
    public var offset: UInt64 = 0
    public var records: [UsageRecord] = []
    /// The session the log belongs to. A Claude subagent's log belongs to the session that started it.
    public var session: String?
    /// The account whose folder holds the log. Nil for the default account.
    public var account: String?
    var cwd: String?
    var model: String?
    /// Claude writes a reply once per content block, each entry repeating the reply's usage, and the last entry
    /// has the final output count. The latest reply is kept so that its later entries replace its usage.
    var lastReply: String?
    var lastReplyUsage: TokenUsage?
    var lastReplyRecord: Int?
    /// Codex logs every model response since mid-2026. Older logs only have running totals.
    var usesResponseRecords = false
    var lastTotal: TokenUsage?
    /// The session a Codex subagent or review works for, whose use it counts toward.
    var parent: String?
    /// The Codex thread the log belongs to, from its first metadata line. A fork's copied history names another.
    var thread: String?
    /// An older Codex fork repeats its parent's running totals before its own first turn. Optional, as saved cursors
    /// from before it must still decode.
    var awaitsOwnTurn: Bool?
    /// When an older fork began: the lines it copied from its parent carry this time, its own turns a later one.
    var forkedAt: Date?

    public init(session: String? = nil, account: String? = nil) {
        self.session = session
        self.account = account
    }

    /// Continue an archived log without recounting its earlier replies or cumulative Codex total.
    var continuation: LedgerCursor {
        var next = self
        next.records = []
        next.lastReplyRecord = nil
        return next
    }

    /// Adds usage to the record for its day, model, and project, and returns that record's position.
    mutating func add(_ usage: TokenUsage, provider: AgentProvider, day: String, model: String) -> Int {
        let project = cwd ?? ""
        if let position = records.firstIndex(where: { $0.day == day && $0.model == model && $0.project == project && $0.account == account }) {
            records[position].usage = records[position].usage + usage
            return position
        }
        records.append(UsageRecord(day: day, provider: provider, model: model, project: project, usage: usage, account: account))
        return records.count - 1
    }
}

/// Reads token use from new lines of Claude Code transcripts and Codex session logs.
/// Only complete lines count; the cursor stops before a line that is still being written.
public enum UsageLedger {
    /// Entries name their kind near the start of the line: Claude in the reply's opening fields, Codex in the
    /// entry and payload types. Searching only there keeps the first read of large logs fast.
    private static let claudeMarkers = [#""role":"assistant""#]
    private static let codexMarkers = [#""type":"token_usage_record""#, #""type":"token_count""#,
                                       #""type":"turn_context""#, #""type":"session_meta""#, #""type":"task_started""#,
                                       #""type":"turn_started""#]

    /// `data` holds the file's bytes from `cursor.offset`. Returns true when usage changed. `events` receives each
    /// use with its time, as quota changes are split among the uses that caused them. `claim` is asked once per
    /// Claude reply and returns false when another log already counted it.
    @discardableResult
    public static func read(_ data: Data, provider: AgentProvider, cursor: inout LedgerCursor,
                            calendar: Calendar = .current, events: ((UsageEvent) -> Void)? = nil,
                            claim: ((String) -> Bool)? = nil) -> Bool {
        let markers = provider == .claude ? claudeMarkers : codexMarkers
        let window = provider == .claude ? 1024 : 256
        // Byte ranges of the complete lines that name a kind of entry holding usage, found with memchr and memmem.
        var lines: [Range<Int>] = []
        let consumed: Int = data.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress, buffer.count > 0 else { return 0 }
            var start = 0
            while start < buffer.count, let found = memchr(base + start, 10, buffer.count - start) {
                let end = base.distance(to: UnsafeRawPointer(found))
                let head = min(end - start, window)
                if markers.contains(where: { marker in
                    marker.withCString { memmem(base + start, head, $0, strlen($0)) != nil }
                }) {
                    lines.append(start..<end)
                }
                start = end + 1
            }
            return start
        }
        var changed = false
        for range in lines {
            let line = data[(data.startIndex + range.lowerBound)..<(data.startIndex + range.upperBound)]
            guard let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { continue }
            let found = provider == .claude ? claudeEntry(object, cursor: &cursor, calendar: calendar, events: events, claim: claim)
                : codexEntry(object, cursor: &cursor, calendar: calendar, events: events)
            changed = changed || found
        }
        cursor.offset += UInt64(consumed)
        return changed
    }

    private static func emit(_ usage: TokenUsage, at date: Date, provider: AgentProvider, model: String,
                             cursor: LedgerCursor, to events: ((UsageEvent) -> Void)?) {
        guard let events, usage.total > 0 else { return }
        events(UsageEvent(at: date, provider: provider, account: cursor.account,
                          session: cursor.parent ?? cursor.session ?? "", project: cursor.cwd ?? "", model: model, usage: usage))
    }

    private static func claudeEntry(_ object: [String: Any], cursor: inout LedgerCursor, calendar: Calendar,
                                    events: ((UsageEvent) -> Void)?, claim: ((String) -> Bool)?) -> Bool {
        if let cwd = object["cwd"] as? String, !cwd.isEmpty { cursor.cwd = cwd }
        guard object["type"] as? String == "assistant", object["isApiErrorMessage"] as? Bool != true,
              let message = object["message"] as? [String: Any],
              let id = message["id"] as? String, let model = message["model"] as? String, model != "<synthetic>",
              let usage = message["usage"] as? [String: Any],
              let date = (object["timestamp"] as? String).flatMap(date) else { return false }
        let day = dayString(date, calendar: calendar)
        let hour = int((usage["cache_creation"] as? [String: Any])?["ephemeral_1h_input_tokens"])
        let tokens = TokenUsage(input: int(usage["input_tokens"]),
                                cacheWrite: max(0, int(usage["cache_creation_input_tokens"]) - hour), cacheWriteHour: hour,
                                cacheRead: int(usage["cache_read_input_tokens"]), output: int(usage["output_tokens"]), requests: 1)
        let reply = id + ":" + (object["requestId"] as? String ?? "")
        var added = tokens
        if reply == cursor.lastReply, let previous = cursor.lastReplyUsage {
            // The entry with the most tokens counts, as the output grows while a reply streams. Only the growth belongs
            // to this reading, including when the earlier entry was archived.
            guard tokens.total > previous.total else { return false }
            added = tokens - previous
        } else if let claim, !claim(reply) {
            // A branched or forked session copies earlier replies into its own log; the log that counted one keeps it.
            return false
        }
        cursor.lastReply = reply
        cursor.lastReplyUsage = tokens
        cursor.lastReplyRecord = cursor.add(added, provider: .claude, day: day, model: model)
        emit(added, at: date, provider: .claude, model: model, cursor: cursor, to: events)
        return true
    }

    private static func codexEntry(_ object: [String: Any], cursor: inout LedgerCursor, calendar: Calendar,
                                   events: ((UsageEvent) -> Void)?) -> Bool {
        let payload = object["payload"] as? [String: Any] ?? [:]
        let date = (object["timestamp"] as? String).flatMap(Self.date)
        let day = date.map { dayString($0, calendar: calendar) }
        switch object["type"] as? String {
        case "session_meta", "turn_context":
            if let cwd = payload["cwd"] as? String, !cwd.isEmpty { cursor.cwd = cwd }
            if let model = payload["model"] as? String, !model.isEmpty { cursor.model = model }
            // A fork's copied history repeats its parent's metadata, so the log's own identity is its first.
            if object["type"] as? String == "session_meta", cursor.thread == nil, let id = payload["id"] as? String {
                cursor.thread = id
                cursor.awaitsOwnTurn = payload["forked_from_id"] is String ? true : nil
                cursor.forkedAt = cursor.awaitsOwnTurn == true ? date : nil
            }
            // Spawned threads and reviews name the session they work for.
            let spawn = ((payload["source"] as? [String: Any])?["subagent"] as? [String: Any])?["thread_spawn"] as? [String: Any]
            if let parent = (payload["parent_thread_id"] as? String) ?? (spawn?["parent_thread_id"] as? String), !parent.isEmpty {
                cursor.parent = parent
            }
        case "event_msg" where ["task_started", "turn_started"].contains(payload["type"] as? String ?? ""):
            // A copied turn start carries the fork's own start time; the fork's first turn begins after it.
            if let forked = cursor.forkedAt, let date, date <= forked { break }
            cursor.awaitsOwnTurn = nil
        case "token_usage_record":
            guard let usage = payload["usage"] as? [String: Any], let day, let date else { return false }
            // A fork may copy its parent's records; those belong to the parent's log.
            if let thread = payload["thread_id"] as? String, let own = cursor.thread, thread != own { return false }
            cursor.usesResponseRecords = true
            let tokens = codexTokens(usage, requests: 1)
            _ = cursor.add(tokens, provider: .codex, day: day, model: cursor.model ?? "unknown")
            emit(tokens, at: date, provider: .codex, model: cursor.model ?? "unknown", cursor: cursor, to: events)
            return true
        case "event_msg" where payload["type"] as? String == "token_count" && !cursor.usesResponseRecords:
            // Before response records, the growth of the running total is the usage.
            guard let info = payload["info"] as? [String: Any], let total = info["total_token_usage"] as? [String: Any],
                  let day, let date else { return false }
            let now = codexTokens(total, requests: 0)
            let before = cursor.lastTotal ?? TokenUsage()
            cursor.lastTotal = now
            // An older fork repeats its parent's totals before its own first turn; its use is the growth after them.
            guard cursor.awaitsOwnTurn != true else { return false }
            var delta = now.total >= before.total ? now - before : now
            guard delta.total > 0 else { return false }
            delta.requests = 1
            _ = cursor.add(delta, provider: .codex, day: day, model: cursor.model ?? "unknown")
            emit(delta, at: date, provider: .codex, model: cursor.model ?? "unknown", cursor: cursor, to: events)
            return true
        default:
            break
        }
        return false
    }

    /// Codex counts cached input inside `input_tokens` and reasoning inside `output_tokens`.
    private static func codexTokens(_ usage: [String: Any], requests: Int) -> TokenUsage {
        let cached = int(usage["cached_input_tokens"])
        let written = int(usage["cache_write_input_tokens"])
        return TokenUsage(input: max(0, int(usage["input_tokens"]) - cached - written), cacheWrite: written,
                          cacheRead: cached, output: int(usage["output_tokens"]), requests: requests)
    }

    private static let fractionalDates: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private static let wholeDates = ISO8601DateFormatter()

    static func date(_ timestamp: String) -> Date? {
        fractionalDates.date(from: timestamp) ?? wholeDates.date(from: timestamp)
    }

    public static func dayString(_ date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    private static func int(_ value: Any?) -> Int {
        (value as? NSNumber)?.intValue ?? 0
    }
}
