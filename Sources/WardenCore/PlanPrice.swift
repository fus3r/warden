import Foundation

/// What a plan's weekly limit stands for in the money you pay for the plan, from a monthly price you enter. A week
/// takes 12/52 of a month's price, and each point of the week's shared limit a hundredth of that: a point used
/// costs the same whether the week ends full or not, and the points left unused are value you paid for and did
/// not use. The 5-hour and model limits only pace use within the week, so they have no price of their own.
public enum PlanPrice {
    /// The key a price is saved under: "Claude/" for the default Claude account, "Codex/work" for another.
    public static func key(provider: AgentProvider, account: String?) -> String { "\(provider.rawValue)/\(account ?? "")" }

    public static func key(_ window: UsageWindow) -> String { key(provider: window.provider, account: window.account) }

    /// A week's share of a monthly price.
    public static func weekly(monthly: Double) -> Double { monthly * 12 / 52 }

    /// Whether a limit is the plan's own weekly limit, whose points a price can be spread over.
    public static func applies(to window: UsageWindow) -> Bool {
        window.durationMinutes == 10_080 && window.scope == nil && QuotaLedger.isQuota(window)
    }

    /// Dollars of the plan that one point of its weekly limit stands for, when the limit has a price.
    public static func perPoint(_ window: UsageWindow, prices: [String: Double]) -> Double? {
        guard applies(to: window), let monthly = prices[key(window)], monthly > 0 else { return nil }
        return weekly(monthly: monthly) / 100
    }
}
