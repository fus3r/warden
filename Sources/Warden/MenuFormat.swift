import AppKit
import WardenCore

enum MenuFormat {
    /// Session counts for the menu header and the menu bar item's tooltip.
    static func summary(attention: Int, working: Int) -> String {
        switch (attention, working) {
        case (0, 0): return "No agents are working"
        case (0, _): return working == 1 ? "1 agent working" : "\(working) agents working"
        case (_, 0): return attention == 1 ? "1 session needs you" : "\(attention) sessions need you"
        default: return "\(attention) need you · \(working) working"
        }
    }

    /// What stopped a session, from the error type Claude Code reports in its log and StopFailure hook.
    /// Claude Code's error types, and the `codex_error_info` of a failed Codex turn.
    static func failure(_ type: String?) -> String {
        switch type {
        case "rate_limit", "usage_limit_exceeded", "rate_limit_exceeded", "quota_auto_resume_disabled": return "Stopped at a usage limit"
        case "quota_auto_resume_stale": return "The limit reset while the Mac slept: press Enter to continue"
        case "session_budget_exceeded": return "Stopped: the session budget is spent"
        case "refusal": return "Stopped: the model declined to go on"
        case "authentication_failed", "cloud_credential_error": return "Login expired, run /login"
        case "oauth_org_not_allowed": return "Stopped: this organization is not allowed"
        case "account_on_hold": return "Stopped: the account is on hold"
        case "billing_error": return "Stopped by a billing problem"
        case "overloaded", "server_overloaded", "server_error": return "Stopped: the service is overloaded"
        case "context_window_exceeded": return "Stopped: the context is full"
        case "max_output_tokens": return "Stopped: the reply was too long"
        case "model_not_found": return "Stopped: the model is unavailable"
        case "invalid_request": return "Stopped: the request was rejected"
        default: return "Stopped with an error"
        }
    }

    /// Whether a failure is a usage limit, which has its own sound.
    static func isLimit(_ type: String?) -> Bool {
        ["rate_limit", "usage_limit_exceeded", "rate_limit_exceeded", "quota_auto_resume_disabled"].contains(type ?? "")
    }

    /// Compact age for menu badges: "now", "4 min", "2 h", "3 d".
    static func age(since date: Date, now: Date = Date()) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        if seconds < 60 { return "now" }
        if seconds < 3600 { return "\(Int(seconds / 60)) min" }
        if seconds < 86_400 { return "\(Int(seconds / 3600)) h" }
        return "\(Int(seconds / 86_400)) d"
    }

    /// Time left for a sentence: "under a minute", "8 min", "1 h 05".
    static func remaining(_ seconds: TimeInterval) -> String {
        if seconds < 60 { return "under a minute" }
        if seconds < 3600 { return "\(Int(seconds / 60)) min" }
        return String(format: "%d h %02d", Int(seconds / 3600), Int(seconds.truncatingRemainder(dividingBy: 3600) / 60))
    }

    /// Time until a reset for the usage table: "42 min", "2 h 05", or a weekday.
    static func resetShort(_ date: Date, now: Date = Date()) -> String {
        let seconds = date.timeIntervalSince(now)
        if seconds <= 0 { return "Reset" }
        if seconds < 3600 { return "\(max(1, Int(seconds / 60))) min" }
        if seconds < 86_400 { return String(format: "%d h %02d", Int(seconds / 3600), Int(seconds.truncatingRemainder(dividingBy: 3600) / 60)) }
        return date.formatted(.dateTime.weekday(.abbreviated))
    }

    /// Reset time for a sentence: "in 42 min", "at 00:00", "Friday at 10:00".
    static func resetPhrase(_ date: Date, now: Date = Date()) -> String {
        let seconds = date.timeIntervalSince(now)
        if seconds <= 0 { return "pending confirmation" }
        if seconds < 3600 { return "in \(max(1, Int(seconds / 60))) min" }
        if seconds < 86_400 { return "at \(time(date))" }
        return "\(date.formatted(.dateTime.weekday(.wide))) at \(time(date))"
    }

    /// Monthly plan prices entered in Settings, by `PlanPrice.key`.
    static var planPrices: [String: Double] {
        (UserDefaults.standard.dictionary(forKey: "planPrices") ?? [:]).compactMapValues { ($0 as? NSNumber)?.doubleValue }
    }

    /// Dollars at API prices: cents below ten dollars, whole dollars above.
    static func cost(_ dollars: Double) -> String {
        dollars.formatted(.currency(code: "USD").presentation(.narrow)
            .precision(.fractionLength(dollars > 0 && dollars < 10 ? 2 : 0)))
    }

    /// Percentage points of a limit: "<0.1%", "2.4%", "31%".
    static func points(_ value: Double) -> String {
        if value > 0 && value < 0.1 { return "<0.1%" }
        return "\(value.formatted(.number.precision(.fractionLength(value < 10 ? 1 : 0))))%"
    }

    /// Tokens in short form: "840K", "1.5B".
    static func tokens(_ count: Int) -> String {
        count < 1000 ? count.formatted() : count.formatted(.number.notation(.compactName).precision(.significantDigits(2)))
    }

    /// Cost when every token has a price, and tokens otherwise, so an estimate never leaves use out silently.
    static func amount(_ totals: UsageTotals, showCost: Bool = false) -> String {
        if totals.tokens == 0 { return "–" }
        return showCost && totals.isFullyPriced ? "≈" + cost(totals.cost) + " API" : tokens(totals.tokens) + " tok"
    }

    /// Readable model names: "claude-opus-5-5" as "Opus 5.5", "claude-haiku-4-5-20251001" as "Haiku 4.5".
    static func modelName(_ id: String) -> String {
        guard id.hasPrefix("claude-") else { return id }
        var parts = id.dropFirst("claude-".count).split(separator: "-").map(String.init)
        if let last = parts.last, last.count == 8, Int(last) != nil { parts.removeLast() }
        guard let family = parts.first else { return id }
        let version = parts.dropFirst().joined(separator: ".")
        return family.prefix(1).uppercased() + family.dropFirst() + (version.isEmpty ? "" : " " + version)
    }

    /// A day key from the usage history, "2026-09-24", as a date at the start of that day.
    static func date(_ day: String) -> Date? {
        let parts = day.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return Calendar.current.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }

    /// An estimated moment: "around 14:40" today, "Thursday around 14:40" on another day.
    static func moment(_ date: Date, now: Date = Date()) -> String {
        let day = Calendar.current.isDate(date, inSameDayAs: now) ? "" : date.formatted(.dateTime.weekday(.wide)) + " "
        return "\(day)around \(time(date))"
    }

    static func time(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }

    /// Truncates text with an ellipsis so it fits a width, keeping the menu from growing.
    static func fit(_ text: String, width: CGFloat, font: NSFont) -> String {
        let attributes: [NSAttributedString.Key: Any] = [.font: font]
        guard (text as NSString).size(withAttributes: attributes).width > width else { return text }
        var result = Substring(text)
        while !result.isEmpty, ((result + "…") as NSString).size(withAttributes: attributes).width > width {
            result = result.dropLast()
        }
        return result.trimmingCharacters(in: .whitespaces) + "…"
    }
}
