import XCTest
@testable import WardenCore

final class UsageHistoryTests: XCTestCase {
    func testResumingAnArchivedCodexLogCountsOnlyNewUsageAfterRelaunch() throws {
        try checkResumedHistory(legacyArchive: false)
    }

    func testExistingArchivesRecoverTheirParserStateWhenALogResumes() throws {
        try checkResumedHistory(legacyArchive: true)
    }

    private func checkResumedHistory(legacyArchive: Bool) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let account = AgentAccount(provider: .codex, folder: root.appendingPathComponent("codex"), name: nil)
        try FileManager.default.createDirectory(at: account.sessions, withIntermediateDirectories: true)
        let file = account.sessions.appendingPathComponent("rollout-session.jsonl")
        let now = ISO8601DateFormatter().date(from: "2026-09-26T12:00:00Z")!
        let first = """
        {"timestamp":"2026-09-22T08:00:00Z","type":"session_meta","payload":{"id":"s1","cwd":"/tmp/project"}}
        {"timestamp":"2026-09-22T08:00:01Z","type":"turn_context","payload":{"model":"gpt-test"}}
        {"timestamp":"2026-09-22T08:01:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":1000,"output_tokens":100}}}}

        """
        try Data(first.utf8).write(to: file)
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-4 * 86_400)], ofItemAtPath: file.path)
        let directory = root.appendingPathComponent("history")
        let before = UsageHistory(directory: directory).update(accounts: [account], now: now)
        XCTAssertEqual(before.records.reduce(0) { $0 + $1.usage.total }, 1100)
        if legacyArchive {
            let archive = directory.appendingPathComponent("usage-archive.json")
            var stored = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: archive)) as? [String: Any])
            var settled = try XCTUnwrap(stored["settled"] as? [String: [String: Any]])
            for key in settled.keys { settled[key]?.removeValue(forKey: "checkpoint") }
            stored["settled"] = settled
            try JSONSerialization.data(withJSONObject: stored).write(to: archive)
        }

        let more = """
        {"timestamp":"2026-09-26T12:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":1400,"output_tokens":200}}}}

        """
        try Data((first + more).utf8).write(to: file)
        try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: file.path)
        let resumed = UsageHistory(directory: directory)
        let after = resumed.update(accounts: [account], now: now)
        XCTAssertEqual(after.records.reduce(0) { $0 + $1.usage.total }, 1600)
        XCTAssertTrue(after.records.allSatisfy { $0.model == "gpt-test" && $0.project == "/tmp/project" })
        resumed.flush(now: now)
        let relaunched = UsageHistory(directory: directory).update(accounts: [account], now: now)
        XCTAssertEqual(relaunched.records.reduce(0) { $0 + $1.usage.total }, 1600)
    }
}

final class UsageDuplicateTests: XCTestCase {
    private func reply(_ id: String, request: String, session: String, output: Int, at time: String) -> String {
        #"{"type":"assistant","timestamp":"2026-09-26T\#(time)Z","cwd":"/tmp/app","sessionId":"\#(session)","requestId":"\#(request)","message":{"id":"\#(id)","model":"claude-opus-5-5","role":"assistant","usage":{"input_tokens":5,"cache_read_input_tokens":1000,"output_tokens":\#(output)}}}"#
    }

    /// A branch copies the replies before it into the new session's log, keeping their ids.
    func testABranchedSessionDoesNotCountTheRepliesItCopied() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let account = AgentAccount(provider: .claude, folder: root.appendingPathComponent("claude"), name: nil)
        let folder = account.sessions.appendingPathComponent("-tmp-app")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let original = [reply("m1", request: "r1", session: "s1", output: 50, at: "08:00:00"),
                        reply("m2", request: "r2", session: "s1", output: 60, at: "08:05:00")]
        try Data((original.joined(separator: "\n") + "\n").utf8).write(to: folder.appendingPathComponent("s1.jsonl"))
        let directory = root.appendingPathComponent("history")
        let now = ISO8601DateFormatter().date(from: "2026-09-26T09:00:00Z")!
        XCTAssertEqual(UsageHistory(directory: directory).update(accounts: [account], now: now).records.reduce(0) { $0 + $1.usage.requests }, 2)

