import Darwin
import Foundation
import WardenCore

enum CodexSessionControl {
    struct Owner: Equatable, Sendable {
        let pid: Int32
        let startedAt: Double
    }

    /// A process is eligible only when it owns this rollout for writing and has no other open rollout writer.
    static func owner(of file: URL, among pids: [Int]) -> Owner? {
        let candidates = pids.compactMap { value -> Owner? in
            guard let pid = Int32(exactly: value), pid > 1, ProcessDetails.name(of: pid) == "codex",
                  let startedAt = ProcessDetails.startTime(of: pid),
                  let arguments = ProcessDetails.arguments(of: pid), !arguments.isEmpty,
                  !TelemetryScanner.isCodexService(arguments),
                  !arguments.dropFirst().contains(where: { ["app-server", "exec-server", "mcp-server"].contains($0) })
            else { return nil }
            return Owner(pid: pid, startedAt: startedAt)
        }
        let files = SessionNavigator.openTranscripts(pids: candidates.map { Int($0.pid) }, fields: "pfan", requireComplete: true)
        guard let pid = uniqueWriter(of: file, in: files),
              let owner = candidates.first(where: { $0.pid == pid }),
              ProcessDetails.startTime(of: pid) == owner.startedAt else { return nil }
        return owner
    }

    static func uniqueWriter(of file: URL, in report: String) -> Int32? {
        let path = file.resolvingSymlinksInPath().path
        var writes: [Int32: Set<String>] = [:]
        var pid: Int32?
        var writable = false
        for line in report.split(separator: "\n") {
            let value = line.dropFirst()
            switch line.first {
            case "p":
                pid = Int32(value)
                writable = false
            case "f":
                writable = false
            case "a":
                writable = value == "w" || value == "u"
            case "n":
                guard writable, let pid, value.hasPrefix("/") else { continue }
                let url = URL(fileURLWithPath: String(value))
                guard url.pathExtension == "jsonl", url.lastPathComponent.hasPrefix("rollout-") else { continue }
                writes[pid, default: []].insert(url.resolvingSymlinksInPath().path)
            default: break
            }
        }
        let matches = writes.filter { $0.value.contains(path) }
        guard matches.count == 1, let (pid, paths) = matches.first, paths.count == 1 else { return nil }
        return pid
    }

    static func forceQuit(_ confirmed: Owner, file: URL, among pids: [Int]) -> Bool {
        // The terminal may have changed conversations or exited while the confirmation was open.
        guard owner(of: file, among: pids) == confirmed,
              ProcessDetails.startTime(of: confirmed.pid) == confirmed.startedAt else { return false }
        return Darwin.kill(confirmed.pid, SIGKILL) == 0
    }
}
