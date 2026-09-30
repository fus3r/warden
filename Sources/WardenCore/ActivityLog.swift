import Foundation

/// A stretch of time a session spent working, waiting for you, or waiting for a usage limit to reset.
public struct ActivitySpan: Codable, Equatable {
    public enum Kind: String, Codable {
        case working
        /// Waiting for an answer, an approval, or what to do after an error or an interruption.
        case waiting
        /// Stopped by a usage limit, continuing by itself after the reset.
        case limited
    }

    public var session: String
    public var provider: AgentProvider
    public var account: String?
    public var project: String
    public var kind: Kind
    /// What a waiting session needs from you.
    public var attention: AttentionKind?
    /// The tool an approval was for, never its command or file.
    public var tool: String?
    public var start: Date
    public var end: Date
    /// Answered with a click in Warden's menu or a notification.
    public var answeredInWarden = false
    /// Closed because Warden quit, so the span may go on after the relaunch. Optional for spans saved before it.
    public var cut: Bool?

    public var duration: TimeInterval { max(0, end.timeIntervalSince(start)) }

    public init(session: String, provider: AgentProvider, account: String? = nil, project: String, kind: Kind,
                attention: AttentionKind? = nil, tool: String? = nil, start: Date, end: Date) {
        self.session = session
        self.provider = provider
        self.account = account
        self.project = project
        self.kind = kind
        self.attention = attention
        self.tool = tool
        self.start = start
        self.end = end
    }
}

/// Follows the sessions of each scan and turns their states into spans of work and waiting. Only times, states,
/// project folders, session ids, and tool names are kept.
public struct ActivityRecorder {
    public private(set) var open: [String: ActivitySpan] = [:]
    /// Where each session's saved spans end, so a relaunch does not count the same time again.
    private var savedUntil: [String: Date]
    /// A session missing from scans for this long has its span closed where it was last seen.
    static let gone: TimeInterval = 90

    /// `saved` holds spans from before a relaunch; a session's new span starts no earlier than they end.
    public init(saved: [ActivitySpan] = []) {
        savedUntil = saved.reduce(into: [:]) { ends, span in ends[span.session] = max(ends[span.session] ?? .distantPast, span.end) }
    }

    /// Updates the open spans from a scan and returns the spans that ended.
    public mutating func record(_ sessions: [AgentSession], now: Date) -> [ActivitySpan] {
        var closed: [ActivitySpan] = []
        var seen = Set<String>()
        for session in sessions where !session.isSubagent {
            seen.insert(session.id)
            let state = Self.state(of: session)
            // A span begins no earlier than the one before it ended, as a turn resumes after an answer.
            var after = savedUntil[session.id] ?? .distantPast
            if var span = open[session.id] {
                if let state, state.kind == span.kind, state.attention == span.attention {
                    span.end = now
                    if span.tool == nil { span.tool = state.tool }
                    open[session.id] = span
                    continue
                }
                // A turn ends when its log says so, which can be a scan earlier than Warden notices.
                if span.kind == .working, session.updatedAt > span.start, session.updatedAt < now { span.end = session.updatedAt }
                else { span.end = now }
                closed.append(span)
                open[session.id] = nil
                after = span.end
                savedUntil[session.id] = max(savedUntil[session.id] ?? .distantPast, span.end)
            }
            guard let state else { continue }
            open[session.id] = ActivitySpan(session: session.id, provider: session.provider, account: session.account,
                                            project: session.cwd, kind: state.kind, attention: state.attention, tool: state.tool,
                                            start: max(after, Self.start(of: session, state: state, now: now)), end: now)
        }
        for (id, span) in open where !seen.contains(id) && now.timeIntervalSince(span.end) > Self.gone {
            closed.append(span)
            open[id] = nil
            savedUntil[id] = max(savedUntil[id] ?? .distantPast, span.end)
        }
        return closed
    }

    /// Marks the waiting span of a session as answered from Warden.
    public mutating func answeredInWarden(session: String) {
        guard open[session]?.kind == .waiting else { return }
        open[session]?.answeredInWarden = true
    }

    /// Closes every open span, as when Warden quits.
    public mutating func closeAll(now: Date) -> [ActivitySpan] {
        let spans = open.values.map { span -> ActivitySpan in
            var span = span
            span.end = min(span.end, now)
            span.cut = true
            return span
        }
        open = [:]
        return spans
    }

    private static func state(of session: AgentSession) -> (kind: ActivitySpan.Kind, attention: AttentionKind?, tool: String?)? {
        guard !session.ended else { return nil }
        switch session.phase {
        case .working: return session.resumesAt != nil ? (.limited, nil, nil) : (.working, nil, nil)
        case .needsAttention:
            let attention = session.attention ?? .notification
            return (.waiting, attention, attention == .permission ? session.detail.map { String($0.prefix(60)) } : nil)
        default: return nil
        }
    }

