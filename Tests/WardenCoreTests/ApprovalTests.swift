import XCTest
@testable import WardenCore

final class ApprovalTests: XCTestCase {
    func testBridgeRequestRetainsItsNamedAccount() throws {
        let data = Data(#"{"id":"r-work","sessionID":"s-work","tool":"Bash","canAllowForSession":false,"questions":[],"account":"work"}"#.utf8)
        let request = try JSONDecoder().decode(ApprovalRequest.self, from: data)
        let encoded = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any])
        XCTAssertEqual(encoded["account"] as? String, "work")
        XCTAssertEqual(request.provider, .claude, "Requests from older bridges carry no provider.")
        let legacy = Data(#"{"id":"r-default","sessionID":"s-default","tool":"Bash","canAllowForSession":false,"questions":[]}"#.utf8)
        XCTAssertNil(try JSONDecoder().decode(ApprovalRequest.self, from: legacy).account)
    }

    private func hook(_ json: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
    }

    private func decision(_ output: [String: Any]?) throws -> [String: Any] {
        let specific = try XCTUnwrap(output?["hookSpecificOutput"] as? [String: Any])
        XCTAssertEqual(specific["hookEventName"] as? String, "PermissionRequest")
        return try XCTUnwrap(specific["decision"] as? [String: Any])
    }

    func testToolPromptShowsTheCommandAndAllowsItForTheSessionOnly() throws {
        let input = try hook(#"""
        {"session_id":"s1","transcript_path":"/tmp/s1.jsonl","cwd":"/tmp/app","permission_mode":"default",
         "hook_event_name":"PermissionRequest","tool_name":"Bash",
         "tool_input":{"command":"npm run build &&\n  rm -rf dist/cache","description":"Build and clear the cache"},
         "permission_suggestions":[{"type":"addRules","rules":[{"toolName":"Bash","ruleContent":"npm run build:*"}],
                                    "behavior":"allow","destination":"localSettings"}]}
        """#)
        let request = try XCTUnwrap(Approval.request(from: input, id: "r1", sessionID: "s1"))
        XCTAssertEqual(request.summary, "npm run build && ⏎ rm -rf dist/cache")
        XCTAssertTrue(request.canAllowForSession)
        XCTAssertFalse(request.isQuestion)

        XCTAssertEqual(try decision(Approval.hookOutput(for: .allow, hook: input))["behavior"] as? String, "allow")

        // The rule Claude Code suggests is applied to this session, never written to a settings file.
        let session = try decision(Approval.hookOutput(for: .allowForSession, hook: input))
        let rules = try XCTUnwrap(session["updatedPermissions"] as? [[String: Any]])
        XCTAssertEqual(rules.map { $0["destination"] as? String }, ["session"])
        XCTAssertEqual((rules.first?["rules"] as? [[String: Any]])?.first?["ruleContent"] as? String, "npm run build:*")

        // Always Allow keeps Claude Code's own rule where Claude Code says, as its "don't ask again" does.
        XCTAssertEqual(request.alwaysRule, "Bash(npm run build:*)")
        let always = try decision(Approval.hookOutput(for: .allowAlways, hook: input))
        let kept = try XCTUnwrap(always["updatedPermissions"] as? [[String: Any]])
        XCTAssertEqual(kept.map { $0["destination"] as? String }, ["localSettings"])
        // A file edit is offered for the session only, so there is no rule to keep and Warden leaves the prompt alone.
        let edit = try hook(#"""
        {"session_id":"s1","cwd":"/tmp/app","hook_event_name":"PermissionRequest","tool_name":"Edit",
         "tool_input":{"file_path":"/tmp/app/main.swift"},
         "permission_suggestions":[{"type":"setMode","mode":"acceptEdits","destination":"session"}]}
        """#)
        XCTAssertNil(try XCTUnwrap(Approval.request(from: edit, id: "r3", sessionID: "s1")).alwaysRule)
        XCTAssertNil(Approval.hookOutput(for: .allowAlways, hook: edit))

        // Denying stops the turn, as No does in the terminal.
        let denied = try decision(Approval.hookOutput(for: .deny, hook: input))
        XCTAssertEqual(denied["behavior"] as? String, "deny")
        XCTAssertEqual(denied["interrupt"] as? Bool, true)

        // Without a decision the hook prints nothing and the terminal's prompt decides.
        XCTAssertNil(Approval.hookOutput(for: .undecided, hook: input))
    }

    func testQuestionIsAnsweredWithTheChosenOption() throws {
        let input = try hook(#"""
        {"session_id":"s2","cwd":"/tmp/solve","hook_event_name":"PermissionRequest","tool_name":"AskUserQuestion",
         "tool_input":{"questions":[{"question":"Where should the exercises run?","header":"Runner","multiSelect":false,
                                     "options":[{"label":"Browser (Recommended)","description":"Pyodide"},
                                                {"label":"Server","description":"API"}]}]}}
        """#)
        let request = try XCTUnwrap(Approval.request(from: input, id: "r2", sessionID: "s2"))
        XCTAssertTrue(request.isQuestion)
        XCTAssertFalse(request.canAllowForSession)
        XCTAssertEqual(request.questions.first?.options, ["Browser (Recommended)", "Server"])

        let answer = ApprovalAnswer(behavior: "allow", answers: ["Where should the exercises run?": "Server"])
        let updated = try XCTUnwrap(try decision(Approval.hookOutput(for: answer, hook: input))["updatedInput"] as? [String: Any])
        // The questions stay in the input next to their answers.
        XCTAssertEqual((updated["questions"] as? [[String: Any]])?.count, 1)
        XCTAssertEqual(updated["answers"] as? [String: String], ["Where should the exercises run?": "Server"])
    }
}
