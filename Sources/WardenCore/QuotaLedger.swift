import Foundation

/// Tokens one log line recorded, with the time they were used.
public struct UsageEvent: Codable, Equatable {
    public var at: Date
    public var provider: AgentProvider
    /// The account, such as "work". Nil for the default account.
    public var account: String?
    /// The session the use belongs to. A subagent's use belongs to the session that started it.
    public var session: String
    public var project: String
    public var model: String
    public var usage: TokenUsage

    public init(at: Date, provider: AgentProvider, account: String? = nil, session: String, project: String,
                model: String, usage: TokenUsage) {
        self.at = at
        self.provider = provider
        self.account = account
        self.session = session
        self.project = project
        self.model = model
        self.usage = usage
    }

    // Short keys and a flat usage array: the ledger may hold a few thousand of these while a week's first rise waits.
    private enum CodingKeys: String, CodingKey { case at = "t", provider = "p", account = "a", session = "s", project = "d", model = "m", usage = "u" }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        at = try container.decode(Date.self, forKey: .at)
        provider = try container.decode(AgentProvider.self, forKey: .provider)
        account = try container.decodeIfPresent(String.self, forKey: .account)
        session = try container.decode(String.self, forKey: .session)
        project = try container.decode(String.self, forKey: .project)
        model = try container.decode(String.self, forKey: .model)
        let values = try container.decode([Int].self, forKey: .usage)
        guard values.count == 6 else { throw DecodingError.dataCorruptedError(forKey: .usage, in: container, debugDescription: "usage") }
        usage = TokenUsage(input: values[0], cacheWrite: values[1], cacheWriteHour: values[2], cacheRead: values[3],
                           output: values[4], requests: values[5])
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(at, forKey: .at)
        try container.encode(provider, forKey: .provider)
        try container.encodeIfPresent(account, forKey: .account)
        try container.encode(session, forKey: .session)
        try container.encode(project, forKey: .project)
        try container.encode(model, forKey: .model)
        try container.encode([usage.input, usage.cacheWrite, usage.cacheWriteHour, usage.cacheRead, usage.output, usage.requests],
                             forKey: .usage)
    }

    /// How much of a limit this use likely took compared with other use at the same time: its price at API list
    /// prices, or a stand-in price for a model without one. Only the ratio between uses matters.
    var weight: Double {
        if let price = Pricing.price(for: model) { return price.cost(of: usage) }
        let standIn = provider == .claude ? ModelPrice.claude(5, 25)
            : ModelPrice(input: 1.25, output: 10, cacheWrite: 1.25, cacheWriteHour: 1.25, cacheRead: 0.125)
        return standIn.cost(of: usage)
    }
}

/// Percentage points of a limit charged, for one day, to the use of one project.
public struct QuotaCharge: Codable, Equatable {
    public var day: String
    /// The limit's id, such as "Claude-seven_day". It stays the same from one window to the next.
    public var window: String
    /// Nil for a rise that no local use explains, such as use on the web or on another computer.
    public var project: String?
    public var points: Double

    public init(day: String, window: String, project: String?, points: Double) {
        self.day = day
        self.window = window
        self.project = project
        self.points = points
    }
}

/// One window of a limit, from its start to its reset, as far as Warden saw it.
public struct QuotaPeriod: Codable, Equatable {
    public var window: String
    public var resetsAt: Date?
    /// The highest percentage read in this window.
    public var percent: Double
    /// Points split among local use, by project and by session. Sessions are kept only for the current window.
    public var projects: [String: Double] = [:]
    public var sessions: [String: Double] = [:]
    /// Points of rises that no local use explains.
    public var unexplained = 0.0
    /// API value of the priced use that received points, and those points.
    public var dollars = 0.0
    public var pricedPoints = 0.0

    public init(window: String, resetsAt: Date?, percent: Double) {
        self.window = window
        self.resetsAt = resetsAt
        self.percent = percent
    }

    public var attributed: Double { projects.values.reduce(0, +) }

