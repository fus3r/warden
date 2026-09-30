import XCTest
@testable import WardenCore

final class TelemetryParserTests: XCTestCase {
    func testCodexLogMapsContextAndWeeklyQuotaWithoutTreatingCumulativeTokensAsContext() throws {
        let lines = [
            #"{"type":"session_meta","payload":{"id":"session-1","cwd":"/tmp/work","originator":"codex-tui","source":"cli"}}"#,
            #"{"type":"turn_context","payload":{"model":"gpt-6-sol","cwd":"/tmp/work"}}"#,
            #"{"type":"event_msg","payload":{"type":"task_started","turn_id":"t1","started_at":1790191895,"model_context_window":200000}}"#,
            #"{"type":"event_msg","payload":{"type":"token_count","info":{"model_context_window":200000,"last_token_usage":{"input_tokens":80000},"total_token_usage":{"total_tokens":900000}},"rate_limits":{"primary":{"used_percent":72,"window_minutes":10080,"resets_at":1790760451},"secondary":null,"plan_type":"prolite"}}}"#,
            #"{"type":"event_msg","payload":{"type":"task_complete","turn_id":"t1","last_agent_message":"I compared both designs.\n\nThe second one is faster. Which option should I use?","started_at":1790191895,"completed_at":1790192349,"duration_ms":454186}}"#
        ]
        let data = Data(lines.joined(separator: "\n").appending("\n").utf8)
        let session = try XCTUnwrap(TelemetryParser.codex(head: data, tail: data,
                                                           filename: "session-1.jsonl", modifiedAt: Date()))
        XCTAssertEqual(session.contextPercent, 40)
        XCTAssertEqual(session.contextEvidence, .inferred)
        XCTAssertEqual(session.totalTokens, 900000)
        XCTAssertEqual(session.phase, .needsAttention)
        XCTAssertEqual(session.attention, .question)
        XCTAssertEqual(session.detail, "Which option should I use?")
        XCTAssertEqual(session.turnStartedAt, Date(timeIntervalSince1970: 1790191895))
        XCTAssertEqual(session.windows.count, 1)
        XCTAssertEqual(session.windows.first?.shortLabel, "7d")
        XCTAssertEqual(session.windows.first?.usedPercent, 72)
    }

    func testClaudeTranscriptUsesTitleAndClosingQuestion() throws {
        let lines = [
            #"{"type":"user","sessionId":"claude-2","cwd":"/tmp/site","entrypoint":"cli","timestamp":"2026-09-23T19:40:22.000Z","message":{"role":"user","content":"Fix the header"}}"#,
            #"{"type":"last-prompt","lastPrompt":"Fix the header","leafUuid":"leaf-1","sessionId":"claude-2"}"#,
            #"{"type":"ai-title","aiTitle":"Fix the header layout","sessionId":"claude-2"}"#,
            #"{"type":"assistant","sessionId":"claude-2","cwd":"/tmp/site","message":{"model":"claude-opus","stop_reason":"end_turn","usage":{"input_tokens":10,"cache_read_input_tokens":90000},"content":[{"type":"text","text":"Updated the header.\n\n**Do you want the footer changed as well?**"}]}}"#
        ]
        let data = Data(lines.joined(separator: "\n").appending("\n").utf8)
        let session = try XCTUnwrap(TelemetryParser.claude(head: data, tail: Data("\n".utf8) + data,
                                                            filename: "claude-2.jsonl", modifiedAt: Date()))
        XCTAssertEqual(session.title, "Fix the header layout")
        XCTAssertEqual(session.phase, .needsAttention)
        XCTAssertEqual(session.detail, "Do you want the footer changed as well?")
        XCTAssertEqual(session.lastInputTokens, 90010)
    }

    func testClaudeSessionWithoutGeneratedTitleIsNamedByItsPrompt() throws {
        // Sessions started through the SDK, here from the root folder, never get an ai-title record.
        let lines = [
            #"{"parentUuid":null,"isSidechain":false,"promptId":"p1","type":"user","message":{"role":"user","content":"List the example files\n\nInclude hidden files."},"uuid":"u1","timestamp":"2026-09-24T05:52:23.752Z","promptSource":"sdk","entrypoint":"sdk-cli","cwd":"/","sessionId":"sdk-1"}"#,
            #"{"type":"last-prompt","lastPrompt":"List the example files   Include hidden files.","leafUuid":"u1","sessionId":"sdk-1"}"#,
            #"{"parentUuid":"u1","isSidechain":false,"message":{"model":"claude-opus-5-5","role":"assistant","stop_reason":"end_turn","content":[{"type":"text","text":"Three files found."}],"usage":{"input_tokens":2}},"type":"assistant","timestamp":"2026-09-24T05:53:02.000Z","entrypoint":"sdk-cli","cwd":"/","sessionId":"sdk-1"}"#
        ]
        let data = Data(lines.joined(separator: "\n").appending("\n").utf8)
        let session = try XCTUnwrap(TelemetryParser.claude(head: data, tail: Data("\n".utf8) + data,
                                                            filename: "sdk-1.jsonl", modifiedAt: Date()))
        XCTAssertEqual(session.title, "List the example files Include hidden files.")
        XCTAssertEqual(session.phase, .finished)
    }

