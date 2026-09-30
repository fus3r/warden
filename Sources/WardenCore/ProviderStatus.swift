import Foundation

/// What a provider's public status page says about the services its coding agent uses, when something is wrong.
public struct ProviderIncident: Equatable {
    public var provider: AgentProvider
    /// "Elevated errors on Claude Code", or "Claude Code: degraded performance" when no incident is named.
    public var summary: String
    public var checkedAt: Date

    public init(provider: AgentProvider, summary: String, checkedAt: Date) {
        self.provider = provider
        self.summary = summary
        self.checkedAt = checkedAt
    }
}

/// Reads the providers' public status pages, which answer in the Statuspage format. Warden asks only while a session
/// has stopped on an error that may be the provider's, and only when that is turned on in Settings.
public enum ProviderStatus {
    public static func page(_ provider: AgentProvider) -> URL {
        URL(string: provider == .claude ? "https://status.claude.com" : "https://status.openai.com")!
    }

    public static func summaryURL(_ provider: AgentProvider) -> URL {
        page(provider).appendingPathComponent("api/v2/summary.json")
    }

    /// Error types that can come from the provider's side rather than from the account or the request.
    public static func mayBeProvider(_ failure: String?) -> Bool {
        ["overloaded", "server_error", "unknown", "api_error", "server_overloaded", "internal_server_error",
         "response_stream_disconnected", "http_connection_failed", "other"].contains(failure ?? "")
    }

    /// The components a coding agent depends on, by name on each page.
    static func concerns(_ component: String, provider: AgentProvider) -> Bool {
        let name = component.lowercased()
        return provider == .claude ? name.contains("claude code") || name.contains("claude api")
            : name.contains("codex") || name == "cli" || name.contains("vs code")
    }

    /// Nil while the components the agent uses are operational.
    public static func incident(from data: Data, provider: AgentProvider, checkedAt: Date) -> ProviderIncident? {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        let components = (object["components"] as? [[String: Any]] ?? []).filter {
            $0["group"] as? Bool != true && concerns($0["name"] as? String ?? "", provider: provider)
        }
        let affected = components.filter { ($0["status"] as? String ?? "operational") != "operational" }
        // An open incident that names a component the agent uses, or names none while one is affected, says best
        // what is wrong.
        let incidents = (object["incidents"] as? [[String: Any]] ?? []).filter { incident in
            guard (incident["status"] as? String) != "resolved" else { return false }
            let listed = (incident["components"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
            return listed.isEmpty ? !affected.isEmpty : listed.contains { concerns($0, provider: provider) }
        }
        if let name = incidents.first?["name"] as? String, !name.isEmpty {
            return ProviderIncident(provider: provider, summary: name, checkedAt: checkedAt)
        }
        guard !affected.isEmpty else { return nil }
        let words = affected.compactMap { component -> String? in
            guard let name = component["name"] as? String else { return nil }
            let status = (component["status"] as? String ?? "").replacingOccurrences(of: "_", with: " ")
            return "\(name.replacingOccurrences(of: " (api.anthropic.com)", with: "")): \(status)"
        }
        return ProviderIncident(provider: provider, summary: words.sorted().joined(separator: "; "), checkedAt: checkedAt)
    }
}