    /// Dollars of API value per percentage point, once at least two points were split among priced use.
    public var dollarsPerPoint: Double? { pricedPoints >= 2 ? dollars / pricedPoints : nil }
}

/// Splits each observed rise of a limit among the local use that caused it.
///
/// A provider reports a limit as a percentage of the window. Between two readings where it rose, the local logs
/// show which sessions used tokens. The rise is split among them in proportion to the API price of their use,
/// which stands in for how providers meter their plans. A rise without local use, such as use on the web or on
/// another computer, stays unexplained. Readings are never extrapolated: use after the last rise of a window
/// that ended is not charged.
///
/// The ledger keeps percentages, times, project folders, session ids, and model names; no text.
public final class QuotaLedger: @unchecked Sendable {
    private struct Mark: Codable {
        var at: Date
        var percent: Double
        /// A new window starts here, and `percent` is its first known value.
        var starts = false
        var resetsAt: Date?
        /// Another window under the same name, such as another account signed in to the same folder: follow it from
        /// here without charging the difference. Optional, as files from before it must still decode.
        var rebase: Bool?
    }

    private struct Tracker: Codable {
        /// The latest reading.
        var window: UsageWindow
        /// The last rise that was split, from which local use counts toward the next one.
        var baseTime: Date
        var basePercent: Double
        /// Readings that wait for the logs to be read up to their time.
        var marks: [Mark] = []
        var period: QuotaPeriod
        /// A reading far below the latest, kept until a second one confirms the window restarted.
        var dropAt: Date?
        var dropPercent: Double?

        var latestPercent: Double { marks.last?.percent ?? basePercent }
    }

    private struct State: Codable {
        var version = 1
        /// Local use is complete from this time.
        var coverage: Date?
        /// The logs were read up to this time.
        var readThrough: Date?
        var trackers: [String: Tracker] = [:]
        var events: [UsageEvent] = []
        var charges: [QuotaCharge] = []
        var finished: [QuotaPeriod] = []
        /// When the ledger first ran, and, per account without a limit read yet, the time before which its use was
        /// let go. Optional, as files from before they existed must still decode.
        var startedAt: Date?
        var trimmed: [String: Date]?
    }

    /// Readings wait this long past their time for log lines written at the same moment.
    static let margin: TimeInterval = 5
    static let keptEvents: TimeInterval = 8 * 86_400
    static let keptDays = 90
    private static let saveInterval: TimeInterval = 300

    private let file: URL
    private let calendar: Calendar
    private var state = State()
    private var loaded = false
    private var changed = false
    private var savedAt = Date.distantPast

    public init(directory: URL = WardenPaths.support, calendar: Calendar = .current) {
        file = directory.appendingPathComponent("quota-ledger.json")
        self.calendar = calendar
    }

    /// True until local use from before the ledger's first run has been added.
    public var needsBackfill: Bool {
        load()
        return state.coverage == nil
    }

    /// Adds local use read up to `readAt`, then the readings taken since the last update, and splits every rise
    /// whose time the logs now cover. `coverage` is given once: local use is complete from that time.
    @discardableResult
    public func update(events: [UsageEvent], readings: [UsageWindow], readAt: Date, coverage: Date? = nil) -> QuotaSummary {
        load()
        if state.coverage == nil, let coverage {
            state.coverage = max(coverage, readAt.addingTimeInterval(-Self.keptEvents))
            changed = true
        }
        if state.startedAt == nil { state.startedAt = readAt }
        if !events.isEmpty {
            // Lines read again, as after a crash that lost the logs' read positions, are not counted twice.
            var known = Set(state.events.map(Self.key))
            for event in events where known.insert(Self.key(event)).inserted { state.events.append(event) }
            changed = true
        }
        state.readThrough = max(state.readThrough ?? .distantPast, readAt)
        observe(readings, now: readAt)
        split()
        prune(now: readAt)
        if changed, readAt.timeIntervalSince(savedAt) >= Self.saveInterval { flush(now: readAt) }
        return summary
    }