    /// A span starts when the log says the state began, if that is recent; otherwise at the scan that saw it.
    private static func start(of session: AgentSession, state: (kind: ActivitySpan.Kind, attention: AttentionKind?, tool: String?),
                              now: Date) -> Date {
        let reported = state.kind == .working ? (session.turnStartedAt ?? session.updatedAt) : session.updatedAt
        return reported <= now && now.timeIntervalSince(reported) < 6 * 3600 ? reported : now
    }
}

/// Spans that ended, kept for 30 days in `activity.json`.
public final class ActivityLog: @unchecked Sendable {
    private let file: URL
    private var spans: [ActivitySpan] = []
    private var loaded = false
    private var changed = false
    private var savedAt = Date.distantPast
    static let keptDays: TimeInterval = 30 * 86_400
    private static let saveInterval: TimeInterval = 300

    public init(directory: URL = WardenPaths.support) {
        file = directory.appendingPathComponent("activity.json")
    }

    public func add(_ closed: [ActivitySpan], now: Date = Date()) {
        load()
        // Spans shorter than a scan tell nothing and would crowd the file.
        let kept = closed.filter { $0.duration >= 5 }
        guard !kept.isEmpty else { return }
        spans += kept
        spans.removeAll { $0.end < now.addingTimeInterval(-Self.keptDays) }
        changed = true
        if now.timeIntervalSince(savedAt) >= Self.saveInterval { flush(now: now) }
    }

    public var all: [ActivitySpan] {
        load()
        return spans
    }

    public func flush(now: Date = Date()) {
        guard changed else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        guard let data = try? encoder.encode(spans) else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
        changed = false
        savedAt = now
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        if let data = try? Data(contentsOf: file), let stored = try? decoder.decode([ActivitySpan].self, from: data) {
            spans = stored
        }
    }
}

/// What a day of agent work looked like: how long agents worked, and how long they waited for you.
public struct ActivitySummary: Equatable {
    public var working: TimeInterval = 0
    public var waiting: TimeInterval = 0
    public var limited: TimeInterval = 0
    /// Time with at least one agent working.
    public var busy: TimeInterval = 0
    /// Times an agent needed you, and how long you took to answer.
    public var waits = 0
    public var medianWait: TimeInterval?
    public var longestWait: TimeInterval?
    public var answeredInWarden = 0
    public var waitingByKind: [AttentionKind: TimeInterval] = [:]
    public var waitingByProject: [String: TimeInterval] = [:]

    /// The share of agent time spent working rather than waiting for you.
    public var autonomy: Double? { working + waiting > 0 ? working / (working + waiting) : nil }

    /// Spans clipped to an interval, such as a day.
    public init(_ spans: [ActivitySpan], from start: Date, to end: Date) {
        var waits: [TimeInterval] = []
        var busyIntervals: [(Date, Date)] = []
        for span in Self.joined(spans) {
            let from = max(span.start, start), to = min(span.end, end)
            guard to > from else { continue }
            let length = to.timeIntervalSince(from)
            switch span.kind {
            case .working:
                working += length
                busyIntervals.append((from, to))
            case .limited:
                limited += length
            case .waiting:
                waiting += length
                waitingByKind[span.attention ?? .notification, default: 0] += length
                waitingByProject[span.project, default: 0] += length
                // A wait counts on the day it began.
                if span.start >= start {
                    waits.append(span.duration)
                    if span.answeredInWarden { answeredInWarden += 1 }
                }
            }
        }
        self.waits = waits.count
        let sorted = waits.sorted()
        medianWait = sorted.isEmpty ? nil : sorted.count % 2 == 1 ? sorted[sorted.count / 2]
            : (sorted[sorted.count / 2 - 1] + sorted[sorted.count / 2]) / 2
        longestWait = sorted.last
        var cursor = Date.distantPast
        for (from, to) in busyIntervals.sorted(by: { $0.0 < $1.0 }) {
            let begin = max(from, cursor)
            if to > begin { busy += to.timeIntervalSince(begin) }
            cursor = max(cursor, to)
        }
    }

    /// A wait or turn that a relaunch cut in two counts once.
    static func joined(_ spans: [ActivitySpan]) -> [ActivitySpan] {
        var result: [ActivitySpan] = []
        for span in spans.sorted(by: { ($0.session, $0.start) < ($1.session, $1.start) }) {
            if var last = result.last, last.cut == true, last.session == span.session, last.kind == span.kind,
               last.attention == span.attention, span.start.timeIntervalSince(last.end) <= 600, span.start >= last.start {
                last.end = max(last.end, span.end)
                last.answeredInWarden = last.answeredInWarden || span.answeredInWarden
                last.cut = span.cut
                result[result.count - 1] = last
            } else {
                result.append(span)
            }
        }
        return result
    }
}
