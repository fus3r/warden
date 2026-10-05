import XCTest
@testable import WardenCore

final class RemoteSSHTests: XCTestCase {
    private func snapshot(inputPending: Bool = false, process: Bool = true) throws -> RemoteSnapshot {
        let meta = #"{"type":"session_meta","payload":{"id":"same-session","cwd":"/project","originator":"codex-tui"}}"#
        let started = #"{"timestamp":"2026-10-05T12:00:00Z","type":"event_msg","payload":{"type":"task_started"}}"#
        let tokens = #"{"type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":20000},"total_token_usage":{"total_tokens":31000},"model_context_window":100000}}}"#
        let data = try JSONSerialization.data(withJSONObject: [
            "version": 1, "observedAt": 1_791_201_600,
            "files": [["provider": "Codex", "filename": "same-session.jsonl", "accountFolder": "/home/me/.codex",
                       "modifiedAt": 1_791_201_600, "head": meta + "\n", "tail": "\n" + started + "\n" + tokens,
                       "pid": 123, "inputPending": inputPending, "tmux": ["session": "$1", "window": "@3", "pane": "%7"]]],
            "processes": process ? [["pid": 123, "provider": "Codex", "cwd": "/project"]] : [],
            "usage": [["provider": "Codex", "observedAt": 1_791_201_600,
                       "result": #"{"rateLimits":{"primary":{"usedPercent":31,"windowDurationMins":300,"resetsAt":1791220000}}}"#]]
        ])
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .secondsSince1970
        return try decoder.decode(RemoteSnapshot.self, from: data)
    }

    func testHostIdentityAndLinuxPIDCannotCollideWithLocalSessions() throws {
        let value = try snapshot()
        let date = value.observedAt.addingTimeInterval(300)
        let first = try XCTUnwrap(value.sessions(host: RemoteSSHHost(id: "a", destination: "first", name: "Cluster"), receivedAt: date).first)
        let second = try XCTUnwrap(value.sessions(host: RemoteSSHHost(id: "b", destination: "second"), receivedAt: date).first)
        XCTAssertNotEqual(first.id, second.id)
        XCTAssertNotEqual(first.id, "same-session")
        XCTAssertEqual(first.remote?.sessionID, "same-session")
        XCTAssertNil(first.host, "A Linux PID must never reach local process navigation or train-guard.")
        XCTAssertEqual(first.phase, .working)
        XCTAssertEqual(first.activityProject, "ssh://first/project")
        XCTAssertEqual(first.contextPercent, 20)
        XCTAssertEqual(first.updatedAt, date)
        let quota = try XCTUnwrap(value.windows(host: RemoteSSHHost(id: "a", destination: "first", name: "Cluster"), receivedAt: date).first)
        XCTAssertEqual(quota.account, "Cluster / Codex")
        XCTAssertTrue(quota.id.hasPrefix("ssh:a:"))
        XCTAssertEqual(quota.usedPercent, 31)
        XCTAssertEqual(quota.observedAt, date)
    }

    func testBlockingQuestionAndStaleWorkingLogHaveDifferentStates() throws {
        let pending = try snapshot(inputPending: true)
        XCTAssertEqual(pending.sessions(host: RemoteSSHHost(destination: "host"), receivedAt: pending.observedAt).first?.phase, .needsAttention)
        XCTAssertEqual(pending.sessions(host: RemoteSSHHost(destination: "host"), receivedAt: pending.observedAt).first?.attention, .choice)
        var stale = try snapshot(process: false)
        stale.observedAt = stale.observedAt.addingTimeInterval(180)
        XCTAssertEqual(stale.sessions(host: RemoteSSHHost(destination: "host"), receivedAt: stale.observedAt).first?.phase, .unknown)
    }

    func testSSHNavigationTargetsExistingTmuxPaneAndRejectsCommands() throws {
        let value = try snapshot()
        let session = try XCTUnwrap(value.sessions(host: RemoteSSHHost(destination: "cluster"), receivedAt: value.observedAt).first)
        let command = try XCTUnwrap(RemoteNavigation.tmuxCommand(for: session))
        XCTAssertTrue(command.contains("attach-session"))
        XCTAssertTrue(command.contains("%7"))
        XCTAssertFalse(command.contains("resume"))
        XCTAssertTrue(RemoteSSHHost.validDestination("user@server"))
        XCTAssertTrue(RemoteSSHHost.validDestination("ssh://user@127.0.0.1:2222"))
        XCTAssertFalse(RemoteSSHHost.validDestination("-oProxyCommand=touch"))
        XCTAssertFalse(RemoteSSHHost.validDestination("cluster; touch /tmp/file"))
        XCTAssertFalse(RemoteTmuxTarget(session: "$1", window: "@2", pane: "%3;ls").valid)
        var unavailable = session; unavailable.remote?.connected = false
        XCTAssertNil(RemoteNavigation.tmuxCommand(for: unavailable))
    }

    func testJumpHostAndTunnelCannotSelectTheWrongSSHTab() {
        XCTAssertEqual(RemoteNavigation.interactiveDestination(arguments: ["/usr/bin/ssh", "-J", "login", "compute"]), "compute")
        XCTAssertEqual(RemoteNavigation.interactiveDestination(arguments: ["ssh", "-p2222", "-i", "/test-key", "compute", "tmux", "attach"]), "compute")
        XCTAssertNil(RemoteNavigation.interactiveDestination(arguments: ["ssh", "-N", "-L", "2222:host:22", "login"]))
        XCTAssertNil(RemoteNavigation.interactiveDestination(arguments: ["ssh", "-T", "compute", "python3 -u -"]))
    }

    func testInteractiveAuthenticationAndScreenReattachUseTheSameSharedConnection() throws {
        let host = RemoteSSHHost(destination: "cluster")
        let path = "/private/warden ssh/approved.sock"
        let authenticate = try XCTUnwrap(RemoteNavigation.authenticationCommand(host: host, controlPath: path))
        XCTAssertTrue(authenticate.contains("ControlMaster=auto"))
        XCTAssertTrue(authenticate.contains("BatchMode=no"))
        XCTAssertFalse(host.monitoringArguments.contains("ControlPath=none"), "Monitoring must honor an existing configured SSH master.")
        XCTAssertTrue(host.monitoringArguments.contains("BatchMode=yes"), "Only the interactive terminal can request MFA.")
        var session = try XCTUnwrap(snapshot().sessions(host: host).first)
        session.remote?.screen = RemoteScreenTarget(session: "123.training")
        let command = try XCTUnwrap(RemoteNavigation.screenCommand(for: session, controlPath: path))
        XCTAssertTrue(command.contains(SessionNavigation.shellQuote(path)))
        XCTAssertTrue(command.contains("screen -x -p"))
        XCTAssertFalse(command.contains("-R"), "Screen navigation must never create another session.")
        XCTAssertFalse(RemoteScreenTarget(session: "123.training; touch /tmp/marker").valid)
        session.remote?.connected = false
        XCTAssertNil(RemoteNavigation.screenCommand(for: session, controlPath: path))
    }

    func testClaudeWorkerLogWithParentSessionIDDoesNotReplaceTheParentRow() throws {
        let user = #"{"type":"user","sessionId":"parent","cwd":"/project","message":{"content":""}}"#
        let done = #"{"type":"assistant","sessionId":"parent","cwd":"/project","message":{"model":"claude-sonnet-4-5","stop_reason":"end_turn","content":[]}}"#
        let worker = #"{"type":"assistant","sessionId":"parent","cwd":"/project","message":{"model":"claude-sonnet-4-5","stop_reason":"tool_use","content":[{"type":"tool_use","name":"Bash"}]}}"#
        let data = try JSONSerialization.data(withJSONObject: [
            "version": 1, "observedAt": 10000, "processes": [], "usage": [],
            "files": [["provider": "Claude", "filename": "parent.jsonl", "accountFolder": "/home/me/.claude", "modifiedAt": 9999,
                       "head": user + "\n", "tail": "\n" + done],
                      ["provider": "Claude", "filename": "agent-worker.jsonl", "parentID": "parent", "accountFolder": "/home/me/.claude", "modifiedAt": 10000,
                       "head": user + "\n", "tail": "\n" + worker]]
        ])
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .secondsSince1970
        let value = try decoder.decode(RemoteSnapshot.self, from: data)
        let sessions = value.sessions(host: RemoteSSHHost(destination: "cluster"), receivedAt: value.observedAt)
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions.first?.remote?.sessionID, "parent")
        XCTAssertEqual(sessions.first?.activeSubagents, 1)
        XCTAssertEqual(sessions.first?.phase, .working)
    }
}
