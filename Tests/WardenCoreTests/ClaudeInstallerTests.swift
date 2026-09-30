import XCTest
@testable import WardenCore

final class ClaudeInstallerTests: XCTestCase {
    private var folder: URL!
    private var settings: URL!
    private var helper: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        settings = folder.appendingPathComponent("settings.json")
        helper = try makeHelper("Warden.app")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    func testConnectingKeepsUserSettingsAndDisconnectRestoresThem() throws {
        let original: [String: Any] = [
            "model": "opus",
            "statusLine": ["type": "command", "command": "~/.claude/statusline.sh", "padding": 2],
            "hooks": ["Stop": [["matcher": "", "hooks": [["type": "command", "command": "afplay done.aiff"]]]]]
        ]
        try JSONSerialization.data(withJSONObject: original).write(to: settings)

        try ClaudeInstaller.install(helper: helper, settingsURL: settings)
        var root = try read()
        let line = try XCTUnwrap(root["statusLine"] as? [String: Any])
        let command = try XCTUnwrap(line["command"] as? String)
        XCTAssertTrue(command.hasPrefix("\"\(helper.path)\" claude-status --chain "))
        XCTAssertEqual(ClaudeInstaller.chainedCommand(String(command.split(separator: " ").last!)), "~/.claude/statusline.sh")
        XCTAssertEqual(line["padding"] as? Int, 2)
        XCTAssertEqual(root["model"] as? String, "opus")
        XCTAssertEqual(stopCommands(root), ["afplay done.aiff", "\"\(helper.path)\" claude-event"])
        XCTAssertEqual(ClaudeInstaller.status(helper: helper, settingsURL: settings), .connected)
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("settings.warden-backup.json").path))

        // Connecting again from a moved app repairs the paths without duplicating hooks or the chain.
        let moved = try makeHelper("Moved/Warden.app")
        XCTAssertEqual(ClaudeInstaller.status(helper: moved, settingsURL: settings), .needsRepair)
        try ClaudeInstaller.install(helper: moved, settingsURL: settings)
        root = try read()
        XCTAssertEqual(stopCommands(root), ["afplay done.aiff", "\"\(moved.path)\" claude-event"])
        XCTAssertEqual(((root["statusLine"] as? [String: Any])?["command"] as? String)?.components(separatedBy: "--chain").count, 2)
        XCTAssertEqual(ClaudeInstaller.status(helper: moved, settingsURL: settings), .connected)

        try ClaudeInstaller.uninstall(settingsURL: settings)
        root = try read()
        XCTAssertEqual(NSDictionary(dictionary: root["statusLine"] as? [String: Any] ?? [:]),
                       NSDictionary(dictionary: original["statusLine"] as! [String: Any]))
        XCTAssertEqual(stopCommands(root), ["afplay done.aiff"])
        XCTAssertEqual((root["hooks"] as? [String: Any])?.keys.sorted(), ["Stop"])
        XCTAssertEqual(ClaudeInstaller.status(helper: moved, settingsURL: settings), .notConnected)
    }

    func testEventsAreConnectedOnlyForAClaudeCodeThatKnowsThem() throws {
        XCTAssertEqual(ClaudeInstaller.hookEvents(forVersion: "2.1.281"), ClaudeInstaller.hookEvents)
        XCTAssertEqual(ClaudeInstaller.hookEvents(forVersion: "2.1.50"),
                       ["UserPromptSubmit", "PermissionRequest", "Notification", "Stop", "SessionEnd"])
        XCTAssertEqual(ClaudeInstaller.hookEvents(forVersion: nil), ["UserPromptSubmit", "Notification", "Stop", "SessionEnd"])

        // An older Claude Code skips a settings file naming an event it does not know, so such a hook needs a repair.
        try ClaudeInstaller.install(helper: helper, settingsURL: settings)
        let older = ClaudeInstaller.hookEvents(forVersion: "2.1.50")
        XCTAssertEqual(ClaudeInstaller.status(helper: helper, settingsURL: settings, events: older), .needsRepair)
        try ClaudeInstaller.install(helper: helper, settingsURL: settings, events: older)
        XCTAssertEqual(ClaudeInstaller.status(helper: helper, settingsURL: settings, events: older), .connected)
        XCTAssertNil((try read()["hooks"] as? [String: Any])?["StopFailure"])
    }

    func testInvalidSettingsAreLeftUntouched() throws {
        let broken = Data("{ \"model\": ".utf8)
        try broken.write(to: settings)
        XCTAssertThrowsError(try ClaudeInstaller.install(helper: helper, settingsURL: settings))
        XCTAssertEqual(try Data(contentsOf: settings), broken)
    }

    func testHookCommandsRunTheLiteralHelperPath() throws {
        let helper = try makeHelper("Warden's $WARDEN_TEST_PATH `printf changed` \"preview\" \\.app")
        try Data("#!/bin/sh\nprintf '%s\\n' \"$1\"\n".utf8).write(to: helper)
        try ClaudeInstaller.install(helper: helper, settingsURL: settings)
        let root = try read()
        let status = try XCTUnwrap((root["statusLine"] as? [String: Any])?["command"] as? String)
        let event = try XCTUnwrap(stopCommands(root).first)

        for (command, argument) in [(status, "claude-status"), (event, "claude-event")] {
            let process = Process()
            let output = Pipe()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", command]
            process.environment = ["WARDEN_TEST_PATH": "expanded"]
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0)
            XCTAssertEqual(String(decoding: data, as: UTF8.self), argument + "\n")
        }
        XCTAssertEqual(ClaudeInstaller.status(helper: helper, settingsURL: settings), .connected)
    }

    private func makeHelper(_ app: String) throws -> URL {
        let url = folder.appendingPathComponent("\(app)/Contents/Helpers/WardenBridge")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    private func read() throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: settings)) as? [String: Any])
    }

    private func stopCommands(_ root: [String: Any]) -> [String] {
        let groups = (root["hooks"] as? [String: Any])?["Stop"] as? [[String: Any]] ?? []
        return groups.flatMap { ($0["hooks"] as? [[String: Any]] ?? []).compactMap { $0["command"] as? String } }
    }
}