    public var summary: QuotaSummary {
        load()
        return QuotaSummary(charges: state.charges, windows: state.trackers.mapValues(\.window),
                            current: state.trackers.mapValues(\.period), finished: state.finished, coverage: state.coverage)
    }

    /// Uses held for a rise not yet split.
    var heldUses: Int { state.events.count }

    private static func key(_ use: UsageEvent) -> String {
        "\(use.at.timeIntervalSince1970)|\(use.session)|\(use.model)|\(use.usage.total)|\(use.usage.output)|\(use.usage.requests)"
    }

    public func flush(now: Date = Date()) {
        guard changed, let data = try? JSONEncoder().encode(state) else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
        changed = false
        savedAt = now
    }

    // MARK: Readings

    /// Extra usage is money spent beyond the plan, not a share of included capacity.
    public static func isQuota(_ window: UsageWindow) -> Bool {
        !window.id.hasSuffix("extra_usage") && !window.id.hasSuffix("spend_limit")
    }

    private func observe(_ windows: [UsageWindow], now: Date) {
        // Accounts with limits read before: their older use already followed those limits' rises.
        let known = Set(state.trackers.values.map { Self.account(of: $0.window) })
        for window in windows.sorted(by: { $0.observedAt < $1.observedAt })
        where Self.isQuota(window) && window.usedPercent.isFinite && window.observedAt <= now.addingTimeInterval(60) {
            let percent = min(max(window.usedPercent, 0), 100)
            guard var tracker = state.trackers[window.id] else {
                state.trackers[window.id] = start(window, percent: percent, fresh: !known.contains(Self.account(of: window)))
                changed = true
                continue
            }
            guard window.observedAt > tracker.window.observedAt else { continue }
            var reading = window
            // A reading without a reset time, as when no window is open, keeps the one already known.
            if reading.resetsAt == nil { reading.resetsAt = tracker.window.resetsAt }
            let latest = tracker.latestPercent
            switch Self.order(reading, after: tracker.window, latest: latest) {
            case .same:
                // A reset moved within the same window belongs to the window it will end.
                if reading.resetsAt != tracker.window.resetsAt {
                    if let index = tracker.marks.lastIndex(where: \.starts) { tracker.marks[index].resetsAt = reading.resetsAt }
                    else { tracker.period.resetsAt = reading.resetsAt }
                }
                if percent > latest + 1e-6 {
                    tracker.marks.append(Mark(at: reading.observedAt, percent: percent))
                    (tracker.dropAt, tracker.dropPercent) = (nil, nil)
                    changed = true
                } else if percent < latest - 30 {
                    // A lower value is usually an older answer, such as an idle session's status line. A drop that
                    // holds for ten minutes restarts the window, as when a provider resets a limit without a new time.
                    if let at = tracker.dropAt, let low = tracker.dropPercent, reading.observedAt.timeIntervalSince(at) >= 600 {
                        let base = min(low, percent)
                        tracker.marks.append(Mark(at: at, percent: base, starts: true, resetsAt: reading.resetsAt))
                        if percent > base { tracker.marks.append(Mark(at: reading.observedAt, percent: percent)) }
                        (tracker.dropAt, tracker.dropPercent) = (nil, nil)
                        changed = true
                    } else if tracker.dropAt == nil {
                        (tracker.dropAt, tracker.dropPercent) = (reading.observedAt, percent)
                    }
                } else {
                    (tracker.dropAt, tracker.dropPercent) = (nil, nil)
                }
            case .newer:
                let last = tracker.marks.last?.at ?? tracker.baseTime
                if let begins = reading.periodStart {
                    // A new window starts empty, so its first reading can be split among the use since its start.
                    let from = max(begins, last)
                    tracker.marks.append(Mark(at: from, percent: 0, starts: true, resetsAt: reading.resetsAt))
                    if percent > 0 { tracker.marks.append(Mark(at: max(reading.observedAt, from), percent: percent)) }
                } else {
                    tracker.marks.append(Mark(at: max(reading.observedAt, last), percent: percent, starts: true,
                                              resetsAt: reading.resetsAt))
                }
                (tracker.dropAt, tracker.dropPercent) = (nil, nil)
                changed = true
            case .other:
                tracker.marks.append(Mark(at: reading.observedAt, percent: percent, rebase: true))
                (tracker.dropAt, tracker.dropPercent) = (nil, nil)
                changed = true
            case .older:
                continue
            }
            tracker.window = reading
            state.trackers[window.id] = tracker
        }
    }

