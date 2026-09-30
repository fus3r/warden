import Foundation

/// Follows when you step away from the Mac and come back, from the time since your last keyboard or mouse input and
/// whether the screen is locked. Nothing is recorded; only the start of the current absence is kept in memory.
public struct PresenceTracker {
    /// When the current absence began: your last input before it. Nil while you are here.
    public private(set) var awaySince: Date?
    /// No input for this long, or a locked screen, starts an absence.
    public static let idleAfter: TimeInterval = 120

    public init() {}

    /// Returns the absence that just ended when you come back, however long it lasted.
    public mutating func update(idle: TimeInterval, locked: Bool, now: Date) -> DateInterval? {
        let lastInput = now.addingTimeInterval(-max(0, idle))
        if locked || idle >= Self.idleAfter {
            if awaySince == nil { awaySince = lastInput }
            return nil
        }
        guard let start = awaySince else { return nil }
        awaySince = nil
        return lastInput > start ? DateInterval(start: start, end: lastInput) : nil
    }
}

/// What happened while you were away: sessions that finished or started waiting for you, how long agents worked and
/// waited, and how the limits moved. Built from the states and readings Warden already keeps.
public struct AwayDigest: Equatable {
    public var away: DateInterval
    public var lines: [String]
    /// The session that has waited longest for you, to open from the summary.
    public var firstWaiting: String?
    /// "2 finished · 1 needs you", for a short menu line.
    public var headline: String

    public var isEmpty: Bool { lines.isEmpty }

    /// `before` holds the limit readings from when the absence began, `windows` the current ones. `spans` are the
    /// activity spans, ended and open.
    public init(away: DateInterval, sessions: [AgentSession], spans: [ActivitySpan], before: [UsageWindow],
                windows: [UsageWindow], now: Date = Date()) {
        self.away = away
        var lines: [String] = []
        var headline: [String] = []
        func name(_ session: AgentSession) -> String {
            session.title.map { "“\(String($0.prefix(40)))” (\(session.project))" } ?? session.project
        }
        func names(_ list: [AgentSession]) -> String {
            let shown = list.prefix(2).map(name)
            return ListFormatter.localizedString(byJoining: shown + (list.count > 2 ? ["\(list.count - 2) more"] : []))
        }
        let visible = sessions.filter { !$0.isSubagent }
        let waiting = visible.filter { $0.phase == .needsAttention }.sorted { $0.updatedAt < $1.updatedAt }
        let finished = visible.filter { $0.phase == .finished && away.contains($0.updatedAt) }.sorted { $0.updatedAt < $1.updatedAt }
        if !finished.isEmpty {
            lines.append("\(finished.count == 1 ? "1 session" : "\(finished.count) sessions") finished: \(names(finished)).")
            headline.append("\(finished.count) finished")
        }
        if !waiting.isEmpty {
            let oldest = waiting[0]
            let since = oldest.updatedAt < away.start ? "since before you left" : "since \(Self.time(oldest.updatedAt))"
            lines.append("\(waiting.count == 1 ? "1 session waits" : "\(waiting.count) sessions wait") for you: \(names(waiting)), the first \(since).")
            headline.append("\(waiting.count) \(waiting.count == 1 ? "needs" : "need") you")
        }
        let activity = ActivitySummary(spans, from: away.start, to: away.end)
        if activity.working >= 60 {
            var line = "Agents worked \(Self.duration(activity.working))"
            if activity.waiting >= 60 { line += " and waited \(Self.duration(activity.waiting)) for you" }
            lines.append(line + ".")
        }
        let previous = Dictionary(before.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for window in windows.sorted(by: { $0.id < $1.id }) where !window.id.hasSuffix("extra_usage") {
            guard let old = previous[window.id] else { continue }
            if let oldReset = old.resetsAt, oldReset > away.start, oldReset <= now {
                // Only a reading of the new window tells how much of it is used.
                let renewed = (window.resetsAt ?? oldReset) > oldReset.addingTimeInterval(60)
                lines.append("\(window.name) reset at \(Self.time(oldReset))" + (renewed ? "; \(Int(window.usedPercent.rounded()))% used since." : "."))
                if old.usedPercent >= 90 { headline.append("\(window.name) reset") }
                continue
            }
            guard window.observedAt > away.start else { continue }
            let reset = window.resetsAt.map { $0 > now ? " It resets \(Self.phrase($0, now: now))." : "" } ?? ""
            if window.usedPercent >= 100, old.usedPercent < 100 {
                lines.append("\(window.name) reached its limit.\(reset)")
                headline.append("\(window.name) full")
            } else if window.usedPercent - old.usedPercent >= 5 {
                lines.append("\(window.name) rose \(Int((window.usedPercent - old.usedPercent).rounded())) points to \(Int(window.usedPercent.rounded()))%.\(reset)")
            }
        }
        self.lines = lines
        self.headline = headline.joined(separator: " · ")
        firstWaiting = waiting.first?.id
    }

    /// "1 h 05", "47 min".
    public static func duration(_ seconds: TimeInterval) -> String {
        if seconds < 3600 { return "\(max(1, Int(seconds / 60))) min" }
        return String(format: "%d h %02d", Int(seconds / 3600), Int(seconds.truncatingRemainder(dividingBy: 3600) / 60))
    }

    private static func time(_ date: Date) -> String { date.formatted(date: .omitted, time: .shortened) }

    private static func phrase(_ date: Date, now: Date) -> String {
        date.timeIntervalSince(now) < 86_400 ? "at \(time(date))" : "\(date.formatted(.dateTime.weekday(.wide))) at \(time(date))"
    }
}
