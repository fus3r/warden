import Foundation

/// An observed change in a provider's quota, independent of token prices or subscription fees.
public struct UsagePace: Equatable {
    public let pointsPerHour: Double
    public let sampledMinutes: Int
    public let sampleCount: Int
}

/// A small in-memory sample of existing quota readings. It makes no requests of its own and stores no text.
public struct UsagePaceTracker {
    private var readings: [String: [UsageWindow]] = [:]

    public init() {}

    public mutating func record(_ windows: [UsageWindow], now: Date = Date()) {
        let ids = Set(windows.map(\.id))
        readings = readings.filter { ids.contains($0.key) }
        for window in windows {
            var samples = (readings[window.id] ?? []).filter { now.timeIntervalSince($0.observedAt) <= 3600 }
            guard window.isCurrent(now: now) else { readings[window.id] = []; continue }
            if let last = samples.last {
                guard window.observedAt > last.observedAt else { readings[window.id] = samples; continue }
                // A reset, a real drop, or a sleep-sized gap starts a new observation period. Sessions running side by
                // side report a point or two apart moments apart; such a dip is skipped rather than restarting.
                if !UsageWindow.sameReset(window.resetsAt, last.resetsAt) || window.usedPercent < last.usedPercent - 3
                    || window.observedAt.timeIntervalSince(last.observedAt) > 1200 {
                    samples = []
                } else if window.usedPercent < last.usedPercent || window.observedAt.timeIntervalSince(last.observedAt) < 60 {
                    readings[window.id] = samples
                    continue
                }
            }
            samples.append(window)
            readings[window.id] = samples
        }
    }

    /// The same bounded sample used for the estimate, available for inspection in the planner.
    public func observations(for window: UsageWindow, now: Date = Date()) -> [UsageWindow] {
        (readings[window.id] ?? []).filter {
            UsageWindow.sameReset($0.resetsAt, window.resetsAt) && $0.observedAt <= window.observedAt
                && now.timeIntervalSince($0.observedAt) <= 3600
        }
    }

    public func pace(for window: UsageWindow, now: Date = Date()) -> UsagePace? {
        let samples = observations(for: window, now: now)
        guard window.isCurrent(now: now), samples.count >= 3,
              let first = samples.first, let last = samples.last, UsageWindow.sameReset(last.resetsAt, window.resetsAt),
              now.timeIntervalSince(last.observedAt) < 1200, window.usedPercent >= last.usedPercent - 3 else { return nil }
        let seconds = last.observedAt.timeIntervalSince(first.observedAt)
        let change = last.usedPercent - first.usedPercent
        // Rounded percentages and a quiet account do not support a useful duration estimate.
        guard seconds >= 600, change >= 1 else { return nil }
        return UsagePace(pointsPerHour: change * 3600 / seconds,
                         sampledMinutes: Int(seconds / 60), sampleCount: samples.count)
    }
}

/// The shared limits for one account, plus a model's own limits when a scope is selected.
public struct WorkRoute: Identifiable {
    public let provider: AgentProvider
    public let account: String?
    public let scope: String?
    public let windows: [UsageWindow]

    public var id: String { "\(provider.rawValue)/\(account ?? "")/\(scope ?? "")" }
    public var title: String {
        provider.rawValue + (account.map { " (\($0))" } ?? "") + (scope.map { " · \($0)" } ?? " · shared limits")
    }

    public static func all(in windows: [UsageWindow]) -> [WorkRoute] {
        // Extra usage is an optional paid allowance, not a window of included subscription capacity.
        let windows = windows.filter { !$0.id.hasSuffix("extra_usage") && !$0.id.hasSuffix("spend_limit") }
        var routes: [String: WorkRoute] = [:]
        for window in windows {
            let matching = windows.filter {
                $0.provider == window.provider && $0.account == window.account
                    && ($0.scope == nil || $0.scope == window.scope)
            }
            let route = WorkRoute(provider: window.provider, account: window.account, scope: window.scope, windows: matching)
            routes[route.id] = route
        }
        return routes.values.sorted { $0.id < $1.id }
    }
}

public struct WorkPlan {
    public enum Status: Equatable {
        case limitReached
        case reserveReached
        case needsRefresh
        case atRisk(Date)
        case reserveAtRisk(Date)
        case resetDuringSession(Date)
        case learning
        case withinObservedPace
    }

    public struct Check: Identifiable {
        public let window: UsageWindow
        public let pace: UsagePace?
        public let observations: [UsageWindow]
        public let exhaustsAt: Date?
        public let reachesReserveAt: Date?
        /// Unavailable if the requested session extends into a new quota window.
        public let projectedUsedPercent: Double?
        public var id: String { window.id }
    }

    public let checks: [Check]
    public let status: Status
    /// The limit responsible for a block or the earliest projected interruption.
    public let limitingWindow: UsageWindow?

    public init(route: WorkRoute, tracker: UsagePaceTracker, minutes: Int, now: Date = Date(),
                paceMultiplier: Double = 1, reservePercent: Double = 0) {
        let end = now.addingTimeInterval(Double(minutes) * 60)
        let ceiling = 100 - reservePercent
        checks = route.windows.map { window in
            let pace = tracker.pace(for: window, now: now)
            let rate = pace.map { $0.pointsPerHour * paceMultiplier }
            // The scenario starts now. Only the observed pace can fill the gap since the last reading.
            let estimatedNow = pace.map { window.usedPercent + max(0, now.timeIntervalSince(window.observedAt)) / 3600 * $0.pointsPerHour }
            let exhausts = rate.map { now.addingTimeInterval(max(0, 100 - estimatedNow!) / $0 * 3600) }
            let reserve = rate.map { now.addingTimeInterval(max(0, ceiling - estimatedNow!) / $0 * 3600) }
            let projection = window.resetsAt.map { end < $0 } == true
                ? rate.map { estimatedNow! + Double(minutes) / 60 * $0 } : nil
            return Check(window: window, pace: pace, observations: tracker.observations(for: window, now: now), exhaustsAt: exhausts,
                         reachesReserveAt: reserve, projectedUsedPercent: projection)
        }
        if let full = checks.first(where: { $0.window.isCurrent(now: now) && $0.window.usedPercent >= 100 }) {
            status = .limitReached
            limitingWindow = full.window
        } else if let old = checks.first(where: { !$0.window.isCurrent(now: now) }) {
            status = .needsRefresh
            limitingWindow = old.window
        } else if reservePercent > 0, let reserved = checks.first(where: { $0.window.usedPercent >= ceiling }) {
            status = .reserveReached
            limitingWindow = reserved.window
        } else if let risk = checks.filter({ check in
            guard let exhausts = check.reachesReserveAt, let reset = check.window.resetsAt else { return false }
            return exhausts <= end && exhausts < reset
        }).min(by: { $0.reachesReserveAt! < $1.reachesReserveAt! }) {
            status = reservePercent > 0 ? .reserveAtRisk(risk.reachesReserveAt!) : .atRisk(risk.exhaustsAt!)
            limitingWindow = risk.window
        } else if let reset = checks.compactMap(\.window.resetsAt).filter({ $0 <= end }).min() {
            // Never extrapolate into a new window before the provider confirms its capacity.
            status = .resetDuringSession(reset)
            limitingWindow = nil
        } else if checks.isEmpty || checks.contains(where: { $0.pace == nil || $0.window.resetsAt == nil }) {
            status = .learning
            limitingWindow = nil
        } else {
            status = .withinObservedPace
            limitingWindow = nil
        }
    }
}
