import Foundation

/// One session from `claude agents --json`, Claude Code's supported way to read session state from outside it.
public struct AgentViewEntry: Equatable {
    public var sessionID: String?
    /// Short id of a background session, which `claude attach` takes.
    public var backgroundID: String?
    public var pid: Int32?
    public var isBackground: Bool
    /// `busy`, `waiting`, or `idle` while the process lives.
    public var status: String?
    /// What a waiting session is blocked on, such as `permission prompt` or `dialog open`.
    public var waitingFor: String?
    /// A background session's `working`, `blocked`, `done`, `failed`, or `stopped`.
    public var state: String?
    public var name: String?
    public var cwd: String

    /// Blocked on you: an open prompt in a live process, or a background session that cannot continue alone.
    public var isWaiting: Bool { status == "waiting" || state == "blocked" }
    public var isBusy: Bool { status == "busy" || (status == nil && state == "working") }
}

public enum ClaudeAgentView {
    public static func entries(_ data: Data) -> [AgentViewEntry] {
        guard let list = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return [] }
        return list.compactMap { entry in
            guard let cwd = entry["cwd"] as? String else { return nil }
            return AgentViewEntry(sessionID: entry["sessionId"] as? String, backgroundID: entry["id"] as? String,
                                  pid: (entry["pid"] as? NSNumber).map { Int32(truncating: $0) },
                                  isBackground: entry["kind"] as? String == "background",
                                  status: entry["status"] as? String, waitingFor: entry["waitingFor"] as? String,
                                  state: entry["state"] as? String, name: entry["name"] as? String, cwd: cwd)
        }
    }

    /// Adds what the reading knows and the log cannot show: the session's process, and waits such as a sandbox
    /// request, an open dialog, or a blocked background session. A log that moved on since the reading wins.
    public static func merge(_ session: AgentSession, entry: AgentViewEntry, readAt: Date) -> AgentSession {
        var result = session
        if result.host?.pid == nil, let pid = entry.pid {
            result.host = SessionHost(pid: pid, tty: result.host?.tty, bundleID: result.host?.bundleID,
                                      termProgram: result.host?.termProgram)
        }
        if entry.isBackground { result.backgroundID = entry.backgroundID }
        guard !session.ended, session.updatedAt <= readAt.addingTimeInterval(2) else { return result }
        if entry.isWaiting, session.phase != .needsAttention {
            result.phase = .needsAttention
            result.phaseEvidence = .provider
            switch entry.waitingFor {
            case "permission prompt": (result.attention, result.detail) = (.permission, nil)
            case "input needed": (result.attention, result.detail) = (.question, nil)
            case "sandbox request": (result.attention, result.detail) = (.permission, "sandbox access")
            case "worker request": (result.attention, result.detail) = (.permission, "a subagent's request")
            case "dialog open": (result.attention, result.detail) = (.notification, "A dialog is open")
            default: (result.attention, result.detail) = (.notification, "Blocked until you answer")
            }
        } else if entry.isBusy, session.phase != .working {
            // Busy after the log's last word: a prompt answered in the terminal, whose tool may run for minutes
            // before the log moves, or a turn resumed after a stop. After a turn that ended, a command the session
            // started in the background still runs.
            result.phase = .working
            result.phaseEvidence = .provider
            result.attention = nil
            result.detail = nil
            result.busyInBackground = session.phase == .finished
        } else if entry.status == "idle", session.phase == .working, readAt.timeIntervalSince(session.updatedAt) >= 60 {
            // Back at its prompt, though the log's last entry left a turn open, as a refused reply can.
            result.phase = .idle
            result.phaseEvidence = .provider
        }
        return result
    }
}
