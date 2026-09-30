import Foundation

public enum ClaudeConnection: Equatable {
    case notConnected
    case connected
    /// Warden entries exist but point to another helper path or miss a hook.
    case needsRepair
}

/// Adds or removes Warden's status line and hooks in Claude Code's user settings.
/// Other settings are preserved, and the file is backed up before every change.
public enum ClaudeInstaller {
    public static let hookEvents = ["UserPromptSubmit", "PermissionRequest", "Notification",
                                    "Stop", "StopFailure", "SessionEnd"]
    /// Events newer than the rest, with the Claude Code version that added them. Claude Code ignores a whole
    /// settings file that names an event it does not know, so these are added only for a version that has them.
    private static let introduced: [String: [Int]] = ["PermissionRequest": [2, 0, 45], "StopFailure": [2, 1, 78]]

    /// The events to connect for a Claude Code version such as "2.1.281". An unknown version gets the older events.
    public static func hookEvents(forVersion version: String?) -> [String] {
        let parts = version.map { $0.split(separator: ".").compactMap { Int($0.prefix { $0.isNumber }) } } ?? []
        return hookEvents.filter { event in
            guard let minimum = introduced[event] else { return true }
            return parts.count >= 3 && parts.lexicographicallyPrecedes(minimum) == false
        }
    }

    public static var defaultSettingsURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/settings.json")
    }

    /// Connected when the status line and exactly `events` run the bridge at `helper`. Missing events, or events
    /// the installed Claude Code does not know, need a repair.
    public static func status(helper: URL, settingsURL: URL = defaultSettingsURL,
                              events: [String] = hookEvents) -> ClaudeConnection {
        guard let root = try? readSettings(settingsURL) else { return .notConnected }
        let statusCommand = (root["statusLine"] as? [String: Any])?["command"] as? String
        let ownsStatus = statusCommand.map(isWardenStatus) ?? false
        let hooks = root["hooks"] as? [String: Any] ?? [:]
        let connected = hooks.keys.filter { !wardenCommands(in: hooks[$0]).isEmpty }
        if !ownsStatus && connected.isEmpty { return .notConnected }
        let prefix = quoted(helper) + " "
        let current = ownsStatus && statusCommand?.hasPrefix(prefix + "claude-status") == true
            && Set(connected) == Set(events)
            && events.allSatisfy { wardenCommands(in: hooks[$0]) == [prefix + "claude-event"] }
        return current ? .connected : .needsRepair
    }

    /// Connects or repairs Warden. A custom status line keeps running: the bridge executes it and prints its output.
    public static func install(helper: URL, settingsURL: URL = defaultSettingsURL, events: [String] = hookEvents) throws {
        guard FileManager.default.isExecutableFile(atPath: helper.path) else { throw InstallError.missingHelper }
        var root = try readSettings(settingsURL) ?? [:]
        let command = quoted(helper)

        var line = root["statusLine"] as? [String: Any] ?? ["type": "command"]
        var statusCommand = "\(command) claude-status"
        if let existing = line["command"] as? String {
            if isWardenStatus(existing) {
                if let chain = chainArgument(existing) { statusCommand += " --chain \(chain)" }
            } else if let data = try? JSONSerialization.data(withJSONObject: line, options: [.sortedKeys]) {
                statusCommand += " --chain \(data.base64EncodedString())"
            }
        }
        line["type"] = "command"
        line["command"] = statusCommand
        root["statusLine"] = line

        var hooks = removingWardenHooks(root["hooks"] as? [String: Any] ?? [:])
        for event in events {
            var groups = hooks[event] as? [[String: Any]] ?? []
            groups.append(["hooks": [["type": "command", "command": "\(command) claude-event"]]])
            hooks[event] = groups
        }
        root["hooks"] = hooks
        try write(root, to: settingsURL)
    }

    /// Removes Warden's hooks and restores the status line that was in place before connecting.
    public static func uninstall(settingsURL: URL = defaultSettingsURL) throws {
        guard var root = try readSettings(settingsURL) else { return }
        if let line = root["statusLine"] as? [String: Any], let command = line["command"] as? String, isWardenStatus(command) {
            if let chain = chainArgument(command), let data = Data(base64Encoded: chain),
               let original = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                root["statusLine"] = original
            } else {
                root.removeValue(forKey: "statusLine")
            }
        }
        let hooks = removingWardenHooks(root["hooks"] as? [String: Any] ?? [:])
        if hooks.isEmpty { root.removeValue(forKey: "hooks") } else { root["hooks"] = hooks }
        try write(root, to: settingsURL)
    }

    /// The status line command Warden runs after recording telemetry, decoded from `--chain`.
    public static func chainedCommand(_ argument: String) -> String? {
        guard let data = Data(base64Encoded: argument),
              let line = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        return line["command"] as? String
    }

    private static func isWardenStatus(_ command: String) -> Bool {
        command.contains("WardenBridge") && command.contains(" claude-status")
    }

    private static func isWardenEvent(_ command: String) -> Bool {
        command.contains("WardenBridge") && command.contains(" claude-event")
    }

    private static func chainArgument(_ command: String) -> String? {
        guard let range = command.range(of: " --chain ") else { return nil }
        let value = command[range.upperBound...].trimmingCharacters(in: .whitespaces)
        return value.isEmpty ? nil : value
    }

    private static func quoted(_ helper: URL) -> String {
        let path = helper.path.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "$", with: "\\$")
            .replacingOccurrences(of: "`", with: "\\`")
        return "\"\(path)\""
    }

    private static func wardenCommands(in groups: Any?) -> [String] {
        (groups as? [[String: Any]] ?? []).flatMap { group in
            (group["hooks"] as? [[String: Any]] ?? []).compactMap { $0["command"] as? String }.filter(isWardenEvent)
        }
    }

    private static func removingWardenHooks(_ hooks: [String: Any]) -> [String: Any] {
        var result: [String: Any] = [:]
        for (event, value) in hooks {
            guard let groups = value as? [[String: Any]] else { result[event] = value; continue }
            let kept = groups.compactMap { group -> [String: Any]? in
                guard let entries = group["hooks"] as? [[String: Any]] else { return group }
                let remaining = entries.filter { !(($0["command"] as? String).map(isWardenEvent) ?? false) }
                if remaining.count == entries.count { return group }
                if remaining.isEmpty { return nil }
                var copy = group
                copy["hooks"] = remaining
                return copy
            }
            if !kept.isEmpty { result[event] = kept }
        }
        return result
    }

    private static func readSettings(_ url: URL) throws -> [String: Any]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw InstallError.invalidSettings
        }
        return root
    }

    private static func write(_ root: [String: Any], to url: URL) throws {
        let manager = FileManager.default
        let folder = url.deletingLastPathComponent()
        try manager.createDirectory(at: folder, withIntermediateDirectories: true)
        if manager.fileExists(atPath: url.path) {
            let original = folder.appendingPathComponent("settings.warden-backup.json")
            if !manager.fileExists(atPath: original.path) { try manager.copyItem(at: url, to: original) }
            let previous = folder.appendingPathComponent("settings.warden-previous.json")
            try? manager.removeItem(at: previous)
            try manager.copyItem(at: url, to: previous)
        }
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: url, options: .atomic)
    }

    private enum InstallError: LocalizedError {
        case missingHelper
        case invalidSettings

        var errorDescription: String? {
            switch self {
            case .missingHelper: return "The Warden bridge is missing from the app bundle."
            case .invalidSettings: return "Claude's settings file is not valid JSON, so Warden left it unchanged."
            }
        }
    }
}
