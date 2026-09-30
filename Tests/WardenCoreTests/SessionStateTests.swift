import XCTest
@testable import WardenCore

/// States from event sequences seen in this Mac's logs between Claude Code 2.1.261 and 2.1.283 and Codex 0.153 and 0.157.
final class SessionStateTests: XCTestCase {
    private func claude(_ lines: [String], id: String) throws -> AgentSession {
        let data = Data(lines.joined(separator: "\n").appending("\n").utf8)
        return try XCTUnwrap(TelemetryParser.claude(head: data, tail: Data("\n".utf8) + data, filename: "\(id).jsonl", modifiedAt: Date()))
    }

    func testARefusedReplyEndsTheTurnAndWaitsForYou() throws {
        let session = try claude([
            #"{"parentUuid":null,"isSidechain":false,"promptId":"p1","type":"user","message":{"role":"user","content":"Continue"},"uuid":"u1","timestamp":"2026-09-22T20:40:00.000Z","entrypoint":"cli","cwd":"/tmp/q","sessionId":"s-c"}"#,
            #"{"parentUuid":"u1","isSidechain":false,"message":{"model":"claude-fable-5-1","role":"assistant","stop_reason":"tool_use","content":[{"type":"tool_use","id":"toolu_1","name":"Bash","input":{"command":"ls"}}],"usage":{"input_tokens":2}},"type":"assistant","uuid":"a1","timestamp":"2026-09-22T20:45:20.100Z","cwd":"/tmp/q","sessionId":"s-c"}"#,
            #"{"parentUuid":"a1","isSidechain":false,"promptId":"p1","type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_1","content":"ok"}]},"uuid":"u2","timestamp":"2026-09-22T20:45:21.782Z","cwd":"/tmp/q","sessionId":"s-c"}"#,
            #"{"parentUuid":"u2","isSidechain":false,"message":{"model":"claude-fable-5-1","role":"assistant","stop_reason":"refusal","content":[{"type":"thinking","thinking":""}],"usage":{"input_tokens":2}},"type":"assistant","uuid":"a2","timestamp":"2026-09-22T20:45:37.314Z","cwd":"/tmp/q","sessionId":"s-c"}"#,
            #"{"parentUuid":"a2","isSidechain":false,"type":"system","subtype":"informational","content":"<notice>","level":"notice","timestamp":"2026-09-22T20:45:37.323Z","isMeta":false,"cwd":"/tmp/q","sessionId":"s-c"}"#,
            #"{"parentUuid":"a2","isSidechain":false,"promptId":"p1","type":"user","message":{"role":"user","content":"<meta>"},"isMeta":true,"uuid":"u3","timestamp":"2026-09-22T20:45:37.323Z","cwd":"/tmp/q","sessionId":"s-c"}"#
        ], id: "s-c")
        XCTAssertEqual(session.phase, .needsAttention)
        XCTAssertEqual(session.attention, .failure)
        XCTAssertEqual(session.detail, "refusal")
    }

    func testClaudeCodesOwnReplyDoesNotEndAWaitForALimitReset() throws {
        let session = try claude([
            #"{"parentUuid":null,"isSidechain":false,"promptId":"p1","type":"user","message":{"role":"user","content":"Run the audit"},"uuid":"u1","timestamp":"2026-09-22T13:40:00.000Z","entrypoint":"cli","cwd":"/tmp/c","sessionId":"s-d"}"#,
            #"{"parentUuid":"u1","isSidechain":false,"type":"assistant","uuid":"a1","timestamp":"2026-09-22T13:57:44.710Z","error":"rate_limit","isApiErrorMessage":true,"apiErrorStatus":429,"quotaLimits":{"status":"rejected","resetsAt":1790265600,"rateLimitType":"five_hour"},"cwd":"/tmp/c","sessionId":"s-d","message":{"id":"m1","model":"<synthetic>","role":"assistant","stop_reason":"stop_sequence","content":[{"type":"text","text":"You've hit your limit"}],"usage":{"input_tokens":0,"output_tokens":0}}}"#,
            #"{"parentUuid":"a1","isSidechain":false,"type":"system","subtype":"informational","content":"Usage limit reached · continuing automatically at 3:50pm · esc or type to cancel","level":"notice","timestamp":"2026-09-22T13:57:44.737Z","isMeta":false,"cwd":"/tmp/c","sessionId":"s-d"}"#,
            #"{"parentUuid":"a1","isSidechain":false,"promptId":"p2","type":"user","message":{"role":"user","content":[{"type":"text","text":"<meta>"}]},"isMeta":true,"uuid":"u2","timestamp":"2026-09-22T14:27:38.346Z","cwd":"/tmp/c","sessionId":"s-d"}"#,
            #"{"parentUuid":"u2","isSidechain":false,"type":"assistant","uuid":"a2","timestamp":"2026-09-22T14:27:38.346Z","isApiErrorMessage":false,"cwd":"/tmp/c","sessionId":"s-d","message":{"id":"m2","model":"<synthetic>","role":"assistant","stop_reason":"stop_sequence","content":[{"type":"text","text":"No response requested."}],"usage":{"input_tokens":0,"output_tokens":0}}}"#,
            #"{"parentUuid":"a2","isSidechain":false,"promptId":"p3","type":"user","message":{"role":"user","content":"<command-name>/effort</command-name>\n<command-message>effort</command-message>\n<command-args>low</command-args>"},"uuid":"u3","timestamp":"2026-09-22T14:27:40.986Z","cwd":"/tmp/c","sessionId":"s-d"}"#
        ], id: "s-d")
        XCTAssertEqual(session.resumesAt, Date(timeIntervalSince1970: 1790265600))
        XCTAssertEqual(session.phase, .working)
    }

