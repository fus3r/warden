import XCTest
@testable import Warden
import WardenCore

final class TelemetryScannerTests: XCTestCase {
    func testToolSidecarServerIsNotAnotherCodexTerminalAgent() {
        // Codex's computer-use tools start this server beneath the TUI, on the same TTY and cwd.
        XCTAssertTrue(TelemetryScanner.isCodexService(["codex", "app-server", "--listen", "stdio"]))
        XCTAssertFalse(TelemetryScanner.isCodexService(["codex", "resume", "3f5d880f-7ac4-42a9-a018-1c46a219eabf"]))
    }

    func testStoppedAccountDoesNotReturnBridgeSessionsOrSavedLimits() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let previous = ProcessInfo.processInfo.environment["WARDEN_SUPPORT_DIR"]
        setenv("WARDEN_SUPPORT_DIR", root.path, 1)
        defer {
            if let previous { setenv("WARDEN_SUPPORT_DIR", previous, 1) }
            else { unsetenv("WARDEN_SUPPORT_DIR") }
            try? FileManager.default.removeItem(at: root)
        }
        guard WardenPaths.support.standardizedFileURL.path == root.standardizedFileURL.path else {
            throw XCTSkip("The scanner fixture requires debug storage isolation.")
        }
        let defaults = UserDefaults.standard
        let previousUsage = defaults.object(forKey: "codexAccountUsage")
        defaults.set(false, forKey: "codexAccountUsage")
        defer {
            if let previousUsage { defaults.set(previousUsage, forKey: "codexAccountUsage") }
            else { defaults.removeObject(forKey: "codexAccountUsage") }
        }
        try FileManager.default.createDirectory(at: WardenPaths.statusDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: WardenPaths.eventDirectory, withIntermediateDirectories: true)
        let now = Date()
        let codex = AgentAccount(provider: .codex, folder: root.appendingPathComponent("codex"), name: nil)
        let kept = UsageWindow(id: "Codex-primary", provider: .codex, label: "5h", usedPercent: 20,
                               resetsAt: now.addingTimeInterval(3600), observedAt: now, evidence: .provider)
        let removed = UsageWindow(id: "Claude-work-five_hour", provider: .claude, label: "5h", usedPercent: 95,
                                  resetsAt: now.addingTimeInterval(3600), observedAt: now, evidence: .provider, account: "work")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode([kept, removed]).write(to: WardenPaths.usageFile)
        let status = BridgeStatus(sessionID: "s-work", cwd: "/tmp/app", model: nil, contextPercent: nil,
                                  totalTokens: nil, windows: [removed], updatedAt: now, account: "work")
        try encoder.encode(status).write(to: WardenPaths.statusDirectory.appendingPathComponent("s-work.json"))
        let event = BridgeEvent(id: "e-work", sessionID: "s-hook-only", cwd: "/tmp/app", kind: "working", at: now, account: "work")
        try encoder.encode(event).write(to: WardenPaths.eventDirectory.appendingPathComponent("s-hook-only.json"))

        // The work account was removed, but its installed hook and last saved limits remain on disk.
        let result = TelemetryScanner().scan(accounts: [codex])
        XCTAssertTrue(result.sessions.isEmpty, "A removed account's bridge must not recreate its session.")
        XCTAssertEqual(result.windows.map(\.id), [kept.id])
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let saved = try decoder.decode([UsageWindow].self, from: Data(contentsOf: WardenPaths.usageFile))
        XCTAssertEqual(saved.map(\.id), [kept.id], "WardenBridge status must also stop reporting the removed limits.")
        XCTAssertEqual(TelemetryScanner().scan(accounts: [codex]).windows.map(\.id), [kept.id],
                       "The removed limits must stay hidden after relaunch.")
    }
}