    func testInterruptedTurnsWaitForYou() throws {
        func claude(_ lines: [String]) throws -> AgentSession {
            let data = Data(lines.joined(separator: "\n").appending("\n").utf8)
            return try XCTUnwrap(TelemetryParser.claude(head: data, tail: Data("\n".utf8) + data,
                                                        filename: "claude-5.jsonl", modifiedAt: Date()))
        }
        let prompt = #"{"parentUuid":null,"isSidechain":false,"promptId":"p1","type":"user","message":{"role":"user","content":"Fix the settings form"},"uuid":"u1","timestamp":"2026-09-24T08:20:20.300Z","entrypoint":"cli","cwd":"/tmp/quant","sessionId":"claude-5"}"#
        let bash = #"{"parentUuid":"u1","isSidechain":false,"message":{"model":"claude-opus-5-5","role":"assistant","stop_reason":"tool_use","content":[{"type":"tool_use","id":"toolu_1","name":"Bash","input":{"command":"rm -rf dist"}}],"usage":{"input_tokens":2,"cache_read_input_tokens":40000}},"type":"assistant","uuid":"a1","timestamp":"2026-09-24T08:20:24.046Z","cwd":"/tmp/quant","sessionId":"claude-5"}"#
        let declined = #"{"parentUuid":"a1","isSidechain":false,"promptId":"p1","type":"user","message":{"role":"user","content":[{"type":"tool_result","content":"The user doesn't want to proceed with this tool use. The tool use was rejected (eg. if it was a file edit, the new_string was NOT written to the file). STOP what you are doing and wait for the user to tell you how to proceed.","is_error":true,"tool_use_id":"toolu_1"}]},"uuid":"u2","timestamp":"2026-09-24T08:20:30.100Z","cwd":"/tmp/quant","sessionId":"claude-5"}"#
        let stopped = #"{"parentUuid":"u2","isSidechain":false,"promptId":"p1","type":"user","message":{"role":"user","content":[{"type":"text","text":"[Request interrupted by user for tool use]"}]},"uuid":"u3","timestamp":"2026-09-24T08:20:30.101Z","interruptedMessageId":"msg_1","cwd":"/tmp/quant","sessionId":"claude-5"}"#
        let escape = #"{"parentUuid":"u1","isSidechain":false,"promptId":"p1","type":"user","message":{"role":"user","content":[{"type":"text","text":"[Request interrupted by user]"}]},"uuid":"u4","timestamp":"2026-09-24T08:20:21.444Z","interruptedMessageId":"msg_2","cwd":"/tmp/quant","sessionId":"claude-5"}"#
        let next = #"{"parentUuid":"u3","isSidechain":false,"promptId":"p2","type":"user","message":{"role":"user","content":"Keep dist and continue"},"uuid":"u5","timestamp":"2026-09-24T08:21:02.000Z","cwd":"/tmp/quant","sessionId":"claude-5"}"#

        // A declined tool is followed by the interruption entry. No hook reports either.
        let declinedSession = try claude([prompt, bash, declined, stopped])
        XCTAssertEqual(declinedSession.phase, .needsAttention)
        XCTAssertEqual(declinedSession.attention, .interrupted)
        XCTAssertEqual(try claude([prompt, bash, declined, stopped, next]).phase, .working)

        // Esc a second after sending: the prompt's hook event, stored to the second, does not revive the turn.
        let escaped = try claude([prompt, escape])
        let submitted = BridgeEvent(id: "e1", sessionID: "claude-5", cwd: "/tmp/quant", kind: "working",
                                    at: Date(timeIntervalSince1970: 1_790_238_020))
        XCTAssertEqual(TelemetryParser.merge(escaped, status: nil, event: submitted).attention, .interrupted)

        let codex = Data([
            #"{"type":"session_meta","payload":{"id":"codex-2","cwd":"/tmp/quant","originator":"codex-tui","source":"cli"}}"#,
            #"{"type":"event_msg","payload":{"type":"task_started","turn_id":"t1","started_at":1787734989}}"#,
            #"{"type":"event_msg","payload":{"type":"turn_aborted","turn_id":"t1","reason":"interrupted","started_at":1787734989,"completed_at":1787735030,"duration_ms":40755}}"#
        ].joined(separator: "\n").appending("\n").utf8)
        let aborted = try XCTUnwrap(TelemetryParser.codex(head: codex, tail: codex, filename: "codex-2.jsonl", modifiedAt: Date()))
        XCTAssertEqual(aborted.phase, .needsAttention)
        XCTAssertEqual(aborted.attention, .interrupted)
    }

    func testLocalCommandsStartNoTurn() throws {
        func parse(_ lines: [String]) -> AgentSession? {
            let data = Data(lines.joined(separator: "\n").appending("\n").utf8)
            return TelemetryParser.claude(head: data, tail: Data("\n".utf8) + data, filename: "claude-8.jsonl", modifiedAt: Date())
        }
        // The transcript a /clear opens, before any prompt.
        let cleared = [
            #"{"type":"mode","mode":"auto"}"#,
            #"{"parentUuid":null,"isSidechain":false,"type":"user","message":{"role":"user","content":"<local-command-caveat>Caveat: The messages below were generated by the user while running local commands.</local-command-caveat>"},"isMeta":true,"uuid":"u1","timestamp":"2026-09-24T09:34:46.821Z","cwd":"/tmp/quant","sessionId":"claude-8"}"#,
            #"{"parentUuid":"u1","isSidechain":false,"type":"user","message":{"role":"user","content":"<command-name>/clear</command-name>\n            <command-message>clear</command-message>\n            <command-args></command-args>"},"uuid":"u2","timestamp":"2026-09-24T09:34:46.801Z","cwd":"/tmp/quant","sessionId":"claude-8"}"#,
            #"{"parentUuid":"u2","isSidechain":false,"type":"system","subtype":"local_command","content":"<local-command-stdout></local-command-stdout>","level":"info","timestamp":"2026-09-24T09:34:46.821Z","isMeta":false,"cwd":"/tmp/quant","sessionId":"claude-8"}"#
        ]
        XCTAssertNil(parse(cleared))

        let finished = [
            #"{"parentUuid":null,"isSidechain":false,"promptId":"p1","type":"user","message":{"role":"user","content":"Summarize the notes"},"uuid":"u1","timestamp":"2026-09-24T09:00:00.000Z","cwd":"/tmp/quant","sessionId":"claude-8"}"#,
            #"{"parentUuid":"u1","isSidechain":false,"message":{"model":"claude-opus-5-5","role":"assistant","stop_reason":"end_turn","content":[{"type":"text","text":"Done."}],"usage":{"input_tokens":2}},"type":"assistant","uuid":"a1","timestamp":"2026-09-24T09:00:20.000Z","cwd":"/tmp/quant","sessionId":"claude-8"}"#,
            #"{"parentUuid":"a1","isSidechain":false,"promptId":"p2","type":"user","message":{"role":"user","content":"<command-name>/model</command-name>\n            <command-message>model</command-message>\n            <command-args></command-args>"},"uuid":"u2","timestamp":"2026-09-24T09:01:00.000Z","cwd":"/tmp/quant","sessionId":"claude-8"}"#,
            #"{"parentUuid":"u2","isSidechain":false,"promptId":"p2","type":"user","message":{"role":"user","content":"<local-command-stdout>Set model to `Fable 5.1` and saved as your default for new sessions</local-command-stdout>"},"uuid":"u3","timestamp":"2026-09-24T09:01:00.100Z","cwd":"/tmp/quant","sessionId":"claude-8"}"#
        ]
        XCTAssertEqual(try XCTUnwrap(parse(finished)).phase, .finished)
    }

