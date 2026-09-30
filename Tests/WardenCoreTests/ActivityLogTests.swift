import XCTest
@testable import WardenCore

final class ActivityLogTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_790_400_000)

    private func session(_ phase: AgentPhase, _ attention: AttentionKind? = nil, id: String = "s1", updated: TimeInterval,
                         turn: TimeInterval? = nil, detail: String? = nil) -> AgentSession {
        var session = AgentSession(id: id, provider: .claude, surface: "Terminal", cwd: "/tmp/app", phase: phase,
                                   attention: attention, updatedAt: start.addingTimeInterval(updated), detail: detail,
                                   turnStartedAt: turn.map { start.addingTimeInterval($0) })
        session.account = nil
        return session
    }

    func testScansBecomeSpansOfWorkAndOfWaitingForYou() throws {
        var recorder = ActivityRecorder()
        var closed: [ActivitySpan] = []
        // A turn that began before the first scan counts from its start in the log.
        closed += recorder.record([session(.working, updated: 50, turn: 0)], now: start.addingTimeInterval(60))
        closed += recorder.record([session(.working, updated: 290, turn: 0)], now: start.addingTimeInterval(300))
        // It asks for approval at 310, seen by the scan at 316.
        closed += recorder.record([session(.needsAttention, .permission, updated: 310, detail: "Bash")], now: start.addingTimeInterval(316))
        XCTAssertEqual(closed.map(\.kind), [.working])
        XCTAssertEqual(closed.first?.end, start.addingTimeInterval(310), "The turn ends when the log says it did.")
        recorder.answeredInWarden(session: "s1")
        closed += recorder.record([session(.working, updated: 400, turn: 0)], now: start.addingTimeInterval(404))
        let wait = try XCTUnwrap(closed.last)
        XCTAssertEqual(wait.kind, .waiting)
        XCTAssertEqual(wait.attention, .permission)
        XCTAssertEqual(wait.tool, "Bash")
        XCTAssertTrue(wait.answeredInWarden)
        XCTAssertEqual(wait.duration, 94)
        // Finished at 900; the session leaves the list, and its span closes where it was last seen.
        closed += recorder.record([session(.finished, updated: 900)], now: start.addingTimeInterval(904))
        closed += recorder.record([], now: start.addingTimeInterval(2000))
        XCTAssertTrue(recorder.open.isEmpty)
        XCTAssertEqual(closed.map(\.kind), [.working, .waiting, .working])

        let day = ActivitySummary(closed, from: start, to: start.addingTimeInterval(86_400))
        XCTAssertEqual(day.working, 310 + (900 - 404))
        XCTAssertEqual(day.waiting, 94)
        XCTAssertEqual(day.waits, 1)
        XCTAssertEqual(day.answeredInWarden, 1)
        XCTAssertEqual(day.medianWait, 94)
        XCTAssertEqual(day.waitingByKind[.permission], 94)
        XCTAssertEqual(try XCTUnwrap(day.autonomy), Double(day.working) / Double(day.working + 94), accuracy: 1e-9)
    }

    func testParallelWorkCountsOnceTowardBusyTime() {
        let spans = [
            ActivitySpan(session: "a", provider: .claude, project: "/a", kind: .working, start: start, end: start.addingTimeInterval(600)),
            ActivitySpan(session: "b", provider: .codex, project: "/b", kind: .working, start: start.addingTimeInterval(300),
                         end: start.addingTimeInterval(900)),
            // A wait that began the day before counts its time today, but not as one of today's waits.
            ActivitySpan(session: "c", provider: .codex, project: "/b", kind: .waiting, attention: .question,
                         start: start.addingTimeInterval(-100), end: start.addingTimeInterval(100))
        ]
        let summary = ActivitySummary(spans, from: start, to: start.addingTimeInterval(3600))
        XCTAssertEqual(summary.working, 1200)
        XCTAssertEqual(summary.busy, 900)
        XCTAssertEqual(summary.waiting, 100)
        XCTAssertEqual(summary.waits, 0)
    }

    /// Warden quits at 300 s during a turn that began at 0 s, and again at 700 s during a wait: each counts once.
    func testARelaunchDoesNotCountTheSameTimeTwice() {
        var first = ActivityRecorder()
        _ = first.record([session(.working, updated: 290, turn: 0)], now: start.addingTimeInterval(300))
        var spans = first.closeAll(now: start.addingTimeInterval(300))
        var second = ActivityRecorder(saved: spans)
        spans += second.record([session(.working, updated: 350, turn: 0)], now: start.addingTimeInterval(360))
        spans += second.record([session(.needsAttention, .question, updated: 600)], now: start.addingTimeInterval(604))
        spans += second.record([session(.needsAttention, .question, updated: 600)], now: start.addingTimeInterval(700))
        spans += second.closeAll(now: start.addingTimeInterval(700))
        var third = ActivityRecorder(saved: spans)
        spans += third.record([session(.needsAttention, .question, updated: 600)], now: start.addingTimeInterval(760))
        spans += third.record([session(.working, updated: 800, turn: 800)], now: start.addingTimeInterval(804))
        let day = ActivitySummary(spans, from: start, to: start.addingTimeInterval(3600))
        XCTAssertEqual(day.working, 600, "0 to 600 s once, not 0 to 300 s and 0 to 600 s.")
        XCTAssertEqual(day.busy, 600)
        XCTAssertEqual(day.waits, 1)
        XCTAssertEqual(day.waiting, 204)
        XCTAssertEqual(day.medianWait, 204)
    }

    func testTheLogKeepsSpansAcrossRelaunches() {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let log = ActivityLog(directory: folder)
        log.add([ActivitySpan(session: "a", provider: .claude, project: "/a", kind: .working, start: start,
                              end: start.addingTimeInterval(60)),
                 ActivitySpan(session: "a", provider: .claude, project: "/a", kind: .waiting, attention: .question,
                              start: start.addingTimeInterval(60), end: start.addingTimeInterval(62))],
                now: start.addingTimeInterval(62))
        log.flush()
        XCTAssertEqual(ActivityLog(directory: folder).all.map(\.kind), [.working])
    }
}
