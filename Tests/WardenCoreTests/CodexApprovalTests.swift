import XCTest
@testable import WardenCore

/// Requests as Codex 0.157.1's shared daemon sent them to a second client while its terminal app showed the same prompt.
final class CodexApprovalTests: XCTestCase {
    private func json(_ text: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }

    private func decision(_ result: [String: Any]?) -> String? {
        result?["decision"] as? String
    }

    func testCommandPromptOffersTheTerminalsAnswers() throws {
        let params = try json(#"""
        {"kind":"command","threadId":"01a0ddd9-a0d4","turnId":"01a0ddd9-a16e","itemId":"exec-16e6c113","startedAtMs":1790428431657,
         "environmentId":"local","reason":"May I run `touch approved.txt` as requested?","command":"/bin/zsh -lc 'touch approved.txt'",
         "cwd":"/tmp/app","commandActions":[{"type":"unknown","command":"touch approved.txt"}],
         "proposedExecpolicyAmendment":["touch","approved.txt"],
         "availableDecisions":["accept",{"acceptWithExecpolicyAmendment":{"execpolicy_amendment":["touch","approved.txt"]}},"cancel"]}
        """#)
        let request = try XCTUnwrap(CodexApprovals.request(method: CodexApprovals.command, params: params, id: "p1", sessionID: "01a0ddd9-a0d4",
                                                           cwd: nil, rules: "~/.codex/rules/default.rules"))
        XCTAssertEqual(request.provider, .codex)
        XCTAssertEqual(request.summary, "touch approved.txt")
        XCTAssertEqual(request.cwd, "/tmp/app")
        XCTAssertFalse(request.isQuestion)
        // The terminal offers Yes, Yes and don't ask again for commands that start with these words, and No.
        XCTAssertFalse(request.canAllowForSession)
        XCTAssertEqual(request.alwaysRule, "commands starting with touch approved.txt")
        XCTAssertEqual(request.alwaysFile, "~/.codex/rules/default.rules")

        XCTAssertEqual(decision(CodexApprovals.result(for: .allow, method: CodexApprovals.command, params: params)), "accept")
        XCTAssertNil(CodexApprovals.result(for: .allowForSession, method: CodexApprovals.command, params: params))
        let always = try XCTUnwrap(CodexApprovals.result(for: .allowAlways, method: CodexApprovals.command, params: params)?["decision"] as? [String: Any])
        XCTAssertEqual((always["acceptWithExecpolicyAmendment"] as? [String: Any])?["execpolicy_amendment"] as? [String], ["touch", "approved.txt"])
        // Deny stops the turn, as "No, and tell Codex what to do differently" does, and declines where that is not offered.
        XCTAssertEqual(decision(CodexApprovals.result(for: .deny, method: CodexApprovals.command, params: params)), "cancel")
        var declining = params
        declining["availableDecisions"] = ["accept", "acceptForSession", "decline"]
        XCTAssertEqual(decision(CodexApprovals.result(for: .deny, method: CodexApprovals.command, params: declining)), "decline")
        XCTAssertEqual(decision(CodexApprovals.result(for: .allowForSession, method: CodexApprovals.command, params: declining)), "acceptForSession")
    }

    func testFileChangeNamesItsFilesFromTheCurrentTurn() throws {
        // The request names only its item; the page `thread/resume` returns holds the pending edit.
        let page = try json(#"""
        {"data":[{"id":"01a0dddd-1dac","items":[
          {"type":"userMessage","id":"item-1","clientId":"79e9db60","content":[{"type":"text","text":"Append world to patched.txt","text_elements":[]}]},
          {"type":"agentMessage","id":"item-2","text":"Applying the requested one-line append with `apply_patch`.","phase":"commentary","memoryCitation":null,"delivery":null,"questions":null},
          {"type":"fileChange","id":"exec-18898714","changes":[{"path":"/tmp/app/patched.txt","kind":{"type":"update","move_path":null},"diff":"@@ -1 +1,2 @@\n hello\n+world\n"}],"status":"inProgress"}],
          "itemsView":"full","status":"inProgress","error":null,"startedAt":1790428650,"completedAt":null,"durationMs":null}],
         "nextCursor":null,"backwardsCursor":null}
        """#)
        let params = try json(#"""
        {"threadId":"01a0ddd9-a0d4","turnId":"01a0dddd-1dac","itemId":"exec-18898714","startedAtMs":1790428656268,"reason":null,"grantRoot":null}
        """#)
        let edits = CodexApprovals.fileChanges(inPage: page)
        XCTAssertEqual(edits, ["exec-18898714": ["/tmp/app/patched.txt"]])
        let request = try XCTUnwrap(CodexApprovals.request(method: CodexApprovals.fileChange, params: params, id: "p2", sessionID: "01a0ddd9-a0d4",
                                                           cwd: "/tmp/app", paths: edits["exec-18898714"] ?? []))
        XCTAssertEqual(request.tool, "Edit")
        XCTAssertEqual(request.summary, "patched.txt")
        // "Yes, and don't ask again for these files".
        XCTAssertTrue(request.canAllowForSession)
        XCTAssertNil(request.alwaysRule)
        XCTAssertEqual(decision(CodexApprovals.result(for: .allowForSession, method: CodexApprovals.fileChange, params: params)), "acceptForSession")
        XCTAssertEqual(decision(CodexApprovals.result(for: .deny, method: CodexApprovals.fileChange, params: params)), "cancel")
        XCTAssertNil(CodexApprovals.result(for: .allowAlways, method: CodexApprovals.fileChange, params: params))
    }

    func testQuestionIsAnsweredByItsID() throws {
        let params = try json(#"""
        {"threadId":"01a0ddd9-a0d4","turnId":"01a0dddd-b0a4","itemId":"call_Vh8JAzao5O9KIWgsBTxpFDPO",
         "questions":[{"id":"plan_color","header":"Plan color","question":"Which color should the plan use?","isOther":true,"isSecret":false,
                       "options":[{"label":"Red","description":"Use red for the plan."},{"label":"Blue","description":"Use blue for the plan."}]}],
         "isBlocking":true,"autoResolutionMs":null}
        """#)
        let request = try XCTUnwrap(CodexApprovals.request(method: CodexApprovals.userInput, params: params, id: "p3", sessionID: "01a0ddd9-a0d4", cwd: "/tmp/app"))
        XCTAssertTrue(request.isQuestion)
        XCTAssertEqual(request.questions.first?.id, "plan_color")
        XCTAssertEqual(request.questions.first?.options, ["Red", "Blue"])
        // The menu answers by question text, as it does for Claude; Codex takes the question's id.
        let answer = ApprovalAnswer(behavior: "allow", answers: ["Which color should the plan use?": "Blue"])
        let result = try XCTUnwrap(CodexApprovals.result(for: answer, method: CodexApprovals.userInput, params: params))
        XCTAssertEqual((result["answers"] as? [String: Any])?["plan_color"] as? [String: [String]], ["answers": ["Blue"]])
        XCTAssertNil(CodexApprovals.result(for: .deny, method: CodexApprovals.userInput, params: params))
    }

    func testOtherRequestsAreLeftToTheirClient() throws {
        // A reply to these would count as the answer of the client they were meant for.
        let requests = [
            ("item/tool/call", #"{"threadId":"t1","turnId":"u1","callId":"c1","tool":"lookup","arguments":{}}"#),
            ("item/permissions/requestApproval", #"{"threadId":"t1","turnId":"u1","itemId":"i1","environmentId":null,"startedAtMs":1,"cwd":"/tmp/app","reason":null,"permissions":{"network":null,"fileSystem":null}}"#),
            ("mcpServer/elicitation/request", #"{"threadId":"t1","turnId":null,"serverName":"docs","mode":"url","_meta":null,"message":"Sign in","url":"https://example.com","elicitationId":"e1"}"#),
            ("currentTime/read", #"{"threadId":"t1"}"#)
        ]
        for (method, text) in requests {
            let params = try json(text)
            XCTAssertNil(CodexApprovals.request(method: method, params: params, id: "p", sessionID: "t1", cwd: nil), method)
            XCTAssertNil(CodexApprovals.result(for: .allow, method: method, params: params), method)
        }
    }

    func testAWaitingThreadPutsItsSessionInNeedsYou() throws {
        // The log shows a turn that runs: Codex never records the wait.
        let lines = [
            #"{"timestamp":"2026-09-26T13:13:42.000Z","ordinal":0,"type":"session_meta","payload":{"id":"01a0ddd9-a0d4","session_id":"01a0ddd9-a0d4","cwd":"/tmp/app","originator":"codex-tui","cli_version":"0.157.1","source":"vscode","thread_source":"user"}}"#,
            #"{"timestamp":"2026-09-26T13:15:30.000Z","ordinal":40,"type":"event_msg","payload":{"type":"task_started","turn_id":"01a0dddb-4678","started_at":1790428530}}"#
        ]
        let data = Data(lines.joined(separator: "\n").appending("\n").utf8)
        let session = try XCTUnwrap(TelemetryParser.codex(head: data, tail: data, filename: "rollout.jsonl", modifiedAt: Date()))
        XCTAssertEqual(session.phase, .working)

        let approval = try json(#"{"threadId":"01a0ddd9-a0d4","status":{"type":"active","activeFlags":["waitingOnApproval"]}}"#)
        let question = try json(#"{"threadId":"01a0ddd9-a0d4","status":{"type":"active","activeFlags":["waitingOnUserInput"]}}"#)
        XCTAssertEqual(CodexApprovals.waits(inStatus: approval["status"] as? [String: Any]), .permission)
        XCTAssertEqual(CodexApprovals.waits(inStatus: question["status"] as? [String: Any]), .choice)
        XCTAssertNil(CodexApprovals.waits(inStatus: ["type": "active", "activeFlags": [String]()]))
        XCTAssertNil(CodexApprovals.waits(inStatus: ["type": "idle"]))

        let waiting = CodexApprovals.applying(["01a0ddd9-a0d4": .init(kind: .permission, detail: "Command")], to: [session])
        XCTAssertEqual(waiting.first?.phase, .needsAttention)
        XCTAssertEqual(waiting.first?.attention, .permission)
        XCTAssertEqual(waiting.first?.detail, "Command")
    }

    func testOnlyADaemonThatHostsTheTerminalIsUsed() {
        XCTAssertTrue(CodexApprovals.isSupported(userAgent: "codex-tui/0.157.1 (Mac OS 15.7.7; arm64) vscode/1.138.0 (warden; 1.0)"))
        XCTAssertTrue(CodexApprovals.isSupported(userAgent: "codex-tui/0.159.0-alpha.4 (Mac OS 15.7.7; arm64)"))
        XCTAssertFalse(CodexApprovals.isSupported(userAgent: "codex-tui/0.156.2 (Mac OS 15.7.7; arm64)"))
        XCTAssertFalse(CodexApprovals.isSupported(userAgent: ""))
    }

    func testClaudeBridgeRequestsStillDecodeAsClaude() throws {
        // A bridge from an earlier build sends no provider and no question ids.
        let line = #"{"id":"r1","sessionID":"s1","tool":"AskUserQuestion","canAllowForSession":false,"cwd":"/tmp/app","questions":[{"text":"Which runner?","options":["Browser","Server"],"multiSelect":false}]}"#
        let request = try JSONDecoder().decode(ApprovalRequest.self, from: Data(line.utf8))
        XCTAssertEqual(request.provider, .claude)
        XCTAssertNil(request.questions.first?.id)
        XCTAssertTrue(request.isQuestion)
    }
}