    func testClaudeQuestionPromptWaitsForYourAnswer() throws {
        let asked = [
            #"{"parentUuid":null,"isSidechain":false,"promptId":"p1","type":"user","message":{"role":"user","content":"Intègre RecallForge"},"uuid":"u1","timestamp":"2026-09-23T07:42:30.000Z","entrypoint":"cli","cwd":"/tmp/solve","sessionId":"claude-7"}"#,
            #"{"parentUuid":"u1","isSidechain":false,"message":{"model":"claude-opus-5-5","role":"assistant","stop_reason":"tool_use","content":[{"type":"tool_use","id":"toolu_9","name":"AskUserQuestion","input":{"questions":[{"question":"Comment faire tourner les 93 exercices PyTorch de RecallForge dans Solvewright ?","header":"Exécution","multiSelect":false,"options":[{"label":"Navigateur + runner local (Recommended)","description":"Pyodide"},{"label":"Serveur","description":"API"}]}]}}],"usage":{"input_tokens":2,"cache_read_input_tokens":61000}},"type":"assistant","uuid":"a1","timestamp":"2026-09-23T07:42:57.014Z","cwd":"/tmp/solve","sessionId":"claude-7"}"#
        ]
        let answer = #"{"parentUuid":"a1","isSidechain":false,"promptId":"p1","type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_9","content":"Your questions have been answered: \"Comment faire tourner les 93 exercices PyTorch de RecallForge dans Solvewright ?\"=\"Navigateur + runner local (Recommended)\"."}]},"uuid":"u2","timestamp":"2026-09-23T07:44:04.075Z","cwd":"/tmp/solve","sessionId":"claude-7"}"#
        func parse(_ lines: [String]) throws -> AgentSession {
            let data = Data(lines.joined(separator: "\n").appending("\n").utf8)
            return try XCTUnwrap(TelemetryParser.claude(head: data, tail: Data("\n".utf8) + data,
                                                        filename: "claude-7.jsonl", modifiedAt: Date()))
        }
        let waiting = try parse(asked)
        XCTAssertEqual(waiting.phase, .needsAttention)
        XCTAssertEqual(waiting.attention, .choice)
        XCTAssertEqual(waiting.detail, "Comment faire tourner les 93 exercices PyTorch de RecallForge dans Solvewright ?")
        XCTAssertEqual(try parse(asked + [answer]).phase, .working)
    }

    func testClaudeApiErrorEndsTheTurnWithItsType() throws {
        let lines = [
            #"{"parentUuid":null,"isSidechain":false,"promptId":"p1","type":"user","message":{"role":"user","content":"Run the audit"},"uuid":"u1","timestamp":"2026-09-17T19:38:58.000Z","entrypoint":"cli","cwd":"/tmp/audit","sessionId":"claude-6"}"#,
            #"{"parentUuid":"u1","isSidechain":false,"message":{"model":"claude-opus-5-5","role":"assistant","stop_reason":"tool_use","content":[{"type":"tool_use","id":"toolu_1","name":"Read","input":{"file_path":"/tmp/audit/a.py"}}],"usage":{"input_tokens":2,"cache_read_input_tokens":52000}},"type":"assistant","uuid":"a1","timestamp":"2026-09-17T19:39:10.000Z","cwd":"/tmp/audit","sessionId":"claude-6"}"#,
            #"{"parentUuid":"a1","isSidechain":false,"type":"assistant","uuid":"a2","timestamp":"2026-09-17T19:39:40.584Z","error":"rate_limit","isApiErrorMessage":true,"apiErrorStatus":429,"entrypoint":"cli","cwd":"/tmp/audit","sessionId":"claude-6","message":{"id":"m2","container":null,"model":"<synthetic>","role":"assistant","stop_reason":"stop_sequence","stop_sequence":"","type":"message","content":[{"type":"text","text":"You've hit your session limit · resets 1:40am (Europe/Paris)"}],"usage":{"input_tokens":0,"output_tokens":0}}}"#,
            #"{"parentUuid":"a2","isSidechain":false,"type":"system","subtype":"turn_duration","durationMs":42584,"messageCount":4,"isMeta":false,"uuid":"s1","timestamp":"2026-09-17T19:39:40.590Z","cwd":"/tmp/audit","sessionId":"claude-6"}"#
        ]
        let data = Data(lines.joined(separator: "\n").appending("\n").utf8)
        let session = try XCTUnwrap(TelemetryParser.claude(head: data, tail: Data("\n".utf8) + data,
                                                            filename: "claude-6.jsonl", modifiedAt: Date()))
        XCTAssertEqual(session.phase, .needsAttention)
        XCTAssertEqual(session.attention, .failure)
        XCTAssertEqual(session.detail, "rate_limit")
        // The error entry names no real model.
        XCTAssertEqual(session.model, "claude-opus-5-5")
    }

