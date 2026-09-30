import Foundation

public enum SessionLiveness {
    /// Sessions with a live agent process: the exact process recorded by the bridge, or else, per folder,
    /// the most recent sessions up to the number of unclaimed agent processes there. A process hosts one session at a time.
    public static func running(_ sessions: [AgentSession], processes: [AgentProcess]) -> Set<String> {
        var running = Set<String>()
        var claimed = Set<Int>()
        for session in sessions where !session.ended {
            guard let pid = session.host?.pid else { continue }
            running.insert(session.id)
            claimed.insert(Int(pid))
        }
        var slots: [String: Int] = [:]
        for process in processes where !claimed.contains(process.id) {
            guard let cwd = process.cwd, cwd != "/" else { continue }
            slots["\(process.provider.rawValue):\(cwd)", default: 0] += 1
        }
        for session in sessions.sorted(by: { $0.updatedAt > $1.updatedAt }) where session.host?.pid == nil {
            let key = "\(session.provider.rawValue):\(session.cwd)"
            guard let free = slots[key], free > 0 else { continue }
            slots[key] = free - 1
            running.insert(session.id)
        }
        return running
    }
}