    func testAPromptAnsweredInTheTerminalWorksWhileItsToolRuns() throws {
        let asked = Date(timeIntervalSince1970: 1_790_400_001)
        let session = AgentSession(id: "s-e", provider: .claude, surface: "Terminal", cwd: "/tmp/w", phase: .working,
                                   updatedAt: asked.addingTimeInterval(-1))
        let waiting = TelemetryParser.merge(session, status: nil, event: BridgeEvent(id: "e1", sessionID: "s-e", cwd: "/tmp/w",
                                                                                      kind: "permission", at: asked, detail: "Bash"))
        XCTAssertEqual(waiting.attention, .permission)
        // Approved at once; the command runs for minutes and nothing reaches the log. Claude Code's list says busy.
        let busy = ClaudeAgentView.entries(Data(#"[{"pid":4242,"cwd":"/tmp/w","kind":"interactive","sessionId":"s-e","status":"busy"}]"#.utf8))[0]
        let running = ClaudeAgentView.merge(waiting, entry: busy, readAt: asked.addingTimeInterval(60))
        XCTAssertEqual(running.phase, .working)
        XCTAssertNil(running.attention)
        XCTAssertFalse(running.busyInBackground)
        // A list read before the prompt says nothing about it.
        XCTAssertEqual(ClaudeAgentView.merge(waiting, entry: busy, readAt: asked.addingTimeInterval(-5)).attention, .permission)
        // Back at its prompt a minute after a turn the log left open.
        let idle = ClaudeAgentView.entries(Data(#"[{"pid":4242,"cwd":"/tmp/w","kind":"interactive","sessionId":"s-e","status":"idle"}]"#.utf8))[0]
        XCTAssertEqual(ClaudeAgentView.merge(running, entry: idle, readAt: asked.addingTimeInterval(200)).phase, .idle)
    }

    func testATurnThatEndedStaysBusyWhileItsBackgroundCommandRuns() throws {
        // The turn started a command in the background and ended; Claude Code still calls the session busy a day later.
        let parsed = try claude([
            #"{"parentUuid":null,"isSidechain":false,"promptId":"p1","type":"user","message":{"role":"user","content":"Watch the job"},"uuid":"u1","timestamp":"2026-09-26T12:31:11.000Z","entrypoint":"cli","cwd":"/tmp/q","sessionId":"s-g"}"#,
            #"{"parentUuid":"u1","isSidechain":false,"message":{"model":"claude-opus-5-5","role":"assistant","stop_reason":"tool_use","content":[{"type":"tool_use","id":"toolu_1","name":"Bash","input":{"command":"./watch.sh","run_in_background":true}}],"usage":{"input_tokens":2}},"type":"assistant","uuid":"a1","timestamp":"2026-09-26T12:31:28.000Z","cwd":"/tmp/q","sessionId":"s-g"}"#,
            #"{"parentUuid":"a1","isSidechain":false,"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_1","content":"Command running in background with ID: b1"}]},"uuid":"u2","timestamp":"2026-09-26T12:31:30.000Z","cwd":"/tmp/q","sessionId":"s-g"}"#,
            #"{"parentUuid":"u2","isSidechain":false,"message":{"model":"claude-opus-5-5","role":"assistant","stop_reason":"end_turn","content":[{"type":"text","text":"It runs in the background."}],"usage":{"input_tokens":2}},"type":"assistant","uuid":"a2","timestamp":"2026-09-26T12:32:03.000Z","cwd":"/tmp/q","sessionId":"s-g"}"#
        ], id: "s-g")
        XCTAssertEqual(parsed.phase, .finished)
        let busy = ClaudeAgentView.entries(Data(#"[{"pid":48296,"cwd":"/tmp/q","kind":"interactive","sessionId":"s-g","status":"busy"}]"#.utf8))[0]
        let merged = ClaudeAgentView.merge(parsed, entry: busy, readAt: parsed.updatedAt.addingTimeInterval(20 * 3600))
        XCTAssertEqual(merged.phase, .working)
        XCTAssertTrue(merged.busyInBackground)
    }

    func testAQuestionPromptStaysAQuestionWhenItsPermissionHookRuns() throws {
        let parsed = try claude([
            #"{"parentUuid":null,"isSidechain":false,"promptId":"p1","type":"user","message":{"role":"user","content":"Integrate it"},"uuid":"u1","timestamp":"2026-09-23T07:42:30.000Z","entrypoint":"cli","cwd":"/tmp/s","sessionId":"s-f"}"#,
            #"{"parentUuid":"u1","isSidechain":false,"message":{"model":"claude-opus-5-5","role":"assistant","stop_reason":"tool_use","content":[{"type":"tool_use","id":"toolu_9","name":"AskUserQuestion","input":{"questions":[{"question":"Run the exercises in the browser?","header":"Run","multiSelect":false,"options":[{"label":"Browser"},{"label":"Server"}]}]}}],"usage":{"input_tokens":2}},"type":"assistant","uuid":"a1","timestamp":"2026-09-23T07:42:57.014Z","cwd":"/tmp/s","sessionId":"s-f"}"#
        ], id: "s-f")
        let hook = BridgeEvent(id: "e2", sessionID: "s-f", cwd: "/tmp/s", kind: "permission",
                               at: parsed.updatedAt.addingTimeInterval(0.2), detail: "AskUserQuestion")
        let merged = TelemetryParser.merge(parsed, status: nil, event: hook)
        XCTAssertEqual(merged.attention, .choice)
        XCTAssertEqual(merged.detail, "Run the exercises in the browser?")
    }

    func testACodexTurnLongerThanTheTailStillWorks() throws {
        let meta = Data(#"{"timestamp":"2026-09-26T09:34:31.450Z","type":"session_meta","payload":{"id":"t2","cwd":"/tmp/m","originator":"codex-tui","source":"cli","cli_version":"0.157.1"}}"#.utf8)
        // The tail holds only the turn's latest replies and token counts; its start is megabytes earlier.
        let tail = Data("""

        {"timestamp":"2026-09-26T10:20:00.000Z","type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Running the suite."}],"phase":"commentary"}}
        {"timestamp":"2026-09-26T10:20:01.000Z","type":"event_msg","payload":{"type":"token_count","info":{"model_context_window":258400,"last_token_usage":{"input_tokens":120000},"total_token_usage":{"total_tokens":9000000}},"rate_limits":{"limit_id":"codex","primary":{"used_percent":61,"window_minutes":10080,"resets_at":1790760451},"secondary":null}}}

        """.utf8)
        let session = try XCTUnwrap(TelemetryParser.codex(head: meta, tail: tail, filename: "t2.jsonl", modifiedAt: Date()))
        XCTAssertEqual(session.phase, .working)
        XCTAssertEqual(session.contextPercent ?? 0, 120_000.0 / 258_400 * 100, accuracy: 1e-9)
    }

    func testAClaudeSessionClosedWhileItWaitedWaitsNoMore() throws {
        let lines = [
            #"{"parentUuid":null,"isSidechain":false,"promptId":"p1","type":"user","message":{"role":"user","content":"Fix the header"},"uuid":"u1","timestamp":"2026-09-24T09:00:00.000Z","entrypoint":"cli","cwd":"/tmp/site","sessionId":"s-g"}"#,
            #"{"parentUuid":"u1","isSidechain":false,"message":{"model":"claude-opus-5-5","role":"assistant","stop_reason":"end_turn","content":[{"type":"text","text":"Should the footer change too?"}],"usage":{"input_tokens":2}},"type":"assistant","uuid":"a1","timestamp":"2026-09-24T09:01:00.000Z","cwd":"/tmp/site","sessionId":"s-g"}"#
        ]
        XCTAssertEqual(try claude(lines, id: "s-g").phase, .needsAttention)
        // Claude Code writes the session's cost when it exits.
        let exit = #"{"type":"cost-state","sessionId":"s-g","totalCostUSD":0.83,"totalAPIDuration":81794,"totalDuration":314061,"startTime":1790211600000,"modelUsage":{},"hasUnknownModelCost":false}"#
        let closed = try claude(lines + [exit], id: "s-g")
        XCTAssertTrue(closed.ended)
        XCTAssertEqual(closed.phase, .idle)
        // Resumed later in the same log, it is open again.
        let resumed = #"{"parentUuid":"a1","isSidechain":false,"promptId":"p2","type":"user","message":{"role":"user","content":"Yes, the footer too"},"uuid":"u2","timestamp":"2026-09-24T11:00:00.000Z","entrypoint":"cli","cwd":"/tmp/site","sessionId":"s-g"}"#
        let reopened = try claude(lines + [exit, resumed], id: "s-g")
        XCTAssertFalse(reopened.ended)
        XCTAssertEqual(reopened.phase, .working)
    }
}