    func testClaudeBridgeSuppliesExactContextAttentionAndHost() throws {
        let base = AgentSession(id: "claude-1", provider: .claude, surface: "Terminal",
                                cwd: "/tmp/work/src", phase: .working, updatedAt: Date())
        let host = SessionHost(pid: 4242, processName: "2.1.280", tty: "ttys004", bundleID: "com.microsoft.VSCode")
        let status = BridgeStatus(sessionID: "claude-1", cwd: "/tmp/work/src", projectDir: "/tmp/work",
                                  sessionName: "Refactor parser", model: "Opus",
                                  contextPercent: 87, totalTokens: 174000,
                                  windows: [UsageWindow(id: "Claude-five_hour", provider: .claude,
                                                        label: "5h", usedPercent: 80, resetsAt: Date().addingTimeInterval(1200),
                                                        observedAt: Date(), evidence: .provider)],
                                  host: host, updatedAt: Date())
        let event = BridgeEvent(id: "event-1", sessionID: "claude-1", cwd: "/tmp/work",
                                kind: "permission", at: Date(), detail: "Bash")
        let result = TelemetryParser.merge(base, status: status, event: event)
        XCTAssertEqual(result.phase, .needsAttention)
        XCTAssertEqual(result.attention, .permission)
        XCTAssertEqual(result.detail, "Bash")
        XCTAssertEqual(result.contextPercent, 87)
        XCTAssertEqual(result.contextEvidence, .provider)
        XCTAssertEqual(result.project, "work")
        XCTAssertEqual(result.title, "Refactor parser")
        XCTAssertEqual(result.host, host)
        XCTAssertEqual(result.windows.first?.durationMinutes, 300)
    }

    func testTranscriptOverridesQuestionEventForFinishedReply() {
        // Older bridges recorded Claude's idle reminder, sent a minute after a finished reply, as a question.
        let finished = AgentSession(id: "claude-3", provider: .claude, surface: "Terminal", cwd: "/tmp/app",
                                    phase: .finished, updatedAt: Date().addingTimeInterval(-60))
        let reminder = BridgeEvent(id: "event-2", sessionID: "claude-3", cwd: "/tmp/app", kind: "question", at: Date())
        let result = TelemetryParser.merge(finished, status: nil, event: reminder)
        XCTAssertEqual(result.phase, .finished)
        XCTAssertNil(result.attention)

        // Without a transcript, the bridge's own reading of the final reply is all there is.
        let bridgeOnly = AgentSession(id: "claude-4", provider: .claude, surface: "Claude Code", cwd: "/tmp/app",
                                      updatedAt: .distantPast)
        XCTAssertEqual(TelemetryParser.merge(bridgeOnly, status: nil, event: reminder).attention, .question)
    }

    func testOneAgentProcessKeepsOnlyItsLatestSessionRunning() {
        let now = Date()
        let current = AgentSession(id: "new", provider: .claude, surface: "Terminal", cwd: "/tmp/app",
                                   phase: .working, updatedAt: now.addingTimeInterval(-600))
        let abandoned = AgentSession(id: "old", provider: .claude, surface: "Terminal", cwd: "/tmp/app",
                                     phase: .working, updatedAt: now.addingTimeInterval(-5400))
        var exact = AgentSession(id: "exact", provider: .claude, surface: "Terminal", cwd: "/tmp/other",
                                 phase: .working, updatedAt: now.addingTimeInterval(-900))
        exact.host = SessionHost(pid: 900)
        let processes = [AgentProcess(id: 800, provider: .claude, surface: "Terminal", cwd: "/tmp/app"),
                         AgentProcess(id: 900, provider: .claude, surface: "Terminal", cwd: "/tmp/other")]
        // A quiet transcript, such as a long reasoning step, keeps the session running while its process lives.
        XCTAssertEqual(SessionLiveness.running([abandoned, current, exact], processes: processes), ["new", "exact"])
    }

    func testAClosedSessionDoesNotTakeTheProcessOfAnOpenSession() {
        let now = Date()
        let open = AgentSession(id: "open", provider: .claude, surface: "Terminal", cwd: "/tmp/app",
                                phase: .working, updatedAt: now.addingTimeInterval(-600))
        var closed = AgentSession(id: "closed", provider: .claude, surface: "Terminal", cwd: open.cwd,
                                  phase: .idle, updatedAt: now)
        closed.ended = true
        let process = AgentProcess(id: 800, provider: .claude, surface: "Terminal", cwd: open.cwd)
        XCTAssertEqual(SessionLiveness.running([open, closed], processes: [process]), ["open"])
        XCTAssertTrue(SessionLiveness.running([closed], processes: [process]).isEmpty)
    }

    func testCodexAccountLimitsFromAppServer() {
        let result: [String: Any] = [
            "rateLimits": ["limitId": "codex", "planType": "prolite",
                           "primary": ["usedPercent": 10, "windowDurationMins": 10080, "resetsAt": 1790760451],
                           "secondary": NSNull()],
            "ordinaryUsageAllowed": true
        ]
        let windows = TelemetryParser.codexAccountWindows(result, observedAt: Date())
        XCTAssertEqual(windows.count, 1)
        XCTAssertEqual(windows.first?.id, "Codex-primary")
        XCTAssertEqual(windows.first?.shortLabel, "7d")
        XCTAssertEqual(windows.first?.evidence, .provider)
        XCTAssertEqual(windows.first?.resetsAt, Date(timeIntervalSince1970: 1790760451))
    }

