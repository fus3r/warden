import Foundation

public enum HistoryMetric: String, CaseIterable, Identifiable {
    case tokens, requests, apiEquivalent
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .tokens: return "Tokens"
        case .requests: return "Requests"
        case .apiEquivalent: return "API equivalent"
        }
    }
    public func value(_ totals: UsageTotals) -> Double {
        switch self {
        case .tokens: return Double(totals.tokens)
        case .requests: return Double(totals.requests)
        case .apiEquivalent: return totals.cost
        }
    }
}

public struct UsageAccount: Hashable, Identifiable {
    public let provider: AgentProvider
    public let name: String?
    public var id: String { "\(provider.rawValue)/\(name ?? "")" }
    public var title: String { "\(provider.rawValue) · \(name ?? "Default")" }
    public init(provider: AgentProvider, name: String?) { self.provider = provider; self.name = name }
}

/// Tokens and their cost at API prices for a set of usage records.
public struct UsageTotals: Equatable {
    public private(set) var usage = TokenUsage()
    public var tokens: Int { usage.total }
    public var requests: Int { usage.requests }
    /// The share of recorded input served from cache. Output is never part of this denominator.
    public var cacheReadFraction: Double? {
        let input = usage.input + usage.cacheWrite + usage.cacheWriteHour + usage.cacheRead
        return input > 0 ? Double(usage.cacheRead) / Double(input) : nil
    }
    /// Dollars at public API prices for the models with a known price.
    public var cost = 0.0
    /// Tokens from models without a known price, which the cost leaves out.
    public var unpricedTokens = 0

    public init() {}

    public mutating func add(_ usage: TokenUsage, model: String) {
        self.usage = self.usage + usage
        if let price = Pricing.price(for: model) {
            cost += price.cost(of: usage)
        } else {
            unpricedTokens += usage.total
        }
    }

    public mutating func add(_ other: UsageTotals) {
        usage = usage + other.usage
        cost += other.cost
        unpricedTokens += other.unpricedTokens
    }

    /// True when every token has a price, so the cost covers all use.
    public var isFullyPriced: Bool { unpricedTokens == 0 }
}

/// Usage grouped for the menu: by day, provider, project, and model.
public struct UsageSummary {
    public struct Group: Equatable {
        public var name: String
        public var provider: AgentProvider?
        public var totals: UsageTotals
    }

    public let records: [UsageRecord]
    public let today: String
    /// Use so far of each session still being written, by session id.
    public let sessions: [String: UsageTotals]

    public init(records: [UsageRecord], sessions: [String: [UsageRecord]] = [:], now: Date = Date(),
                calendar: Calendar = .current) {
        self.records = records
        self.today = UsageLedger.dayString(now, calendar: calendar)
        self.calendar = calendar
        self.now = now
        self.sessions = sessions.mapValues { records in
            var totals = UsageTotals()
            for record in records { totals.add(record.usage, model: record.model) }
            return totals
        }
    }

    private let calendar: Calendar
    private let now: Date

    public var accounts: [UsageAccount] {
        Set(records.map { UsageAccount(provider: $0.provider, name: $0.account) }).sorted { $0.id < $1.id }
    }

    public func filtered(to account: UsageAccount? = nil, project: String? = nil, day: String? = nil) -> UsageSummary {
        guard account != nil || project != nil || day != nil else { return self }
        return UsageSummary(records: records.filter {
            (account == nil || ($0.provider == account?.provider && $0.account == account?.name))
                && (project == nil || $0.project == project) && (day == nil || $0.day == day)
        },
                            now: now, calendar: calendar)
    }

    /// The first day of a period that ends today: 1 for today alone, 7 for the last seven days.
    public func firstDay(ofLast days: Int) -> String {
        let start = calendar.date(byAdding: .day, value: 1 - days, to: now) ?? now
        return UsageLedger.dayString(start, calendar: calendar)
    }

    public func totals(lastDays days: Int, provider: AgentProvider? = nil) -> UsageTotals {
        let first = firstDay(ofLast: days)
        var totals = UsageTotals()
        for record in records where record.day >= first && record.day <= today && (provider == nil || record.provider == provider) {
            totals.add(record.usage, model: record.model)
        }
        return totals
    }

