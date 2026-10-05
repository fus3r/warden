import XCTest
@testable import Warden
import WardenCore

final class RemoteConnectionTests: XCTestCase {
    func testDisconnectDoesNotTurnWorkIntoCompletionOrFocusALocalProcess() async throws {
        await MainActor.run {
            var session = AgentSession(id: "ssh:host:Codex:s", provider: .codex, surface: "SSH", cwd: "/project", phase: .working, updatedAt: Date())
            session.remote = RemoteSessionOrigin(host: RemoteSSHHost(id: "host", destination: "cluster"), sessionID: "s", accountFolder: "/home/me/.codex")
            let missing = RemoteConnections.unavailable(session)
            XCTAssertEqual(missing.phase, .unknown)
            XCTAssertNil(missing.attention)
            XCTAssertEqual(missing.remote?.connected, false)
            XCTAssertNil(SessionNavigator.hostBundleID(for: missing, processes: [AgentProcess(id: 123, provider: .codex, surface: "Terminal", cwd: "/project", hostBundleID: "com.apple.Terminal")]))
            let engine = AlertEngine(sounds: SoundLibrary())
            var events: [AutomationEvent] = []
            engine.onEvent = { events.append($0) }
            engine.process(sessions: [missing], previous: [session.id: session], windows: [], previousWindows: [:], styles: [:], mode: .all, snoozed: true)
            XCTAssertTrue(events.isEmpty, "Losing SSH is not a provider completion event.")
        }
    }

    func testHostConfigurationPersistsWithoutOverwritingUnreadableOwnerData() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try await MainActor.run {
            let path = root.appendingPathComponent("hosts.json")
            let connections = RemoteConnections(storage: path, collector: nil)
            XCTAssertTrue(connections.add(destination: "cluster", name: "Lab"))
            XCTAssertFalse(connections.add(destination: "cluster", name: "Duplicate"))
            let restored = RemoteConnections(storage: path, collector: nil)
            let host = try XCTUnwrap(restored.hosts.first)
            XCTAssertEqual(host.name, "Lab")
            restored.setEnabled(false, host: host)
            XCTAssertFalse(try XCTUnwrap(RemoteConnections(storage: path, collector: nil).hosts.first).enabled)
            let corrupt = Data("owner data with an unsupported format".utf8)
            try corrupt.write(to: path)
            let unreadable = RemoteConnections(storage: path, collector: nil)
            XCTAssertNotNil(unreadable.storageError)
            XCTAssertFalse(unreadable.add(destination: "another", name: ""))
            XCTAssertEqual(try Data(contentsOf: path), corrupt)
        }
    }

    /// Run through Scripts/verify-remote-ssh.py: a real Linux OpenSSH server with isolated keys and fixture agents.
    func testLinuxSSHTransportReconnectAndRemovingMonitoringKeepsAgentsAlive() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let config = env["WARDEN_SSH_TEST_CONFIG"], let container = env["WARDEN_SSH_TEST_CONTAINER"] else {
            throw XCTSkip("Run Scripts/verify-remote-ssh.py for the isolated Linux SSH integration test.")
        }
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let storage = FileManager.default.temporaryDirectory.appendingPathComponent("warden-ssh-" + UUID().uuidString + ".json")
        let connections = await MainActor.run {
            RemoteConnections(storage: storage, collector: source.appendingPathComponent("Resources/Remote/warden-remote.py"), configuration: URL(fileURLWithPath: config))
        }
        defer { Task { @MainActor in connections.shutdown() } }
        defer { try? FileManager.default.removeItem(at: storage) }
        await MainActor.run { _ = connections.add(destination: "warden-qa", name: "Ubuntu QA"); connections.start() }
        _ = await waitUntil { connections.states.values.first?.message != nil || (connections.states.values.first?.phase == .connected && connections.windows.count >= 2) }
        let ready = await MainActor.run { connections.states.values.first?.phase == .connected && connections.windows.count >= 2 }
        let diagnostic = await MainActor.run { connections.states.values.first?.message ?? "No snapshot or quota reply" }
        guard ready else { throw NSError(domain: "SSHIntegration", code: 1, userInfo: [NSLocalizedDescriptionKey: diagnostic]) }
        await MainActor.run {
            XCTAssertEqual(Set(connections.sessions.map(\.provider)), [.claude, .codex])
            XCTAssertTrue(connections.sessions.allSatisfy { $0.remote?.tmux != nil && $0.host == nil })
            XCTAssertTrue(connections.sessions.contains { $0.phase == .needsAttention && $0.attention == .choice })
        }
        try docker(["stop", "-t", "0", container])
        let disconnected = await waitUntil { connections.states.values.first?.phase == .reconnecting }
        XCTAssertTrue(disconnected)
        await MainActor.run {
            XCTAssertTrue(connections.sessions.allSatisfy { $0.phase == .unknown && $0.remote?.connected == false })
            XCTAssertTrue(connections.hasUncertainWork)
        }
        try docker(["start", container])
        try await Task.sleep(nanoseconds: 2_000_000_000)
        try docker(["exec", container, "tmux", "new-session", "-d", "-s", "agents", "-c", "/project", "/root/.local/bin/codex 97d66436-6ead-4aab-8888-097d81e4de11"])
        try docker(["exec", container, "tmux", "split-window", "-h", "-t", "agents", "-c", "/project", "/root/.local/bin/claude 5aa6c736-08b1-4f57-9999-997d81e4de22"])
        await MainActor.run { if let host = connections.hosts.first { connections.retry(host) } }
        let reconnected = await waitUntil { connections.states.values.first?.phase == .connected }
        XCTAssertTrue(reconnected)
        if let path = env["WARDEN_SSH_TEST_COMMAND"] {
            let target = await MainActor.run { connections.sessions.first { $0.provider == .codex } }
            let session = try XCTUnwrap(target)
            let command = try XCTUnwrap(RemoteNavigation.tmuxCommand(for: session))
            let pane = try XCTUnwrap(session.remote?.tmux?.pane)
            try JSONSerialization.data(withJSONObject: ["command": command, "pane": pane]).write(to: URL(fileURLWithPath: path))
        }
        // Existing account-usage preferences also apply to a newly launched remote collector.
        let keys = ["codexAccountUsage", "claudeAccountUsage"]
        let saved = keys.map { UserDefaults.standard.object(forKey: $0) }
        defer {
            for (key, value) in zip(keys, saved) {
                if let value { UserDefaults.standard.set(value, forKey: key) }
                else { UserDefaults.standard.removeObject(forKey: key) }
            }
        }
        keys.forEach { UserDefaults.standard.set(false, forKey: $0) }
        await MainActor.run { connections.refreshUsagePreferences() }
        let optedOut = await waitUntil { connections.states.values.first?.phase == .connected && connections.windows.isEmpty }
        XCTAssertTrue(optedOut, "Turning CLI usage reads off must also stop remote CLI quota queries.")
        await MainActor.run { XCTAssertEqual(connections.sessions.count, 2) }
        await MainActor.run {
            if let host = connections.hosts.first { connections.remove(host) }
            XCTAssertTrue(connections.sessions.isEmpty)
            connections.shutdown()
        }
        try docker(["exec", container, "tmux", "has-session", "-t", "agents"])
    }

    @MainActor private func waitUntil(_ condition: @MainActor () -> Bool) async -> Bool {
        for _ in 0..<160 {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        return false
    }

    private func docker(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/local/bin/docker")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        try process.run(); process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
    }
}