    func testClaudeAccountLimitsFromUsageRequest() throws {
        let reply = Data(#"""
        {"session":{"total_cost_usd":0,"total_api_duration_ms":0,"total_duration_ms":0,"total_lines_added":0,"total_lines_removed":0,"model_usage":{}},
         "subscription_type":"max","rate_limits_available":true,
         "rate_limits":{"five_hour":{"utilization":3,"resets_at":"2026-09-24T10:49:59.728601+00:00","limit_dollars":null},
                        "seven_day":{"utilization":65,"resets_at":"2026-09-25T07:59:59.728630+00:00","limit_dollars":null},
                        "seven_day_opus":null,
                        "limits":[{"kind":"session","group":"session","percent":3,"severity":"normal","resets_at":"2026-09-24T10:49:59.728601+00:00","scope":null,"is_active":false}],
                        "model_scoped":[{"display_name":"Fable","utilization":94,"resets_at":"2026-09-25T07:59:59.728885+00:00"}]},
         "behaviors":null}
        """#.utf8)
        let result = try XCTUnwrap(JSONSerialization.jsonObject(with: reply) as? [String: Any])
        let windows = TelemetryParser.claudeAccountWindows(result, observedAt: Date())
        // Same ids as the status line, so the newer reading replaces the older one.
        XCTAssertEqual(windows.map(\.id), ["Claude-five_hour", "Claude-seven_day", "Claude-model-fable"])
        XCTAssertEqual(windows.map(\.usedPercent), [3, 65, 94])
        XCTAssertEqual(windows.map(\.rowLabel), ["Claude 5h", "Claude 7d", "Fable 7d"])
        XCTAssertEqual(windows.first?.evidence, .provider)
        // The status line reports this reset as 1790247000, so both sources give the same alert key.
        XCTAssertEqual(windows.first?.resetsAt, Date(timeIntervalSince1970: 1_790_247_000))
        // Fable's own weekly limit is nearly used while the plan's week is not: it resets with the week.
        XCTAssertEqual(windows.last?.name, "Claude Fable 7d")
        XCTAssertEqual(windows.last?.resetsAt, windows[1].resetsAt)

        // API key sessions have no plan limits.
        XCTAssertTrue(TelemetryParser.claudeAccountWindows(["rate_limits_available": false, "rate_limits": NSNull()],
                                                           observedAt: Date()).isEmpty)
    }

    func testHookEventsIgnoreIdleReminders() {
        XCTAssertEqual(ClaudeHookEvent.kind(event: "UserPromptSubmit"), "working")
        XCTAssertEqual(ClaudeHookEvent.kind(event: "Stop", lastMessage: "Tests pass."), "finished")
        XCTAssertEqual(ClaudeHookEvent.kind(event: "Stop", lastMessage: "Should I push the branch?"), "question")
        XCTAssertEqual(ClaudeHookEvent.kind(event: "Notification", notification: "permission_prompt"), "permission")
        XCTAssertNil(ClaudeHookEvent.kind(event: "Notification", notification: "idle_prompt"))
        XCTAssertEqual(ClaudeHookEvent.kind(event: "SessionEnd"), "ended")
    }

    func testCodexIndexKeepsLatestThreadName() {
        let data = Data("""
        ount":3}
        {"id":"a","thread_name":"First name","updated_at":"2026-09-23T18:48:34Z"}
        {"id":"b","thread_name":"Other","updated_at":"2026-09-23T19:03:24Z"}
        {"id":"a","thread_name":"Renamed","updated_at":"2026-09-23T19:31:42Z"}
        """.utf8)
        XCTAssertEqual(TelemetryParser.codexTitles(data), ["a": "Renamed", "b": "Other"])
    }

    func testForecastProjectsExhaustionOnlyWhenPaceExceedsWindow() throws {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        // Half of a five hour window has elapsed and 60% is used: 100% arrives 100 minutes from now.
        let hot = UsageWindow(id: "Claude-five_hour", provider: .claude, label: "5h", usedPercent: 60,
                              resetsAt: now.addingTimeInterval(9000), observedAt: now, evidence: .provider)
        let forecast = try XCTUnwrap(hot.forecast(now: now))
        XCTAssertEqual(forecast.elapsedFraction, 0.5, accuracy: 0.001)
        XCTAssertEqual(forecast.projectedPercent ?? 0, 120, accuracy: 0.001)
        XCTAssertEqual(forecast.exhaustsAt?.timeIntervalSince(now) ?? 0, 6000, accuracy: 1)
        XCTAssertEqual(UsageAlert.mostUrgent(in: [hot], now: now), .runsOut(hot, at: forecast.exhaustsAt!))

        let calm = UsageWindow(id: "Codex-primary", provider: .codex, label: "7d", usedPercent: 10,
                               resetsAt: now.addingTimeInterval(5 * 86_400), observedAt: now, evidence: .localLog, minutes: 10_080)
        XCTAssertNil(calm.forecast(now: now)?.exhaustsAt)
        XCTAssertNil(UsageAlert.mostUrgent(in: [calm], now: now))

        let early = UsageWindow(id: "Claude-five_hour", provider: .claude, label: "5h", usedPercent: 30,
                                resetsAt: now.addingTimeInterval(17_000), observedAt: now, evidence: .provider)
        XCTAssertNil(early.forecast(now: now)?.projectedPercent)
    }

    func testCodexKeepsEachLimitBucketAndItsOwnQuestions() throws {
        func codex(_ lines: [String]) throws -> AgentSession {
            let data = Data(lines.joined(separator: "\n").appending("\n").utf8)
            return try XCTUnwrap(TelemetryParser.codex(head: data, tail: data, filename: "rollout.jsonl", modifiedAt: Date()))
        }
        let meta = #"{"timestamp":"2026-09-23T18:47:58.000Z","ordinal":1,"type":"session_meta","payload":{"id":"t1","session_id":"t1","cwd":"/tmp/site","originator":"Codex Desktop","source":"vscode","thread_source":"user"}}"#
        let plan = #"{"timestamp":"2026-09-23T18:48:12.000Z","ordinal":4,"type":"event_msg","payload":{"type":"token_count","info":null,"rate_limits":{"limit_id":"codex","limit_name":null,"primary":{"used_percent":11.0,"window_minutes":10080,"resets_at":1790760451},"secondary":null,"plan_type":"prolite"}}}"#
        let spark = #"{"timestamp":"2026-09-23T18:52:00.000Z","ordinal":9,"type":"event_msg","payload":{"type":"token_count","info":null,"rate_limits":{"limit_id":"codex_bengalfox","limit_name":"GPT-5.3-Codex-Spark","primary":{"used_percent":40.0,"window_minutes":300,"resets_at":1790200000},"secondary":{"used_percent":8.0,"window_minutes":10080,"resets_at":1790700000},"plan_type":"prolite"}}}"#
        let session = try codex([meta, plan, spark])
        // The desktop app reports the VS Code source; its originator says where it runs.
        XCTAssertEqual(session.surface, "ChatGPT")
        // A Spark turn reports Spark's own limits and leaves the plan's week in place.
        XCTAssertEqual(session.windows.map(\.id).sorted(), ["Codex-codex_bengalfox-primary", "Codex-codex_bengalfox-secondary", "Codex-primary"])
        XCTAssertEqual(session.windows.first { $0.id == "Codex-codex_bengalfox-primary" }?.rowLabel, "Spark 5h")
        XCTAssertEqual(session.windows.first { $0.id == "Codex-primary" }?.usedPercent, 11)

        let started = #"{"timestamp":"2026-09-23T19:00:00.000Z","type":"event_msg","payload":{"type":"task_started","turn_id":"r2","started_at":1790190000}}"#
        // Codex acknowledges its question at once, with the same call id, and goes on working until you answer.
        let asked = #"{"timestamp":"2026-09-23T19:00:30.000Z","type":"response_item","payload":{"type":"function_call","name":"request_user_input_async","arguments":"{\"questions\":[{\"title\":\"Keep the old snapshots?\"}]}","call_id":"call_Q1"}}"#
        let acknowledged = #"{"timestamp":"2026-09-23T19:00:30.050Z","type":"response_item","payload":{"type":"function_call_output","call_id":"call_Q1","output":"a3f09c21b77d4e0f1"}}"#
        let counted = #"{"timestamp":"2026-09-23T19:00:31.000Z","type":"event_msg","payload":{"type":"token_count","info":null}}"#
        let commentary = #"{"timestamp":"2026-09-23T19:01:10.000Z","type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Meanwhile I checked the build."}],"phase":"commentary"}}"#
        let answered = #"{"timestamp":"2026-09-23T19:04:00.000Z","ordinal":31,"type":"response_item","payload":{"type":"message","id":"msg_9","role":"user","content":[{"type":"input_text","text":"Yes, keep them"}]}}"#
        let completed = #"{"timestamp":"2026-09-23T19:15:00.000Z","type":"event_msg","payload":{"type":"task_complete","turn_id":"r2","last_agent_message":"The build passes. I asked about the snapshots above."}}"#
        let working = try codex([meta, started, asked, acknowledged, counted, commentary])
        XCTAssertEqual(working.phase, .working)
        XCTAssertEqual(working.attention, .choice)
        XCTAssertEqual(working.detail, "Keep the old snapshots?")
        // A real blocking prompt from the daemon still takes precedence over the asynchronous question.
        let blocked = try XCTUnwrap(CodexApprovals.applying([working.id: .init(kind: .permission, detail: "pnpm build")],
                                                          to: [working]).first)
        XCTAssertEqual(blocked.phase, .needsAttention)
        XCTAssertEqual(blocked.attention, .permission)
        // The turn can end first; the question still waits.
        let ended = try codex([meta, started, asked, acknowledged, counted, commentary, completed])
        XCTAssertEqual(ended.phase, .needsAttention)
        XCTAssertEqual(ended.attention, .choice)
        XCTAssertEqual(ended.detail, "Keep the old snapshots?")
        let resumed = try codex([meta, started, asked, acknowledged, counted, answered])
        XCTAssertEqual(resumed.phase, .working)
        XCTAssertNil(resumed.attention)
        XCTAssertNil(resumed.detail)
        XCTAssertEqual(try codex([meta, started, asked, acknowledged, answered, completed]).phase, .finished)

        let failed = #"{"timestamp":"2026-09-23T19:10:00.000Z","type":"event_msg","payload":{"type":"task_complete","turn_id":"r2","last_agent_message":null,"error":{"codex_error_info":"server_overloaded","message":"We're currently experiencing high demand."}}}"#
        let stopped = try codex([meta, started, failed])
        XCTAssertEqual(stopped.attention, .failure)
        XCTAssertEqual(stopped.detail, "server_overloaded")

        // A spawned thread works for the session that started it.
        let spawned = #"{"timestamp":"2026-09-23T19:20:00.000Z","type":"session_meta","payload":{"id":"t9","session_id":"t1","cwd":"/tmp/site","originator":"codex-tui","source":{"subagent":{"thread_spawn":{"parent_thread_id":"t1","depth":1}}},"thread_source":"subagent"}}"#
        let thread = try codex([spawned, started])
        XCTAssertTrue(thread.isSubagent)
        XCTAssertEqual(thread.parentID, "t1")
    }

    func testCodexAccountLimitsPerBucket() throws {
        let bucket: (String, String?, Double, Int) -> [String: Any] = { id, name, percent, minutes in
            ["limitId": id, "limitName": name ?? NSNull(), "primary": ["usedPercent": percent, "windowDurationMins": minutes, "resetsAt": 1790760451],
             "secondary": NSNull()]
        }
        let result: [String: Any] = ["rateLimits": bucket("codex", nil, 11, 10080),
                                     "rateLimitsByLimitId": ["codex": bucket("codex", nil, 11, 10080),
                                                             "codex_bengalfox": bucket("codex_bengalfox", "GPT-5.3-Codex-Spark", 40, 300)]]
        let windows = TelemetryParser.codexAccountWindows(result, observedAt: Date())
        XCTAssertEqual(windows.map(\.name), ["Codex Spark 5h", "Codex 7d"])

        // Banked limit resets are shown only; credits count only when the account has some.
        var reply = result
        reply["rateLimits"] = (result["rateLimits"] as? [String: Any] ?? [:]).merging(
            ["planType": "prolite", "credits": ["hasCredits": false, "unlimited": false, "balance": "0"]]) { $1 }
        reply["rateLimitResetCredits"] = ["availableCount": 2, "credits": NSNull()]
        let plan = try XCTUnwrap(TelemetryParser.codexPlan(reply))
        XCTAssertEqual(plan.resets, 2)
        XCTAssertNil(plan.credits)
        XCTAssertEqual(plan.planName, "Pro Lite")

        // With their details, banked resets say when they expire unused, soonest first.
        reply["rateLimitResetCredits"] = ["availableCount": 2, "credits": [
            ["id": "RateLimitResetCredit_b", "resetType": "codexRateLimits", "status": "available",
             "grantedAt": 1790110148, "expiresAt": 1792702148, "title": "Full reset"],
            ["id": "RateLimitResetCredit_a", "resetType": "codexRateLimits", "status": "available",
             "grantedAt": 1788582132, "expiresAt": 1791174132, "title": "Full reset"]
        ]]
        XCTAssertEqual(try XCTUnwrap(TelemetryParser.codexPlan(reply)).resetsExpire,
                       [Date(timeIntervalSince1970: 1791174132), Date(timeIntervalSince1970: 1792702148)])
    }

    /// Since 0.157 the terminal app runs its threads in Codex's shared daemon, whose logs report the VS Code source.
    func testCodexTerminalOnTheSharedDaemonIsNotVSCode() throws {
        let line = #"{"timestamp":"2026-09-26T07:58:31.881Z","ordinal":0,"type":"session_meta","payload":{"creator_user_id":"user-1","creator_account_id":"account-1","session_id":"example-session","id":"example-session","timestamp":"2026-09-26T07:57:15.091Z","cwd":"/Users/me/Documents/app","runtime_workspace_roots":["/Users/me/Documents/app"],"originator":"codex-tui","cli_version":"0.157.1","source":"vscode","thread_source":"user","model_provider":"openai","base_instructions":"Example session instructions.","history_mode":"paginated","context_window":{"window_id":"example-context-window"},"git":{"commit_hash":"abcdef0","branch":"main","repository_url":null}}}"#
        let data = Data((line + "\n").utf8)
        let session = try XCTUnwrap(TelemetryParser.codex(head: data, tail: data, filename: "rollout.jsonl", modifiedAt: Date()))
        XCTAssertEqual(session.surface, "Terminal")
        XCTAssertFalse(session.isHeadless)
    }

    /// A Codex fork copies its parent's history after its own metadata; the log keeps its own identity.
    func testACodexForkKeepsItsOwnIdentity() throws {
        let lines = [
            #"{"timestamp":"2026-09-26T08:00:00.000Z","type":"session_meta","payload":{"id":"child","forked_from_id":"parent","cwd":"/tmp/site","originator":"codex-tui","source":"cli"}}"#,
            #"{"timestamp":"2026-09-26T08:00:00.100Z","type":"session_meta","payload":{"id":"parent","cwd":"/tmp/site","originator":"codex_exec","source":"exec"}}"#,
            #"{"timestamp":"2026-09-26T08:01:00.000Z","type":"event_msg","payload":{"type":"task_started","turn_id":"t2"}}"#
        ]
        let data = Data(lines.joined(separator: "\n").appending("\n").utf8)
        let session = try XCTUnwrap(TelemetryParser.codex(head: data, tail: data, filename: "rollout-child.jsonl", modifiedAt: Date()))
        XCTAssertEqual(session.id, "child")
        XCTAssertFalse(session.isHeadless)
        XCTAssertEqual(session.phase, .working)
    }

    /// `claude -p` writes its transcript like any session, with an SDK entrypoint, and exits when its turn ends.
    func testAClaudeRunStartedByAProgramIsHeadless() throws {
        let lines = [
            #"{"parentUuid":null,"isSidechain":false,"promptId":"p1","type":"user","message":{"role":"user","content":"List the files in the example project"},"uuid":"u1","timestamp":"2026-09-26T07:09:50.000Z","entrypoint":"sdk-cli","cwd":"/","sessionId":"sdk-1"}"#,
            #"{"parentUuid":"u1","isSidechain":false,"type":"assistant","uuid":"a1","timestamp":"2026-09-26T07:10:12.000Z","error":"server_error","isApiErrorMessage":true,"entrypoint":"sdk-cli","cwd":"/","sessionId":"sdk-1","message":{"id":"m1","model":"<synthetic>","role":"assistant","stop_reason":"stop_sequence","content":[{"type":"text","text":"API Error: 500"}],"usage":{"input_tokens":0,"output_tokens":0}}}"#
        ]
        let data = Data(lines.joined(separator: "\n").appending("\n").utf8)
        let session = try XCTUnwrap(TelemetryParser.claude(head: data, tail: Data("\n".utf8) + data, filename: "sdk-1.jsonl", modifiedAt: Date()))
        XCTAssertTrue(session.isHeadless)
        XCTAssertEqual(session.attention, .failure)
        XCTAssertEqual(session.detail, "server_error")
        let interactive = lines[0].replacingOccurrences(of: "sdk-cli", with: "cli")
        XCTAssertFalse(try XCTUnwrap(TelemetryParser.claude(head: Data(interactive.utf8), tail: Data(("\n" + interactive + "\n").utf8),
                                                            filename: "c.jsonl", modifiedAt: Date())).isHeadless)
    }

    func testClaudeWaitingForALimitResetContinuesByItself() throws {
        let lines = [
            #"{"parentUuid":null,"isSidechain":false,"promptId":"p1","type":"user","message":{"role":"user","content":"Run the audit"},"uuid":"u1","timestamp":"2026-09-17T19:38:58.000Z","entrypoint":"cli","cwd":"/tmp/audit","sessionId":"claude-9"}"#,
            #"{"parentUuid":"u1","isSidechain":false,"type":"assistant","uuid":"a2","timestamp":"2026-09-17T19:39:40.584Z","error":"rate_limit","isApiErrorMessage":true,"apiErrorStatus":429,"quotaLimits":{"status":"rejected","resetsAt":1789688400,"rateLimitType":"five_hour","overageStatus":"rejected"},"cwd":"/tmp/audit","sessionId":"claude-9","message":{"id":"m2","model":"<synthetic>","role":"assistant","stop_reason":"stop_sequence","content":[{"type":"text","text":"You've hit your session limit · resets 1:40am (Europe/Paris)"}],"usage":{"input_tokens":0,"output_tokens":0}}}"#,
            #"{"parentUuid":"a2","isSidechain":false,"type":"system","subtype":"informational","content":"Usage limit reached · continuing automatically at 1:40am · esc or type to cancel","level":"info","timestamp":"2026-09-17T19:39:40.600Z","cwd":"/tmp/audit","sessionId":"claude-9"}"#
        ]
        let data = Data(lines.joined(separator: "\n").appending("\n").utf8)
        let session = try XCTUnwrap(TelemetryParser.claude(head: data, tail: Data("\n".utf8) + data,
                                                            filename: "claude-9.jsonl", modifiedAt: Date()))
        XCTAssertEqual(session.phase, .working)
        XCTAssertNil(session.attention)
        XCTAssertEqual(session.resumesAt, Date(timeIntervalSince1970: 1789688400))
        // The StopFailure hook reports the limit; the log's wait for the reset still decides.
        let hook = BridgeEvent(id: "e9", sessionID: "claude-9", cwd: "/tmp/audit", kind: "failure",
                               at: Date(timeIntervalSince1970: 1789666781), detail: "rate_limit")
        XCTAssertEqual(TelemetryParser.merge(session, status: nil, event: hook).phase, .working)
    }

    func testClaudeAgentViewAddsWaitsTheLogCannotShow() throws {
        let data = Data(#"""
        [{"pid":48296,"cwd":"/tmp/quant","kind":"interactive","startedAt":1790184159237,"sessionId":"s-sandbox","name":"learning-app-23","status":"waiting","waitingFor":"sandbox request"},
         {"pid":96425,"cwd":"/tmp/warden","kind":"interactive","startedAt":1790193027641,"sessionId":"s-busy","name":"warden-a1","status":"busy"},
         {"id":"6515865f","cwd":"/tmp/brain","kind":"background","startedAt":1782937820160,"sessionId":"s-bg","name":"Review the study","state":"blocked"}]
        """#.utf8)
        let entries = ClaudeAgentView.entries(data)
        XCTAssertEqual(entries.count, 3)
        let readAt = Date()
        func session(_ id: String, _ phase: AgentPhase, age: TimeInterval) -> AgentSession {
            AgentSession(id: id, provider: .claude, surface: "Terminal", cwd: "/tmp", phase: phase,
                         updatedAt: readAt.addingTimeInterval(-age))
        }

        // A sandbox request shows in no hook or log entry.
        let sandbox = ClaudeAgentView.merge(session("s-sandbox", .working, age: 30), entry: entries[0], readAt: readAt)
        XCTAssertEqual(sandbox.phase, .needsAttention)
        XCTAssertEqual(sandbox.attention, .permission)
        XCTAssertEqual(sandbox.host?.pid, 48296)

        // A busy process keeps a session working; a log that moved on after the reading wins.
        XCTAssertEqual(ClaudeAgentView.merge(session("s-busy", .finished, age: 20), entry: entries[1], readAt: readAt).phase, .working)
        XCTAssertEqual(ClaudeAgentView.merge(session("s-busy", .finished, age: -10), entry: entries[1], readAt: readAt).phase, .finished)

        // A blocked background session waits on you with no process of its own, and `claude attach` opens it.
        let blocked = ClaudeAgentView.merge(session("s-bg", .unknown, age: 3), entry: entries[2], readAt: readAt)
        XCTAssertEqual(blocked.phase, .needsAttention)
        XCTAssertEqual(blocked.backgroundID, "6515865f")
        XCTAssertNil(blocked.host?.pid)
    }
}
