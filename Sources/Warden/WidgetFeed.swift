import Foundation
import WardenCore
import WidgetKit

/// Keeps the widget extension's snapshot current. The extension runs in a sandbox that may read only this file's
/// folder, so the app writes what the widgets show there: when it changes, and every quarter hour so a widget can tell
/// that Warden still runs. Each write asks WidgetKit to read it again, at most twice a minute.
@MainActor
final class WidgetFeed {
    private var written: WidgetSnapshot?
    private var reloadedAt = Date.distantPast
    private var reloadPending = false

    static var file: URL {
        #if DEBUG
        let preview = true
        #else
        let preview = false
        #endif
        return WidgetSnapshot.folder(home: FileManager.default.homeDirectoryForCurrentUser, preview: preview)
            .appendingPathComponent(WidgetSnapshot.fileName)
    }

    func update(_ snapshot: WidgetSnapshot) {
        let due = written.map { snapshot.updatedAt.timeIntervalSince($0.updatedAt) >= 900 } ?? true
        guard due || !snapshot.sameContent(as: written), let data = snapshot.encoded() else { return }
        written = snapshot
        try? FileManager.default.createDirectory(at: Self.file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: Self.file, options: .atomic)
        reload()
    }

    private func reload() {
        let wait = 30 - Date().timeIntervalSince(reloadedAt)
        guard wait > 0 else {
            reloadedAt = Date()
            WidgetCenter.shared.reloadAllTimelines()
            return
        }
        guard !reloadPending else { return }
        reloadPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.reloadPending = false
                self.reloadedAt = Date()
                WidgetCenter.shared.reloadAllTimelines()
            }
        }
    }

    /// What the widgets show: folders, agents, states, and tool names, never a title, command, or question.
    static func snapshot(attention: [AgentSession], working: [AgentSession], windows: [UsageWindow],
                         tool: (AgentSession) -> String?, now: Date = Date()) -> WidgetSnapshot {
        let items = attention.map { session -> WidgetSnapshot.Item in
            let reason: String
            switch session.attention {
            case .permission: reason = tool(session).map { Approval.wants(tool: $0, provider: session.provider) } ?? "Waiting for approval"
            case .question: reason = "Asked a question"
            case .choice: reason = "Waiting for an answer"
            case .failure: reason = MenuFormat.failure(session.detail)
            case .interrupted: reason = "Interrupted"
            default: reason = "Needs you"
            }
            return WidgetSnapshot.Item(session: session.id, agent: session.provider.rawValue + (session.account.map { " (\($0))" } ?? ""),
                                       project: session.project, reason: reason, since: session.updatedAt)
        }
        // The last reading of a window stays useful until its reset, even when it is not recent.
        let limits = windows.filter { !$0.hasReset(now: now) }.map { window in
            WidgetSnapshot.Limit(name: window.name, used: window.usedPercent, resetsAt: window.resetsAt, minutes: window.durationMinutes,
                                 urgent: window.isCurrent(now: now) && (window.usedPercent >= 90 || window.forecast(now: now)?.exhaustsAt != nil))
        }
        return WidgetSnapshot(needsYou: items, working: working.map(\.project), limits: limits, updatedAt: now)
    }
}