    /// A first reading counts from the window's start when the logs cover it, and from now otherwise. Use is kept from
    /// the window's start only for an account with no limit read yet, as later it follows each limit's last rise.
    private func start(_ window: UsageWindow, percent: Double, fresh: Bool) -> Tracker {
        let kept = max(state.coverage ?? .distantFuture, state.trimmed?[Self.account(of: window)] ?? .distantPast)
        if fresh, let begins = window.periodStart, begins >= kept, begins < window.observedAt {
            var tracker = Tracker(window: window, baseTime: begins, basePercent: 0,
                                  period: QuotaPeriod(window: window.id, resetsAt: window.resetsAt, percent: 0))
            if percent > 0 { tracker.marks = [Mark(at: window.observedAt, percent: percent)] }
            return tracker
        }
        return Tracker(window: window, baseTime: window.observedAt, basePercent: percent,
                       period: QuotaPeriod(window: window.id, resetsAt: window.resetsAt, percent: percent))
    }

    private static func account(of window: UsageWindow) -> String { "\(window.provider.rawValue)/\(window.account ?? "")" }

    private enum Order { case same, newer, older, other }

    /// Whether a reading belongs to the tracked window, a newer one, one that ended, or another window under the same
    /// name. Reset times from different sources differ by a second or so. A later reset starts a new window once the
    /// old reset has passed, or when the percentage fell in a window that begins now; before that, the provider moved
    /// the reset of the same window. An earlier reset still ahead is a correction of the same window. A moved reset
    /// with a jump in the percentage is another window, as when another account signs in to the same Codex folder;
    /// the logs do not say which account wrote a reading.
    private static func order(_ reading: UsageWindow, after old: UsageWindow, latest: Double) -> Order {
        guard let new = reading.resetsAt, let previous = old.resetsAt else { return .same }
        if abs(new.timeIntervalSince(previous)) < 120 { return .same }
        let jumped = abs(reading.usedPercent - latest) > 5
        if new < previous { return new > reading.observedAt ? (jumped ? .other : .same) : .older }
        if reading.observedAt >= previous.addingTimeInterval(-120) { return .newer }
        if reading.usedPercent < latest - 1 {
            // A window that began well before this reading was not started by a reset now.
            if jumped, let begins = reading.periodStart, reading.observedAt.timeIntervalSince(begins) > 3600 { return .other }
            return .newer
        }
        return jumped ? .other : .same
    }

    // MARK: Splitting