        let branch = [reply("m1", request: "r1", session: "s2", output: 50, at: "08:00:00"),
                      reply("m2", request: "r2", session: "s2", output: 60, at: "08:05:00"),
                      reply("m3", request: "r3", session: "s2", output: 70, at: "08:30:00")]
        try Data((branch.joined(separator: "\n") + "\n").utf8).write(to: folder.appendingPathComponent("s2.jsonl"))
        // A relaunch in between must remember which log counted each reply.
        let history = UsageHistory(directory: directory)
        let records = history.update(accounts: [account], now: now.addingTimeInterval(60)).records
        XCTAssertEqual(records.reduce(0) { $0 + $1.usage.requests }, 3)
        XCTAssertEqual(records.reduce(0) { $0 + $1.usage.output }, 50 + 60 + 70)
    }

    func testTheEntryOfAReplyWithTheMostTokensCounts() {
        let lines = [reply("m1", request: "r1", session: "s1", output: 400, at: "08:00:00"),
                     reply("m1", request: "r1", session: "s1", output: 90, at: "08:00:01")]
        var cursor = LedgerCursor()
        UsageLedger.read(Data((lines.joined(separator: "\n") + "\n").utf8), provider: .claude, cursor: &cursor)
        XCTAssertEqual(cursor.records.first?.usage.output, 400)
        XCTAssertEqual(cursor.records.first?.usage.requests, 1)
    }

    /// A Codex fork can copy its parent's history: records of the parent's thread, and before them running totals.
    func testACodexForkCountsOnlyItsOwnUse() throws {
        let lines = [
            #"{"timestamp":"2026-09-26T08:00:00.000Z","type":"session_meta","payload":{"id":"child","forked_from_id":"parent","cwd":"/tmp/site","source":"cli"}}"#,
            #"{"timestamp":"2026-09-26T08:00:00.100Z","type":"session_meta","payload":{"id":"parent","cwd":"/tmp/site","source":"cli"}}"#,
            #"{"timestamp":"2026-09-26T07:00:00.000Z","type":"turn_context","payload":{"cwd":"/tmp/site","model":"gpt-6-sol"}}"#,
            #"{"timestamp":"2026-09-26T07:00:05.000Z","type":"token_usage_record","payload":{"thread_id":"parent","turn_id":"t1","response_id":"resp_1","usage":{"input_tokens":9000,"cached_input_tokens":0,"output_tokens":100}}}"#,
            #"{"timestamp":"2026-09-26T08:01:00.000Z","type":"event_msg","payload":{"type":"task_started","turn_id":"t2"}}"#,
            #"{"timestamp":"2026-09-26T08:01:05.000Z","type":"token_usage_record","payload":{"thread_id":"child","turn_id":"t2","response_id":"resp_2","usage":{"input_tokens":2000,"cached_input_tokens":1000,"output_tokens":50}}}"#
        ]
        var cursor = LedgerCursor()
        UsageLedger.read(Data((lines.joined(separator: "\n") + "\n").utf8), provider: .codex, cursor: &cursor)
        XCTAssertEqual(cursor.records.reduce(0) { $0 + $1.usage.total }, 2050)

        // An older fork repeats running totals instead: only their growth after its own first turn counts.
        let older = [
            #"{"timestamp":"2026-08-01T08:00:00.000Z","type":"session_meta","payload":{"id":"child","forked_from_id":"parent","cwd":"/tmp/api"}}"#,
            #"{"timestamp":"2026-08-01T08:00:01.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":9000,"cached_input_tokens":0,"output_tokens":100,"total_tokens":9100}}}}"#,
            #"{"timestamp":"2026-08-01T08:01:00.000Z","type":"event_msg","payload":{"type":"task_started"}}"#,
            #"{"timestamp":"2026-08-01T08:02:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":10000,"cached_input_tokens":0,"output_tokens":150,"total_tokens":10150}}}}"#
        ]
        var legacy = LedgerCursor()
        UsageLedger.read(Data((older.joined(separator: "\n") + "\n").utf8), provider: .codex, cursor: &legacy)
        XCTAssertEqual(legacy.records.reduce(0) { $0 + $1.usage.total }, 1050)
    }

    /// Archives written before a field existed must still decode, or 90 days of totals would be lost.
    func testCursorsSavedByEarlierVersionsStillDecode() throws {
        let saved = #"{"offset":120,"records":[{"day":"2026-09-01","provider":"Codex","model":"gpt-6-sol","project":"/tmp/site","usage":{"input":10,"cacheWrite":0,"cacheWriteHour":0,"cacheRead":5,"output":3,"requests":1}}],"session":"t1","cwd":"/tmp/site","model":"gpt-6-sol","usesResponseRecords":true}"#
        let cursor = try JSONDecoder().decode(LedgerCursor.self, from: Data(saved.utf8))
        XCTAssertEqual(cursor.offset, 120)
        XCTAssertEqual(cursor.records.first?.usage.total, 18)
    }
}
