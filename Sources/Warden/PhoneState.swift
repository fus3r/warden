import Foundation
import WardenCore

/// What the phone page shows: sessions that need you, with the answers Warden can send, working sessions, and limits.
/// It goes only to paired phones, over TLS, and is never written to disk.
struct PhoneState: Codable, Equatable {
    struct Choice: Codable, Equatable {
        /// "allow", "allowForSession", "allowAlways", "deny", or "option:<index>".
        var id: String
        var title: String
        /// "primary" or "destructive", for the button's color.
        var role: String?
        /// What the choice does beyond its title, such as where a kept rule goes.
        var detail: String?
    }

    struct Prompt: Codable, Equatable {
        var id: String
        /// The tool asking, such as "Bash", for a permission.
        var tool: String?
        /// What the tool would do: a command, a file, or a URL.
        var summary: String?
        /// The question, for a question with options.
        var question: String?
        /// Empty when the prompt can only be answered where it runs, such as a question with several parts.
        var choices: [Choice]
    }

    struct Session: Codable, Equatable {
        var id: String
        /// "Claude", or "Claude (work)" for another account.
        var agent: String
        var project: String
        var title: String?
        /// One line on the session's state, as in the menu.
        var status: String
        var since: Date
        var context: Double?
        var prompt: Prompt?
    }

    struct Limit: Codable, Equatable {
        var name: String
        var used: Double
        /// Where usage would sit at an even pace through the window, in percent.
        var pace: Double?
        var resetsAt: Date?
        /// Not reported for half an hour, or past its reset.
        var stale: Bool
        /// Nearly used, or on pace to run out before its reset, as the menu colors it.
        var urgent: Bool
    }

    var version = 0
    var mac: String
    /// The Mac's clock when the state was sent, so the phone can correct for its own.
    var now = Date()
    var needsYou: [Session]
    var working: [Session]
    var limits: [Limit]
    var snoozedUntil: Date?

    /// Whether two states show the same thing, ignoring when they were sent.
    func sameContent(as other: PhoneState?) -> Bool {
        guard var other else { return false }
        other.version = version
        other.now = now
        return other == self
    }

    @MainActor
    static func make(store: WardenStore, mac: String, now: Date = Date()) -> PhoneState {
        func session(_ session: AgentSession) -> Session {
            let approval = store.approval(for: session)?.request
            return Session(id: session.id, agent: session.provider.rawValue + (session.account.map { " (\($0))" } ?? ""),
                           project: session.project, title: session.title,
                           status: status(session, approval: approval, now: now),
                           since: session.phase == .working ? (session.turnStartedAt ?? session.updatedAt) : session.updatedAt,
                           context: session.contextPercent,
                           prompt: session.phase == .needsAttention ? approval.map(prompt) : nil)
        }
        let limits = store.windows.map { window in
            let reset = window.hasReset(now: now)
            let forecast = window.forecast(now: now)
            let current = window.isCurrent(now: now)
            return Limit(name: window.name, used: reset ? 0 : window.usedPercent,
                         pace: forecast.map { $0.elapsedFraction * 100 },
                         resetsAt: window.resetsAt, stale: reset || !current,
                         urgent: current && (window.usedPercent >= 90 || forecast?.exhaustsAt != nil))
        }
        return PhoneState(mac: mac, now: now, needsYou: store.attentionQueue.map(session),
                          working: store.sessions.filter { $0.phase == .working }.map(session),
                          limits: limits, snoozedUntil: store.snoozedUntil)
    }

    /// The answers the menu offers for a prompt, in the same order.
    private static func prompt(_ request: ApprovalRequest) -> Prompt {
        var choices: [Choice] = []
        if request.isQuestion {
            // As in the menu, only a single choice fits a button row; other questions are answered where they run.
            if let question = request.questions.first, request.questions.count == 1, !question.multiSelect {
                choices = question.options.enumerated().map { Choice(id: "option:\($0.offset)", title: $0.element) }
            }
            return Prompt(id: request.id, question: request.questions.first?.text, choices: choices)
        }
        choices.append(Choice(id: "allow", title: "Allow", role: "primary"))
        if request.canAllowForSession { choices.append(Choice(id: "allowForSession", title: "Allow for This Session")) }
        if let rule = request.alwaysRule {
            choices.append(Choice(id: "allowAlways", title: "Always Allow \(rule)",
                                  detail: "Keeps the rule \(rule) in \(request.alwaysFile ?? "its settings") and stops asking for it."))
        }
        choices.append(Choice(id: "deny", title: "Deny", role: "destructive"))
        return Prompt(id: request.id, tool: request.tool, summary: request.summary, choices: choices)
    }

    /// The menu's subtitle for a session, without its agent and folder, which the page shows apart.
    private static func status(_ session: AgentSession, approval: ApprovalRequest?, now: Date) -> String {
        switch session.phase {
        case .needsAttention:
            switch session.attention {
            case .permission:
                if let approval { return Approval.wants(tool: approval.tool, provider: approval.provider) }
                return session.detail.map { Approval.wants(tool: $0, provider: session.provider) } ?? "Waiting for your approval"
            case .question: return session.detail ?? "Asked you a question"
            case .choice: return session.detail ?? "Waiting for your answer"
            case .failure: return MenuFormat.failure(session.detail)
            case .interrupted: return "Interrupted, waiting for you"
            default: return session.detail ?? "Needs your input"
            }
        case .working:
            if let resumes = session.resumesAt { return "Usage limit, resumes \(MenuFormat.resetPhrase(resumes, now: now))" }
            if let retry = session.retry, now.timeIntervalSince(retry.at) < 600 {
                return "\(retry.networkDown ? "Offline, retrying" : "Retrying after an error") (\(retry.attempt) of \(retry.maxAttempts))"
            }
            if session.activeSubagents > 0 {
                return session.activeSubagents == 1 ? "1 agent working" : "\(session.activeSubagents) agents working"
            }
            if session.busyInBackground { return "Background task running" }
            if let context = session.contextPercent {
                return "Context \(session.contextEvidence == .inferred ? "≈" : "")\(Int(context.rounded()))%"
            }
            return "Working"
        default:
            return session.phase == .finished ? "Done" : "Quiet"
        }
    }
}
