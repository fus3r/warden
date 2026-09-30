import Foundation
import WardenCore

/// Local requests to Warden's VS Code extension: process IDs and terminal tab names only.
enum EditorTerminalBridge {
    private static var folder: URL { WardenPaths.support.appendingPathComponent("editor-focus", isDirectory: true) }

    static func focus(pid: Int32) async -> Bool {
        guard FileManager.default.fileExists(atPath: folder.path) else { return false }
        let id = UUID().uuidString
        let request = folder.appendingPathComponent("\(id).json")
        let reply = folder.appendingPathComponent("\(id).done")
        defer {
            try? FileManager.default.removeItem(at: request)
            try? FileManager.default.removeItem(at: reply)
        }
        guard let data = try? JSONSerialization.data(withJSONObject: ["ancestors": ancestors(of: pid)]),
              (try? data.write(to: request, options: .atomic)) != nil else { return false }
        // Yield to the menu while the extension selects the terminal and raises its own window.
        for _ in 0..<20 {
            if FileManager.default.fileExists(atPath: reply.path) { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return false
    }

    /// Query all candidate terminals before selecting one, so identical titles in different windows
    /// cannot race to claim a click. Reading tab names does not read or type into terminal contents.
    static func terminalNames(for processes: [AgentProcess]) async -> [Int: String] {
        guard !processes.isEmpty, processes.count <= 32,
              FileManager.default.fileExists(atPath: folder.path) else { return [:] }
        let id = UUID().uuidString
        let request = folder.appendingPathComponent("\(id).json")
        var replies = Set<URL>()
        defer {
            try? FileManager.default.removeItem(at: request)
            for reply in replies { try? FileManager.default.removeItem(at: reply) }
        }
        let candidates: [[String: Any]] = processes.map { ["pid": $0.id, "ancestors": ancestors(of: Int32($0.id))] }
        guard let data = try? JSONSerialization.data(withJSONObject: ["terminals": candidates]),
              (try? data.write(to: request, options: .atomic)) != nil else { return [:] }
        let expected = Set(processes.map(\.id))
        var names: [Int: String] = [:]
        for _ in 0..<20 {
            let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.fileSizeKey])) ?? []
            for reply in files where reply.lastPathComponent.hasPrefix(id + ".") && reply.pathExtension == "terminals" {
                guard replies.insert(reply).inserted,
                      let size = try? reply.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 32_768,
                      let data = try? Data(contentsOf: reply),
                      let entries = try? JSONDecoder().decode([TerminalName].self, from: data) else { continue }
                for entry in entries where expected.contains(entry.pid) { names[entry.pid] = entry.name }
            }
            if Set(names.keys) == expected { return names }
            try? await Task.sleep(for: .milliseconds(50))
        }
        // A missing window could contain a duplicate title, so partial replies cannot identify a tab.
        return [:]
    }

    private struct TerminalName: Decodable {
        var pid: Int
        var name: String
    }

    private static func ancestors(of pid: Int32) -> [Int32] {
        var ancestors: [Int32] = []
        var current = pid
        for _ in 0..<16 where current > 1 {
            ancestors.append(current)
            guard let parent = ProcessDetails.parent(of: current), parent != current else { break }
            current = parent
        }
        return ancestors
    }
}
