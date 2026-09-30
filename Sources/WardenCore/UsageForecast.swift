import Foundation

public struct UsageForecast: Equatable {
    /// Share of the window already elapsed now, from 0 to 1.
    public var elapsedFraction: Double
    /// Usage at reset if the average pace since the window opened continues. Nil while too early to tell.
    public var projectedPercent: Double?
    /// When the window runs out at that pace, only if this happens before the reset.
    public var exhaustsAt: Date?
}

public extension UsageWindow {
    /// How long a window stays after its reported reset without a newer reading. The menu shows it as reset and
    /// awaiting a reading, and the reading that follows can confirm recovered quota against it.
    static let keptAfterReset: TimeInterval = 6 * 3600

    /// The latest reading of each window, whatever order readings arrive in. A reading from a newer window wins, and
    /// one from a window that ended, such as an idle session's status line written after a reset, never replaces it.
    /// A reset moved earlier but still ahead is a correction. A window without a reset time is kept for eight days
    /// after its last reading.
    static func latest(_ stored: [String: UsageWindow], adding fresh: [UsageWindow], now: Date = Date()) -> [String: UsageWindow] {
        var latest = stored
        for window in fresh {
            guard let old = latest[window.id] else { latest[window.id] = window; continue }
            if let reset = window.resetsAt, let oldReset = old.resetsAt {
                if reset > oldReset.addingTimeInterval(60) { latest[window.id] = window; continue }
                if reset < oldReset.addingTimeInterval(-60), reset <= window.observedAt { continue }
            }
            if window.observedAt > old.observedAt { latest[window.id] = window }
        }
        return latest.filter { _, window in
            if let reset = window.resetsAt { return now.timeIntervalSince(reset) < keptAfterReset }
            return now.timeIntervalSince(window.observedAt) < 8 * 86_400
        }
    }

    /// Whether two readings name the same reset. Sources, and one source over time, differ by a second or so.
    static func sameReset(_ first: Date?, _ second: Date?) -> Bool {
        switch (first, second) {
        case (nil, nil): return true
        case let (first?, second?): return abs(first.timeIntervalSince(second)) < 120
        default: return false
        }
    }

    /// A reset time for keys that must stay the same across the readings of one window: the ten minutes around it.
    static func resetKey(_ date: Date?) -> Int {
        date.map { Int((($0.timeIntervalSince1970 + 300) / 600).rounded(.down)) } ?? 0
    }

    /// The provider's reported reset has passed, so the window's percentage describes a window that ended.
    func hasReset(now: Date = Date()) -> Bool {
        resetsAt.map { $0 <= now } ?? false
    }

    /// Recovery needs a fresh reading after the old reset, with a renewed window and room to work.
    /// A timer reaching zero, a missing provider, or a moved reset date is not evidence of recovered quota.
    func confirmsRecovery(from old: UsageWindow, now: Date = Date()) -> Bool {
        guard id == old.id, provider == old.provider, account == old.account,
              old.usedPercent >= 90, usedPercent < 90, isCurrent(now: now),
              observedAt > old.observedAt, let oldReset = old.resetsAt,
              oldReset <= now, observedAt >= oldReset,
              let reset = resetsAt, reset > oldReset else { return false }
        return true
    }

    /// A reported reset needs a new observation before its old percentage can guide work again.
    func isCurrent(now: Date = Date()) -> Bool {
        usedPercent.isFinite && usedPercent >= 0 && observedAt <= now.addingTimeInterval(60)
            && now.timeIntervalSince(observedAt) < 1800 && (resetsAt.map { $0 > now } ?? true)
    }

    /// Linear projection from the observed value. This is an estimate, not a provider forecast.
    func forecast(now: Date = Date()) -> UsageForecast? {
        guard isCurrent(now: now), let minutes = durationMinutes, let reset = resetsAt else { return nil }
        let duration = Double(minutes) * 60
        let start = reset.addingTimeInterval(-duration)
        let elapsedNow = min(1, max(0, now.timeIntervalSince(start) / duration))
        let elapsedAtObservation = observedAt.timeIntervalSince(start)
        guard elapsedAtObservation >= duration * 0.1, usedPercent >= 5 else {
            return UsageForecast(elapsedFraction: elapsedNow, projectedPercent: nil, exhaustsAt: nil)
        }
        let rate = usedPercent / elapsedAtObservation
        let projected = rate * duration
        let exhausts = usedPercent < 100 && projected > 100
            ? observedAt.addingTimeInterval((100 - usedPercent) / rate) : nil
        return UsageForecast(elapsedFraction: elapsedNow, projectedPercent: projected, exhaustsAt: exhausts)
    }
}

public enum UsageAlert: Equatable {
    case exhausted(UsageWindow)
    case runsOut(UsageWindow, at: Date)
    case nearlyUsed(UsageWindow)

    public var window: UsageWindow {
        switch self {
        case .exhausted(let window), .runsOut(let window, _), .nearlyUsed(let window): return window
        }
    }

    /// The single most pressing usage condition, if any.
    public static func mostUrgent(in windows: [UsageWindow], now: Date = Date()) -> UsageAlert? {
        let live = windows.filter { $0.isCurrent(now: now) }
        if let full = live.filter({ $0.usedPercent >= 100 }).min(by: { ($0.resetsAt ?? .distantFuture) < ($1.resetsAt ?? .distantFuture) }) {
            return .exhausted(full)
        }
        let running = live.compactMap { window in window.forecast(now: now)?.exhaustsAt.map { (window, $0) } }
            .filter { $0.1 > now }
        if let soonest = running.min(by: { $0.1 < $1.1 }) { return .runsOut(soonest.0, at: soonest.1) }
        if let high = live.filter({ $0.usedPercent >= 90 }).max(by: { $0.usedPercent < $1.usedPercent }) {
            return .nearlyUsed(high)
        }
        return nil
    }
}
