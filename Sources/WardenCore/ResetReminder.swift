import Foundation

/// A provider-reported banked reset or an expiry entered from the provider's Usage page.
public struct ResetReminder: Codable, Equatable, Identifiable {
    public enum Source: String, Codable { case provider, manual }
    public var id: String
    public var provider: AgentProvider
    public var account: String?
    public var title: String
    public var expiresAt: Date
    public var source: Source
    public var observedAt: Date

    public init(id: String = UUID().uuidString, provider: AgentProvider, account: String? = nil,
                title: String = "Full reset", expiresAt: Date, source: Source, observedAt: Date = Date()) {
        self.id = id
        self.provider = provider
        self.account = account
        self.title = title
        self.expiresAt = expiresAt
        self.source = source
        self.observedAt = observedAt
    }

    public var name: String { provider.rawValue + (account.map { " (\($0))" } ?? "") }
    public var usageURL: URL {
        URL(string: provider == .claude ? "https://claude.ai/new#settings/usage" : "https://chatgpt.com/codex/settings/usage")!
    }

    /// Once at the chosen lead time, with a final reminder in the last hour.
    /// Old CLI data and expired offers cannot trigger an availability claim.
    public func alertKey(now: Date, leadHours: Double) -> String? {
        let remaining = expiresAt.timeIntervalSince(now)
        guard remaining > 0, remaining <= max(1, leadHours) * 3600,
              source == .manual || (observedAt <= now && now.timeIntervalSince(observedAt) < 900) else { return nil }
        return "reset-expiry-\(id)-\(Int(expiresAt.timeIntervalSince1970))-\(remaining <= 3600 ? "final" : "soon")"
    }

    public static func reported(in plans: [PlanDetails]) -> [Self] {
        plans.filter { $0.resets > 0 }.flatMap { plan in
            Set(plan.resetsExpire).map { expiry in
                Self(id: "\(plan.provider.rawValue)-\(plan.account ?? "default")-\(Int(expiry.timeIntervalSince1970))",
                     provider: plan.provider, account: plan.account, title: "Banked reset", expiresAt: expiry,
                     source: .provider, observedAt: plan.observedAt)
            }
        }.sorted { $0.expiresAt < $1.expiresAt }
    }
}