    private func split() {
        guard let through = state.readThrough?.addingTimeInterval(-Self.margin) else { return }
        // Codex meters a model with its own limit, such as Spark, apart from the plan's limit.
        let separate = Set(state.trackers.values.filter { $0.window.provider == .codex }.compactMap { $0.window.scope?.lowercased() })
        for id in state.trackers.keys.sorted() {
            guard var tracker = state.trackers[id], tracker.marks.first.map({ $0.at <= through }) == true else { continue }
            while let mark = tracker.marks.first, mark.at <= through {
                tracker.marks.removeFirst()
                if mark.rebase == true {
                    tracker.baseTime = mark.at
                    tracker.basePercent = mark.percent
                    tracker.period.percent = max(tracker.period.percent, mark.percent)
                    continue
                }
                if mark.starts {
                    finish(&tracker.period)
                    tracker.period = QuotaPeriod(window: id, resetsAt: mark.resetsAt, percent: mark.percent)
                    tracker.baseTime = mark.at
                    tracker.basePercent = mark.percent
                    continue
                }
                let rise = mark.percent - tracker.basePercent
                guard rise > 0 else { continue }
                let window = tracker.window
                let uses = state.events.filter { use in
                    use.at > tracker.baseTime && use.at <= mark.at && use.provider == window.provider
                        && use.account == window.account && Self.counts(use.model, toward: window, separate: separate)
                }
                let weights = uses.map(\.weight)
                let total = weights.reduce(0, +)
                if total > 0 {
                    for (use, weight) in zip(uses, weights) where weight > 0 {
                        let points = rise * weight / total
                        charge(day: UsageLedger.dayString(use.at, calendar: calendar), window: id, project: use.project, points: points)
                        tracker.period.projects[use.project, default: 0] += points
                        tracker.period.sessions[use.session, default: 0] += points
                        if let price = Pricing.price(for: use.model) {
                            tracker.period.dollars += price.cost(of: use.usage)
                            tracker.period.pricedPoints += points
                        }
                    }
                } else {
                    charge(day: UsageLedger.dayString(mark.at, calendar: calendar), window: id, project: nil, points: rise)
                    tracker.period.unexplained += rise
                }
                tracker.period.percent = max(tracker.period.percent, mark.percent)
                tracker.baseTime = mark.at
                tracker.basePercent = mark.percent
            }
            state.trackers[id] = tracker
            changed = true
        }
    }

    /// A limit on one model counts that model's use; a shared limit counts every model, except Codex models with
    /// limits of their own.
    static func counts(_ model: String, toward window: UsageWindow, separate: Set<String>) -> Bool {
        let model = model.lowercased()
        if let scope = window.scope?.lowercased() { return model.contains(scope) }
        return window.provider != .codex || !separate.contains { model.contains($0) }
    }

    private func charge(day: String, window: String, project: String?, points: Double) {
        if let index = state.charges.lastIndex(where: { $0.day == day && $0.window == window && $0.project == project }) {
            state.charges[index].points += points
        } else {
            state.charges.append(QuotaCharge(day: day, window: window, project: project, points: points))
        }
    }

    private func finish(_ period: inout QuotaPeriod) {
        guard period.percent > 0 || period.attributed > 0 else { return }
        period.sessions = [:]
        state.finished.append(period)
    }

    private func prune(now: Date) {
        // Use stays while a limit that counts it may still split it. An account with no limit read yet keeps its use,
        // for at most eight days, until its first reading.
        let floor = now.addingTimeInterval(-Self.keptEvents)
        let trackers = Array(state.trackers.values)
        let separate = Set(trackers.filter { $0.window.provider == .codex }.compactMap { $0.window.scope?.lowercased() })
        // An account still without a reading an hour after the first run, such as one whose limits are never read,
        // keeps six hours of use rather than eight days.
        let settled = now.timeIntervalSince(state.startedAt ?? now) > 3600
        var trimmed = state.trimmed ?? [:]
        let before = state.events.count
        state.events.removeAll { use in
            guard use.at > floor else { return true }
            let limits = trackers.filter { $0.window.provider == use.provider && $0.window.account == use.account }
            guard !limits.isEmpty else {
                guard settled, use.at < now.addingTimeInterval(-6 * 3600) else { return false }
                let account = "\(use.provider.rawValue)/\(use.account ?? "")"
                trimmed[account] = max(trimmed[account] ?? .distantPast, use.at)
                return true
            }
            return !limits.contains { use.at > $0.baseTime && Self.counts(use.model, toward: $0.window, separate: separate) }
        }
        if !trimmed.isEmpty { state.trimmed = trimmed }
        let oldest = UsageLedger.dayString(now.addingTimeInterval(-Double(Self.keptDays) * 86_400), calendar: calendar)
        let charges = state.charges.count
        state.charges.removeAll { $0.day < oldest }
        let periods = state.finished.count
        state.finished.removeAll { ($0.resetsAt ?? now) < now.addingTimeInterval(-Double(Self.keptDays) * 86_400) }
        if state.events.count != before || state.charges.count != charges || state.finished.count != periods { changed = true }
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        if let data = try? Data(contentsOf: file), let stored = try? JSONDecoder().decode(State.self, from: data), stored.version == 1 {
            state = stored
        }
    }
}

