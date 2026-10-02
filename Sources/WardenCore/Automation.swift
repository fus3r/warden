import Foundation

/// An event for the scripts in Warden's Automations folder: what an alert says, and which session or limit it is
/// about. It carries no prompt, reply, or command; a question alert quotes the question, as its notification does.
public struct AutomationEvent: Codable, Equatable {
    /// `needs-you`, `finished`, `context`, `cache-expiring`, `limit-warning`, `limit-reached`, `limit-unused`,
    /// `reset-moved`, `reset-expiring`, `daily-budget`, `quota-available`, `away-summary`, or `test`.
    public var event: String
    public var at: Date
    /// The notification's title and text.
    public var title: String
    public var message: String
    public var session: String?
    /// "Claude" or "Codex".
    public var agent: String?
    public var account: String?
    /// The session's folder.
    public var project: String?
    /// Whether Warden also showed or spoke the alert; false when snoozed, muted by the alert mode, or in quiet hours.
    public var alerted: Bool

    public init(event: String, at: Date, title: String, message: String, session: String? = nil, agent: String? = nil,
                account: String? = nil, project: String? = nil, alerted: Bool) {
        self.event = event
        self.at = at
        self.title = title
        self.message = message
        self.session = session
        self.agent = agent
        self.account = account
        self.project = project
        self.alerted = alerted
    }

    /// The event an alert key stands for, from the key's prefix.
    public static func name(forAlert key: String) -> String {
        let prefixes: [(String, String)] = [
            ("approval-", "needs-you"), ("attention-", "needs-you"), ("finish-", "finished"), ("context-", "context"),
            ("cache-", "cache-expiring"), ("resume-", "limit-reached"), ("restored-", "quota-available"),
            ("away-", "away-summary"), ("unused-", "limit-unused"), ("moved-", "reset-moved"), ("budget-", "daily-budget"),
            ("reset-expiry-", "reset-expiring"),
            ("test-", "test")
        ]
        return prefixes.first { key.hasPrefix($0.0) }?.1 ?? "limit-warning"
    }

    /// The environment a script gets besides the JSON on its standard input.
    public var environment: [String: String] {
        var values = ["WARDEN_EVENT": event, "WARDEN_TITLE": title, "WARDEN_MESSAGE": message]
        values["WARDEN_SESSION"] = session
        values["WARDEN_AGENT"] = agent
        values["WARDEN_PROJECT"] = project
        return values
    }

    public var json: Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(self)) ?? Data("{}".utf8)
    }
}