    /// One entry per day of the period, oldest first, including days without use.
    public func daily(lastDays days: Int) -> [(day: String, byProvider: [AgentProvider: UsageTotals])] {
        var byDay: [String: [AgentProvider: UsageTotals]] = [:]
        let first = firstDay(ofLast: days)
        for record in records where record.day >= first && record.day <= today {
            byDay[record.day, default: [:]][record.provider, default: UsageTotals()].add(record.usage, model: record.model)
        }
        return (0..<days).reversed().map { back in
            let date = calendar.date(byAdding: .day, value: -back, to: now) ?? now
            let day = UsageLedger.dayString(date, calendar: calendar)
            return (day, byDay[day] ?? [:])
        }
    }

    /// Use from the local logs since a limit window opened, for the models the window covers: every model of its
    /// provider, or one model for a limit on one model. Days count whole, so the first day may add a little.
    public func totals(since window: UsageWindow) -> UsageTotals? {
        guard let minutes = window.durationMinutes, let reset = window.resetsAt else { return nil }
        let first = UsageLedger.dayString(reset.addingTimeInterval(-Double(minutes) * 60), calendar: calendar)
        let scope = window.scope?.lowercased()
        var totals = UsageTotals()
        for record in records where record.provider == window.provider && record.account == window.account
            && record.day >= first && record.day <= today {
            if let scope, !record.model.lowercased().contains(scope) { continue }
            totals.add(record.usage, model: record.model)
        }
        return totals
    }

    /// Project folders ordered by the selected metric; token use is the subscription-friendly default.
    public func projects(lastDays days: Int, metric: HistoryMetric = .tokens) -> [Group] {
        grouped(lastDays: days, metric: metric) { ($0.project, nil) }
    }

    public func models(lastDays days: Int, metric: HistoryMetric = .tokens) -> [Group] {
        grouped(lastDays: days, metric: metric) { ($0.model, $0.provider) }
    }

    private func grouped(lastDays days: Int, metric: HistoryMetric, by key: (UsageRecord) -> (String, AgentProvider?)) -> [Group] {
        let first = firstDay(ofLast: days)
        var groups: [String: Group] = [:]
        for record in records where record.day >= first && record.day <= today {
            let (name, provider) = key(record)
            let id = "\(provider?.rawValue ?? "")\t\(name)"
            groups[id, default: Group(name: name, provider: provider, totals: UsageTotals())].totals.add(record.usage, model: record.model)
        }
        return groups.values.sorted {
            let left = metric.value($0.totals), right = metric.value($1.totals)
            return left != right ? left > right : $0.name < $1.name
        }
    }

    /// Local daily aggregates only. An unknown price is an empty cell, never a zero-dollar estimate.
    public func csv(lastDays days: Int, includeAPIEquivalent: Bool = false) -> String {
        func cell(_ value: String) -> String { "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
        var header = ["day", "provider", "account", "model", "project", "input_tokens", "cache_write_5m_tokens",
                      "cache_write_1h_tokens", "cache_read_tokens", "output_tokens", "requests", "source"]
        if includeAPIEquivalent { header += ["estimated_api_equivalent_usd", "price_basis"] }
        let first = firstDay(ofLast: days)
        let selected = records.filter { $0.day >= first && $0.day <= today }
        let daily = Dictionary(grouping: selected) { [$0.day, $0.provider.rawValue, $0.account ?? "", $0.project, $0.model] }
            .values.map { group in
                var record = group[0]
                record.usage = group.reduce(TokenUsage()) { $0 + $1.usage }
                return record
            }
        let rows = daily.sorted {
            ($0.day, $0.provider.rawValue, $0.account ?? "", $0.project, $0.model)
                < ($1.day, $1.provider.rawValue, $1.account ?? "", $1.project, $1.model)
        }.map { record in
            let use = record.usage
            var values = [record.day, record.provider.rawValue, record.account ?? "Default", record.model, record.project,
                          String(use.input), String(use.cacheWrite), String(use.cacheWriteHour), String(use.cacheRead),
                          String(use.output), String(use.requests), "local_log"]
            if includeAPIEquivalent {
                let price = Pricing.price(for: record.model)
                values += [price.map { String(format: "%.6f", locale: Locale(identifier: "en_US_POSIX"), $0.cost(of: use)) } ?? "",
                           price == nil ? "unavailable" : "standard API list price; not a bill; verified " + Pricing.verifiedOn]
            }
            return values.map(cell).joined(separator: ",")
        }
        return ([header.joined(separator: ",")] + rows).joined(separator: "\r\n") + "\r\n"
    }
}