public extension UsageWindow {
    /// When the window began: its reset minus its length, when both are known.
    var periodStart: Date? {
        guard let reset = resetsAt, let minutes = durationMinutes else { return nil }
        return reset.addingTimeInterval(-Double(minutes) * 60)
    }
}

/// What the quota ledger found, for the menu and the reports.
public struct QuotaSummary {
    public let charges: [QuotaCharge]
    /// The latest reading of each limit the ledger follows.
    public let windows: [String: UsageWindow]
    /// The current window of each limit.
    public let current: [String: QuotaPeriod]
    public let finished: [QuotaPeriod]
    /// Local use is complete from this time. Nil until the first read.
    public let coverage: Date?

    public init(charges: [QuotaCharge], windows: [String: UsageWindow], current: [String: QuotaPeriod],
                finished: [QuotaPeriod], coverage: Date?) {
        self.charges = charges
        self.windows = windows
        self.current = current
        self.finished = finished
        self.coverage = coverage
    }

    /// Points a session took of each limit's current window, largest first.
    public func points(session: String) -> [(window: UsageWindow, points: Double)] {
        current.compactMap { id, period in
            guard let points = period.sessions[session], points > 0, let window = windows[id] else { return nil }
            return (window, points)
        }
        .sorted { $0.points > $1.points }
    }

    /// Points by project in each limit's current window, with unexplained rises under a nil project.
    public func projects(inCurrent id: String) -> [(project: String?, points: Double)] {
        guard let period = current[id] else { return [] }
        var list: [(project: String?, points: Double)] = period.projects.map { ($0.key, $0.value) }
        if period.unexplained > 0 { list.append((nil, period.unexplained)) }
        return list.sorted { $0.points > $1.points }
    }

    /// Limits with charges in the period, most charged first.
    public func windowIDs(firstDay: String) -> [String] {
        var totals: [String: Double] = [:]
        for charge in charges where charge.day >= firstDay { totals[charge.window, default: 0] += charge.points }
        return totals.filter { $0.value > 0 }.sorted { $0.value > $1.value }.map(\.key)
    }

    /// Points of one limit per project from `firstDay`, largest first, with unexplained rises under a nil project.
    public func projects(window: String, firstDay: String, project: String? = nil) -> [(project: String?, points: Double)] {
        var totals: [String?: Double] = [:]
        for charge in charges where charge.window == window && charge.day >= firstDay && (project == nil || charge.project == project) {
            totals[charge.project, default: 0] += charge.points
        }
        return totals.map { ($0.key, $0.value) }.sorted { $0.points > $1.points }
    }

    /// Points of one limit per day and project.
    public func daily(window: String, days: [String], project: String? = nil) -> [String: [String?: Double]] {
        let wanted = Set(days)
        var result: [String: [String?: Double]] = [:]
        for charge in charges where charge.window == window && wanted.contains(charge.day) && (project == nil || charge.project == project) {
            result[charge.day, default: [:]][charge.project, default: 0] += charge.points
        }
        return result
    }

    /// Dollars of API value per percentage point: in the current window, and the median of finished windows.
    public func exchange(window: String) -> (current: Double?, typical: Double?) {
        let past = finished.filter { $0.window == window }.compactMap(\.dollarsPerPoint).sorted()
        let middle = past.count / 2
        let median = past.isEmpty ? nil : past.count % 2 == 1 ? past[middle] : (past[middle - 1] + past[middle]) / 2
        return (current[window]?.dollarsPerPoint, median)
    }
}
