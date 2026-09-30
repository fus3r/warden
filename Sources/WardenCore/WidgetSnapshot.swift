import Foundation

/// What Warden's widgets show. The app writes it for its widget extension, which runs in a sandbox and cannot ask the
/// app. Like the activity log, it keeps folder names, agents, states, and tool names, never a title, command, or question.
public struct WidgetSnapshot: Codable, Equatable {
    public struct Item: Codable, Equatable {
        /// The session's id, for a link that brings it forward.
        public var session: String
        /// "Claude", or "Claude (work)".
        public var agent: String
        /// The session's folder name.
        public var project: String
        /// Why it waits: "Wants to use Bash", "Asked a question", "Stopped at a usage limit".
        public var reason: String
        public var since: Date

        public init(session: String, agent: String, project: String, reason: String, since: Date) {
            self.session = session
            self.agent = agent
            self.project = project
            self.reason = reason
            self.since = since
        }
    }

    public struct Limit: Codable, Equatable {
        /// "Claude 5h".
        public var name: String
        public var used: Double
        public var resetsAt: Date?
        /// The window's length, for the even-pace tick at any moment.
        public var minutes: Int?
        /// Nearly used, or on pace to run out before its reset.
        public var urgent: Bool

        public init(name: String, used: Double, resetsAt: Date?, minutes: Int?, urgent: Bool) {
            self.name = name
            self.used = used
            self.resetsAt = resetsAt
            self.minutes = minutes
            self.urgent = urgent
        }

        /// Where usage would sit at an even pace through the window at `date`, from 0 to 1.
        public func pace(at date: Date) -> Double? {
            guard let resetsAt, let minutes, minutes > 0 else { return nil }
            let left = resetsAt.timeIntervalSince(date) / (Double(minutes) * 60)
            return left < 0 || left > 1 ? nil : 1 - left
        }
    }

    public var needsYou: [Item]
    /// Folder names of the sessions at work.
    public var working: [String]
    public var limits: [Limit]
    public var updatedAt: Date

    public init(needsYou: [Item], working: [String], limits: [Limit], updatedAt: Date) {
        self.needsYou = needsYou
        self.working = working
        self.limits = limits
        self.updatedAt = updatedAt
    }

    /// Whether two snapshots show the same thing, whenever they were written.
    public func sameContent(as other: WidgetSnapshot?) -> Bool {
        guard var other else { return false }
        other.updatedAt = updatedAt
        return other == self
    }

    /// The folder the app writes to and the widget may read, relative to the home folder. The widget's sandbox allows
    /// reading this one folder only.
    public static func folder(home: URL, preview: Bool) -> URL {
        home.appendingPathComponent("Library/Application Support/\(preview ? "WardenPreview" : "Warden")/Widget", isDirectory: true)
    }

    public static let fileName = "snapshot.json"

    public static func read(from file: URL) -> WidgetSnapshot? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? Data(contentsOf: file)).flatMap { try? decoder.decode(WidgetSnapshot.self, from: $0) }
    }

    public func encoded() -> Data? {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try? encoder.encode(self)
    }
}
