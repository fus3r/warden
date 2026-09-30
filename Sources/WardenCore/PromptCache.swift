import Foundation

/// A Claude session's prompt cache: the context it holds and when it expires. Claude keeps a cached prompt for five
/// minutes or an hour after the request that last used it. A reply after that writes the whole context to the cache
/// again at the write price; a reply before reads it at a tenth of the input price.
public struct PromptCache: Equatable {
    /// Context tokens the next request writes again if the cache has expired by then.
    public var tokens: Int
    /// The cache's lifetime from its last use: 5 or 60.
    public var minutes: Int
    public var expiresAt: Date
    /// `provider` when Claude Code's status line reported the cache after the session's last request, `localLog`
    /// when it comes from the last cache write in the session's log.
    public var evidence: Evidence
    /// API list prices of that context for the next request: read from a warm cache, or written to a cold one.
    /// Nil for a model without a known price.
    public var warm: Double?
    public var cold: Double?
    /// Claude Code's record of this session's cache, when its status line reports one.
    public var report: StatusCache?

    /// Nil for a session without a cache in its log or status line, such as a Codex session, whose provider does not
    /// say how long it keeps a cache.
    public init?(_ session: AgentSession) {
        guard session.provider == .claude else { return nil }
        let reported = session.statusCache.flatMap { cache in
            session.statusCacheAt.map { $0 >= (session.lastRequestAt ?? .distantPast).addingTimeInterval(-2) } == true ? cache : nil
        }
        if let reported {
            // Claude Code knows exactly; a status line without cache tokens, or right after a compaction, has no cache to lose.
            guard let expires = reported.expiresAt, let tokens = reported.recacheTokens, tokens > 0,
                  let minutes = reported.minutes ?? session.cacheMinutes else { return nil }
            (self.tokens, self.minutes, expiresAt, evidence) = (tokens, minutes, expires, .provider)
        } else {
            guard let minutes = session.cacheMinutes, let last = session.lastRequestAt,
                  let tokens = session.lastInputTokens, tokens > 0 else { return nil }
            (self.tokens, self.minutes, expiresAt, evidence) = (tokens, minutes, last.addingTimeInterval(Double(minutes) * 60), .localLog)
        }
        report = session.statusCache
        if let price = session.modelID.flatMap(Pricing.price(for:)) {
            warm = Double(tokens) * price.cacheRead / 1_000_000
            cold = Double(tokens) * (minutes >= 60 ? price.cacheWriteHour : price.cacheWrite) / 1_000_000
        }
    }

    public func remaining(now: Date = Date()) -> TimeInterval { expiresAt.timeIntervalSince(now) }

    /// What a reply after the cache expires adds, at API list prices.
    public var penalty: Double? {
        guard let warm, let cold else { return nil }
        return max(0, cold - warm)
    }

    /// Whether letting the cache expire costs enough to mention: a point or more of the limit given, or, without a
    /// rate to convert with, a context of 150K tokens or more.
    public static func matters(tokens: Int, points: Double?) -> Bool {
        if let points { return points >= 1 }
        return tokens >= 150_000
    }

    /// Claude Code's names for why a cache missed, in words: "tools changed", "the hour-long cache expired".
    public static func cause(_ name: String) -> String {
        switch name {
        case "ttl_expired_1h": return "the hour-long cache expired"
        case "ttl_expired_5m": return "the five-minute cache expired"
        case "system_prompt_changed": return "the system prompt changed"
        case "tools_changed": return "the tools changed"
        case "model_changed": return "the model changed"
        case "messages_rewritten": return "earlier messages were rewritten"
        default: return name.replacingOccurrences(of: "_", with: " ")
        }
    }
}

public extension QuotaSummary {
    /// Points of a limit that use of this value at API prices takes, at the current window's rate, or at the rate of
    /// past windows before the current one has one. An estimate, like the rates it uses.
    func points(forAPIValue dollars: Double, window id: String) -> Double? {
        let rate = exchange(window: id)
        guard let perPoint = rate.current ?? rate.typical, perPoint > 0 else { return nil }
        return dollars / perPoint
    }
}
