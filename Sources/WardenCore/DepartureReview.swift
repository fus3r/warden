import Foundation

/// A bounded review of observations already in memory. It predicts neither task completion nor new approvals.
public struct DepartureReview {
    public enum Kind: String { case scan, decision, context, cache, quotaCoverage, resume }
    public struct Item: Identifiable {
        public let id: String
        public let kind: Kind
        public let title: String
        public let detail: String
        public let sessionID: String?
        public let evidence: Evidence?
        public let observedAt: Date?
        public let deadline: Date?
    }

    public let items: [Item]
    public let workingCount: Int

    public init(sessions: [AgentSession], windows: [UsageWindow], scannedAt: Date?,
                minutes: Int, contextThreshold: Double = 85, now: Date = Date()) {
        let sessions = sessions.filter { !$0.ended && !$0.isSubagent }
        let working = sessions.filter { $0.phase == .working }
        guard let scannedAt, now.timeIntervalSince(scannedAt) >= -5, now.timeIntervalSince(scannedAt) < 60 else {
            workingCount = 0
            items = [Item(id: "scan", kind: .scan, title: "Activity needs a fresh scan",
                          detail: "Refresh before relying on session state or sleep protection.", sessionID: nil,
                          evidence: nil, observedAt: scannedAt, deadline: nil)]
            return
        }
        workingCount = working.count
        let end = now.addingTimeInterval(Double(minutes) * 60)
        var result: [Item] = []
        func append(_ kind: Kind, _ session: AgentSession, _ detail: String, evidence: Evidence?,
                    observedAt: Date?, deadline: Date? = nil) {
            result.append(Item(id: session.id + "/" + kind.rawValue, kind: kind,
                               title: session.title ?? session.project, detail: detail, sessionID: session.id,
                               evidence: evidence, observedAt: observedAt, deadline: deadline))
        }
        let rank: [AttentionKind: Int] = [.permission: 0, .question: 1, .choice: 1, .failure: 2, .interrupted: 3, .notification: 4]
        let waiting = sessions.filter { $0.phase == .needsAttention }.sorted {
            let left = rank[$0.attention ?? .notification] ?? 5
            let right = rank[$1.attention ?? .notification] ?? 5
            return left != right ? left < right : $0.updatedAt < $1.updatedAt
        }
        for session in waiting {
            append(.decision, session, session.attention == .permission ? "Waiting for your approval."
                   : session.attention == .failure ? "Stopped after an error; inspect it before leaving."
                   : "Waiting for your input.", evidence: session.phaseEvidence, observedAt: session.updatedAt)
        }
        for session in sessions {
            if let percent = session.contextPercent, percent >= contextThreshold {
                append(.context, session, "Last context reading: \(Int(percent.rounded()))% full. A long task may need compaction.",
                       evidence: session.contextEvidence, observedAt: session.updatedAt)
            }
        }
        // Quiet sessions can lose an expensive cache while the user is away. Working sessions renew theirs.
        for session in sessions where session.phase == .needsAttention || session.phase == .finished || session.phase == .idle {
            if let cache = PromptCache(session), cache.tokens >= 150_000, cache.expiresAt > now, cache.expiresAt <= end {
                append(.cache, session, "\(cache.tokens.formatted()) input tokens may need caching again after expiry. This is not a subscription charge.",
                       evidence: cache.evidence == .provider ? .provider : .inferred,
                       observedAt: cache.evidence == .provider ? session.statusCacheAt : session.lastRequestAt, deadline: cache.expiresAt)
            }
            if let resume = session.resumesAt, resume > now, resume <= end {
                append(.resume, session, "The provider reported an automatic resume after this reset. Renewed capacity is not confirmed yet.",
                       evidence: session.phaseEvidence, observedAt: session.updatedAt, deadline: resume)
            }
        }
        var checked = Set<String>()
        let routes = WorkRoute.all(in: windows)
        for session in working {
            let key = session.provider.rawValue + "/" + (session.account ?? "")
            guard checked.insert(key).inserted else { continue }
            let shared = routes.first { $0.provider == session.provider && $0.account == session.account && $0.scope == nil }
            if shared == nil || shared!.windows.contains(where: { !$0.isCurrent(now: now) }) {
                result.append(Item(id: "quota/" + key, kind: .quotaCoverage,
                                   title: session.provider.rawValue + (session.account.map { " (\($0))" } ?? ""),
                                   detail: "No current shared quota reading. The duration of unattended work cannot be checked for this account.",
                                   sessionID: nil, evidence: nil, observedAt: nil, deadline: nil))
            }
        }
        items = result
    }
}
