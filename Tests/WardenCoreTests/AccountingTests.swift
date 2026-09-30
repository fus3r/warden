import XCTest
@testable import WardenCore

/// Accounting cases found in this Mac's logs and data files on 26 September 2026.
final class AccountingTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_790_400_000)
    private func at(_ text: String) -> Date { ISO8601DateFormatter().date(from: text + "Z")! }

    private func folder() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString) }

    /// The Codex readings of 9 September: the account signed in to `~/.codex` changed from one whose week was at 92%
    /// to one at 8% with another reset, and back two hours later. The logs do not say which account wrote a reading.
    func testAnotherAccountSigningInIsNoRiseOfTheLimit() throws {
        func reading(_ percent: Double, _ time: String, reset: String) -> UsageWindow {
            UsageWindow(id: "Codex-primary", provider: .codex, label: "7d", usedPercent: percent, resetsAt: at(reset),
                        observedAt: at(time), evidence: .localLog, minutes: 10_080)
        }
        func use(_ time: String, project: String) -> UsageEvent {
            UsageEvent(at: at(time), provider: .codex, session: "s-\(project)", project: project, model: "gpt-6-sol",
                       usage: TokenUsage(input: 20_000, cacheRead: 200_000, output: 2_000, requests: 1))
        }
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let ledger = QuotaLedger(directory: folder(), calendar: utc)
        let first = "2026-09-15T07:39:34", second = "2026-09-14T11:32:16"
        _ = ledger.update(events: [], readings: [reading(90, "2026-09-09T16:00:00", reset: first)], readAt: at("2026-09-09T16:00:10"),
                          coverage: at("2026-09-09T15:00:00"))
        _ = ledger.update(events: [use("2026-09-09T17:00:00", project: "/p/one")],
                          readings: [reading(91, "2026-09-09T17:05:50", reset: first), reading(92, "2026-09-09T17:10:32", reset: first)],
                          readAt: at("2026-09-09T17:11:00"))
        _ = ledger.update(events: [use("2026-09-09T17:15:00", project: "/p/two")],
                          readings: [reading(8, "2026-09-09T17:14:04", reset: second), reading(9, "2026-09-09T17:17:41", reset: second)],
                          readAt: at("2026-09-09T17:18:00"))
        _ = ledger.update(events: [use("2026-09-09T17:20:00", project: "/p/two")],
                          readings: [reading(10, "2026-09-09T17:27:09", reset: second)], readAt: at("2026-09-09T17:28:00"))
        let summary = ledger.update(events: [use("2026-09-09T18:30:00", project: "/p/three")],
                                    readings: [reading(92, "2026-09-09T19:31:02", reset: first)], readAt: at("2026-09-09T19:32:00"))
        let current = try XCTUnwrap(summary.current["Codex-primary"])
        XCTAssertNil(current.projects["/p/three"], "Switching back is no 82-point rise.")
        XCTAssertEqual(current.projects["/p/one"] ?? 0, 1, accuracy: 1e-9)
        XCTAssertEqual(current.unexplained, 1, accuracy: 1e-9, "The rise to 92% came with no local use.")
        XCTAssertEqual(current.projects["/p/two"] ?? 0, 2, accuracy: 1e-9, "The other account's own rises still count.")
        XCTAssertTrue(summary.finished.isEmpty, "No window ended.")
        XCTAssertEqual(current.resetsAt, at(first))
    }

    func testTheTypicalRateIsTheMedianOfPastWindows() {
        let periods: [QuotaPeriod] = [1.0, 2.0, 3.0, 10.0].map { perPoint in
            var period = QuotaPeriod(window: "Claude-seven_day", resetsAt: nil, percent: 50)
            period.pricedPoints = 10
            period.dollars = perPoint * 10
            return period
        }
        let summary = QuotaSummary(charges: [], windows: [:], current: [:], finished: periods, coverage: nil)
        XCTAssertEqual(summary.exchange(window: "Claude-seven_day").typical ?? 0, 2.5, accuracy: 1e-9)
    }

    /// One turn from 0 to 500 s that twice goes quiet for more than two minutes with no process matched to it.
    func testAQuietStretchInATurnDoesNotCountTheTurnAgain() {
        func session(_ phase: AgentPhase, updated: TimeInterval) -> AgentSession {
            AgentSession(id: "s1", provider: .codex, surface: "Terminal", cwd: "/tmp/app", phase: phase,
                         updatedAt: t0.addingTimeInterval(updated), turnStartedAt: t0)
        }
        var recorder = ActivityRecorder()
        var closed: [ActivitySpan] = []
        for (phase, updated, now) in [(AgentPhase.working, 10.0, 10.0), (.unknown, 10, 130), (.working, 200, 200),
                                      (.unknown, 250, 370), (.working, 400, 400), (.finished, 500, 504)] {
            closed += recorder.record([session(phase, updated: updated)], now: t0.addingTimeInterval(now))
        }
        let day = ActivitySummary(closed, from: t0, to: t0.addingTimeInterval(86_400))
        XCTAssertEqual(day.working, day.busy)
        XCTAssertLessThanOrEqual(day.working, 500)
    }

    /// Codex reports a week's reset a second apart from one reading to the next, and sessions side by side report a
    /// point or two apart.
    func testThePaceSurvivesResetJitterAndSmallDips() throws {
        let reset = t0.addingTimeInterval(3 * 86_400)
        var tracker = UsagePaceTracker()
        var last: UsageWindow?
        for (index, (minute, percent)) in [(0, 30.0), (4, 31), (6, 29), (8, 32), (12, 33), (16, 34)].enumerated() {
            let window = UsageWindow(id: "Codex-primary", provider: .codex, label: "7d", usedPercent: percent,
                                     resetsAt: reset.addingTimeInterval(index % 2 == 0 ? 0 : 1),
                                     observedAt: t0.addingTimeInterval(Double(minute) * 60), evidence: .localLog, minutes: 10_080)
            tracker.record([window], now: window.observedAt)
            last = window
        }
        let window = try XCTUnwrap(last)
        let pace = try XCTUnwrap(tracker.pace(for: window, now: window.observedAt))
        XCTAssertEqual(pace.pointsPerHour, 4 * 60 / 16, accuracy: 1e-9)
        XCTAssertEqual(UsageWindow.resetKey(reset), UsageWindow.resetKey(reset.addingTimeInterval(1)))
    }

    /// The July 2026 fork layout copies the parent's turn start and running totals, stamped with the fork's own start.
    func testAnOlderCodexForkCountsOnlyItsOwnTurns() {
        let lines = [
            #"{"timestamp":"2026-07-17T18:59:46.185Z","type":"session_meta","payload":{"id":"child","forked_from_id":"parent","cwd":"/tmp/api"}}"#,
            #"{"timestamp":"2026-07-17T18:59:46.185Z","type":"event_msg","payload":{"type":"task_started"}}"#,
            #"{"timestamp":"2026-07-17T18:59:46.185Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":39000,"cached_input_tokens":0,"output_tokens":252,"total_tokens":39252}}}}"#,
            #"{"timestamp":"2026-07-17T18:59:46.185Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":9000000,"cached_input_tokens":8000000,"output_tokens":100000,"total_tokens":9100000}}}}"#,
            #"{"timestamp":"2026-07-17T19:01:00.000Z","type":"event_msg","payload":{"type":"task_started"}}"#,
            #"{"timestamp":"2026-07-17T19:02:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":9100000,"cached_input_tokens":8050000,"output_tokens":101000,"total_tokens":9201000}}}}"#
        ]
        var cursor = LedgerCursor()
        UsageLedger.read(Data((lines.joined(separator: "\n") + "\n").utf8), provider: .codex, cursor: &cursor)
        XCTAssertEqual(cursor.records.reduce(0) { $0 + $1.usage.total }, 9_201_000 - 9_100_000)
    }

    func testACodexSessionsRecentUseIncludesTheThreadsItSpawned() throws {
        let root = folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let account = AgentAccount(provider: .codex, folder: root.appendingPathComponent("codex"), name: nil)
        let day = account.sessions.appendingPathComponent("2026/09/26")
        try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
        let parent = "01a0dd0b-ca4a-7000-8000-000000000001", child = "01a0dd0b-ca4a-7000-8000-000000000002"
        let parentLog = [
            #"{"timestamp":"2026-09-26T08:00:00.000Z","type":"session_meta","payload":{"id":"\#(parent)","cwd":"/tmp/app"}}"#,
            #"{"timestamp":"2026-09-26T08:00:01.000Z","type":"turn_context","payload":{"cwd":"/tmp/app","model":"gpt-6-sol"}}"#,
            #"{"timestamp":"2026-09-26T08:00:05.000Z","type":"token_usage_record","payload":{"thread_id":"\#(parent)","usage":{"input_tokens":1000,"cached_input_tokens":0,"output_tokens":100}}}"#
        ]
        let childLog = [
            #"{"timestamp":"2026-09-26T08:01:00.000Z","type":"session_meta","payload":{"id":"\#(child)","cwd":"/tmp/app","source":{"subagent":{"thread_spawn":{"parent_thread_id":"\#(parent)"}}}}}"#,
            #"{"timestamp":"2026-09-26T08:01:01.000Z","type":"turn_context","payload":{"cwd":"/tmp/app","model":"gpt-6-sol"}}"#,
            #"{"timestamp":"2026-09-26T08:01:05.000Z","type":"token_usage_record","payload":{"thread_id":"\#(child)","usage":{"input_tokens":5000,"cached_input_tokens":0,"output_tokens":500}}}"#
        ]
        try Data((parentLog.joined(separator: "\n") + "\n").utf8).write(to: day.appendingPathComponent("rollout-2026-09-26T08-00-00-\(parent).jsonl"))
        try Data((childLog.joined(separator: "\n") + "\n").utf8).write(to: day.appendingPathComponent("rollout-2026-09-26T08-01-00-\(child).jsonl"))
        let update = UsageHistory(directory: root.appendingPathComponent("history"))
            .update(accounts: [account], now: at("2026-09-26T09:00:00"), events: true)
        XCTAssertEqual((update.sessions[parent] ?? []).reduce(0) { $0 + $1.usage.total }, 6_600)
        XCTAssertNil(update.sessions[child])
    }

    /// Logs read before Warden kept reply claims: a fork made later copies replies an earlier read already counted.
    func testRepliesCountedBeforeClaimsExistedCountOnceAfterAFork() throws {
        let root = folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let account = AgentAccount(provider: .claude, folder: root.appendingPathComponent("claude"), name: nil)
        let project = account.sessions.appendingPathComponent("-tmp-app")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let history = root.appendingPathComponent("history")
        func reply(_ id: String, session: String, output: Int, time: String) -> String {
            #"{"parentUuid":null,"isSidechain":false,"type":"assistant","uuid":"u-\#(id)-\#(session)","timestamp":"2026-09-26T\#(time).000Z","cwd":"/tmp/app","sessionId":"\#(session)","requestId":"req-\#(id)","message":{"id":"msg-\#(id)","model":"claude-opus-5-5","role":"assistant","stop_reason":"end_turn","content":[{"type":"text","text":"Done."}],"usage":{"input_tokens":10,"cache_read_input_tokens":1000,"output_tokens":\#(output)}}}"#
        }
        let original = "11111111-1111-4111-8111-111111111111", fork = "22222222-2222-4222-8222-222222222222"
        try Data((reply("a", session: original, output: 100, time: "08:00:00") + "\n").utf8)
            .write(to: project.appendingPathComponent("\(original).jsonl"))
        _ = UsageHistory(directory: history).update(accounts: [account], now: at("2026-09-26T09:00:00"))
        // An install from before claims: no record of which log counted each reply.
        try FileManager.default.removeItem(at: history.appendingPathComponent("usage-replies.json"))
        // The fork copies the reply, then answers one of its own.
        try Data((reply("a", session: fork, output: 100, time: "08:00:00") + "\n" + reply("b", session: fork, output: 50, time: "10:00:00") + "\n").utf8)
            .write(to: project.appendingPathComponent("\(fork).jsonl"))
        let update = UsageHistory(directory: history).update(accounts: [account], now: at("2026-09-26T10:30:00"))
        let total = update.records.reduce(0) { $0 + $1.usage.total }
        XCTAssertEqual(total, 1_110 + 1_060, "Each reply counts once.")
    }
}
