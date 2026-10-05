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

    /// No live MFA service is contacted. Revoking the disposable key proves monitoring borrows approved transport.
    func testLinuxSSHWithInteractiveAuthenticationExpiryAndScreen() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let config = env["WARDEN_SSH_TEST_CONFIG"], let container = env["WARDEN_SSH_TEST_CONTAINER"] else {
            throw XCTSkip("Run Scripts/verify-remote-ssh.py for shared-authentication and screen checks.")
        }
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let root = URL(fileURLWithPath: "/tmp/warden-auth-" + UUID().uuidString.prefix(8))
        let connections = await MainActor.run {
            RemoteConnections(storage: root.appendingPathComponent("hosts.json"), collector: source.appendingPathComponent("Resources/Remote/warden-remote.py"), configuration: URL(fileURLWithPath: config))
        }
        await MainActor.run { _ = connections.add(destination: "warden-qa", name: "MFA fixture"); connections.start() }
        defer { Task { @MainActor in connections.shutdown() } }
        let host = try await MainActor.run { try XCTUnwrap(connections.hosts.first) }
        let control = await MainActor.run { connections.controlPath(for: host) }
        let command = try await MainActor.run { try XCTUnwrap(connections.authenticationCommand(for: host)) }
        defer {
            try? ssh(config: config, control: control.path, arguments: ["-O", "exit", "warden-qa"])
            try? FileManager.default.removeItem(at: root)
        }
        let permissions = try FileManager.default.attributesOfItem(atPath: control.deletingLastPathComponent().path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o700)
        XCTAssertNotEqual(control, RemoteSSHAuthentication.controlPath(hostID: host.id, destination: "different", root: root))
        let ready = await waitUntil { connections.states[host.id]?.phase == .connected }
        XCTAssertTrue(ready)
        try authenticate(command)
        XCTAssertNotNil(RemoteSSHAuthentication.socketIdentity(control))
        try docker(["exec", container, "mv", "/root/.ssh/authorized_keys", "/root/.ssh/authorized_keys.qa-backup"])
        defer {
            try? docker(["exec", container, "python3", "-c", "from pathlib import Path; p=Path('/root/.ssh/authorized_keys.qa-backup'); p.exists() and p.rename('/root/.ssh/authorized_keys')"])
        }
        await MainActor.run { connections.retry(host) }
        let shared = await waitUntil { connections.states[host.id]?.phase == .connected }
        XCTAssertTrue(shared, "Monitoring must work over the approved connection with its login key revoked.")
        try ssh(config: config, control: control.path, arguments: ["-O", "exit", "warden-qa"])
        let lost = await waitUntil { connections.states[host.id]?.phase == .reconnecting }
        XCTAssertTrue(lost)
        await MainActor.run { connections.retry(host) }
        let expired = await waitUntil { connections.states[host.id]?.phase == .authenticationRequired }
        XCTAssertTrue(expired)
        await MainActor.run {
            XCTAssertNil(connections.states[host.id]?.retryAt, "Do not keep trying authentication while phone approval is needed.")
            XCTAssertTrue(connections.sessions.allSatisfy { $0.phase == .unknown && $0.remote?.connected == false })
            XCTAssertTrue(connections.hasUncertainWork)
        }
        try docker(["exec", container, "mv", "/root/.ssh/authorized_keys.qa-backup", "/root/.ssh/authorized_keys"])
        try authenticate(command)
        let resumed = await waitUntil { connections.states[host.id]?.phase == .connected }
        XCTAssertTrue(resumed, "Monitoring resumes when manual sign-in creates the approved shared connection.")

        // An old log in a still-running screen job must also survive a fresh collector after reauthentication.
        let identity = "86d66237-6ead-4aab-8888-097d81e4de33"
        let fixture = """
        import json,pathlib,os,time
        pathlib.Path('/screen-project').mkdir(exist_ok=True)
        path=pathlib.Path('/root/.codex/sessions/2026/10/05/\(identity).jsonl')
        old=time.time()-36*3600
        entries=[{'type':'session_meta','payload':{'id':'\(identity)','cwd':'/screen-project','originator':'codex-tui'}},{'timestamp':time.strftime('%Y-%m-%dT%H:%M:%SZ',time.gmtime(old)),'type':'event_msg','payload':{'type':'task_started'}}]
        path.write_text('\\n'.join(map(json.dumps,entries))+'\\n')
        os.utime(path,(old,old))
        """
        try docker(["exec", container, "python3", "-c", fixture])
        try docker(["exec", "-w", "/screen-project", container, "screen", "-dmS", "long-run", "-t", "coding", "/root/.local/bin/codex"])
        await MainActor.run { connections.retry(host) }
        let screen = await waitUntil { connections.sessions.contains { $0.remote?.sessionID == identity && $0.remote?.screen != nil } }
        XCTAssertTrue(screen)
        let target = try await MainActor.run { try XCTUnwrap(connections.sessions.first { $0.remote?.sessionID == identity }) }
        XCTAssertEqual(target.phase, .working)
        XCTAssertNil(target.host)
        if let artifact = env["WARDEN_SSH_TEST_COMMAND"] {
            let destination = URL(fileURLWithPath: artifact).deletingLastPathComponent().appendingPathComponent("screen-command.json")
            let command = try XCTUnwrap(RemoteNavigation.screenCommand(for: target))
            let session = try XCTUnwrap(target.remote?.screen?.session)
            try JSONSerialization.data(withJSONObject: ["command": command, "session": session]).write(to: destination)
        }
        await MainActor.run { connections.remove(host); connections.shutdown() }
        try ssh(config: config, control: control.path, arguments: ["-O", "check", "warden-qa"])
        try docker(["exec", container, "screen", "-S", "long-run", "-Q", "windows"])
    }

    private func authenticate(_ command: String) throws {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "exec " + command + " 'true'"]
        task.standardInput = FileHandle.nullDevice
        task.standardOutput = FileHandle.nullDevice
        try task.run(); task.waitUntilExit()
        XCTAssertEqual(task.terminationStatus, 0)
    }

    private func ssh(config: String, control: String, arguments: [String]) throws {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        task.arguments = ["-F", config, "-S", control] + arguments
        task.standardOutput = FileHandle.nullDevice
        try task.run(); task.waitUntilExit()
        XCTAssertEqual(task.terminationStatus, 0)
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
