import XCTest
@testable import WardenCore

final class DepartureReviewTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_790_424_000)

    private func session(_ id: String, phase: AgentPhase = .working, account: String? = nil) -> AgentSession {
        var result = AgentSession(id: id, provider: .claude, surface: "Terminal", cwd: "/projects/\(id)",
                                  phase: phase, updatedAt: now)
        result.account = account
        return result
    }

    private func window(account: String? = nil, scope: String? = nil, age: TimeInterval = 0) -> UsageWindow {
        UsageWindow(id: "Claude-\(account ?? "default")-five_hour", provider: .claude, label: "5h", usedPercent: 50,
                    resetsAt: now.addingTimeInterval(7200), observedAt: now.addingTimeInterval(-age),
                    evidence: .provider, scope: scope, account: account)
    }

    func testStaleScanCannotClaimThereAreNoInterruptions() {
        let review = DepartureReview(sessions: [], windows: [], scannedAt: now.addingTimeInterval(-61), minutes: 60, now: now)
        XCTAssertEqual(review.items.map(\.kind), [.scan])
        XCTAssertNil(review.items.first?.evidence)
        let missing = DepartureReview(sessions: [], windows: [], scannedAt: nil, minutes: 60, now: now)
        XCTAssertEqual(missing.items.map(\.kind), [.scan])
    }

    func testDecisionsComeFirstAndEndedSessionsAndSubagentsDoNotDuplicateThem() {
        var waiting = session("approval", phase: .needsAttention)
        waiting.attention = .permission
        var full = session("long-task")
        full.contextPercent = 93
        full.contextEvidence = .inferred
        var ended = waiting; ended.id = "ended"; ended.ended = true
        var child = waiting; child.id = "child"; child.isSubagent = true
        var interrupted = session("interrupted", phase: .needsAttention)
        interrupted.attention = .interrupted
        interrupted.updatedAt = now.addingTimeInterval(-100)
        let review = DepartureReview(sessions: [interrupted, full, ended, child, waiting], windows: [window()], scannedAt: now, minutes: 60, now: now)
        XCTAssertEqual(review.items.map(\.kind), [.decision, .decision, .context])
        XCTAssertEqual(review.items.map(\.sessionID), ["approval", "interrupted", "long-task"])
        XCTAssertEqual(review.items.last?.evidence, .inferred)
        XCTAssertEqual(review.workingCount, 1)
    }

    func testMissingQuotaIsPerWorkingAccountAndDoesNotBorrowAnotherAccountOrModelReading() {
        let sessions = [session("one", account: "work"), session("two", account: "work"), session("personal")]
        let review = DepartureReview(sessions: sessions, windows: [window(), window(account: "work", scope: "Fable")],
                                     scannedAt: now, minutes: 60, now: now)
        XCTAssertEqual(review.items.map(\.kind), [.quotaCoverage])
        XCTAssertEqual(review.items.first?.title, "Claude (work)")
        let stale = DepartureReview(sessions: [session("personal")], windows: [window(age: 3600)],
                                    scannedAt: now, minutes: 60, now: now)
        XCTAssertEqual(stale.items.map(\.kind), [.quotaCoverage])
    }

    func testCacheDeadlinesRespectAbsenceDurationAndNeverWarnForAWorkingCache() {
        var quiet = session("quiet", phase: .finished)
        quiet.lastInputTokens = 160_000
        quiet.lastRequestAt = now.addingTimeInterval(-600)
        quiet.cacheMinutes = 60
        var working = quiet; working.id = "working"; working.phase = .working
        let short = DepartureReview(sessions: [quiet, working], windows: [window()], scannedAt: now, minutes: 30, now: now)
        XCTAssertTrue(short.items.isEmpty)
        let long = DepartureReview(sessions: [quiet, working], windows: [window()], scannedAt: now, minutes: 60, now: now)
        XCTAssertEqual(long.items.map(\.kind), [.cache])
        XCTAssertEqual(long.items.first?.deadline, now.addingTimeInterval(3000))
        XCTAssertEqual(long.items.first?.evidence, .inferred)
        quiet.statusCache = StatusCache(warm: true, minutes: 60, expiresAt: now.addingTimeInterval(1200), recacheTokens: 160_000)
        quiet.statusCacheAt = now
        let reported = DepartureReview(sessions: [quiet], windows: [], scannedAt: now, minutes: 30, now: now)
        XCTAssertEqual(reported.items.first?.evidence, .provider)
        XCTAssertEqual(reported.items.first?.observedAt, now)
    }

    func testReportedResumeIsShownOnlyWithinTheSelectedAbsence() {
        var paused = session("paused", phase: .idle)
        paused.resumesAt = now.addingTimeInterval(3600)
        let short = DepartureReview(sessions: [paused], windows: [], scannedAt: now, minutes: 30, now: now)
        XCTAssertTrue(short.items.isEmpty)
        let long = DepartureReview(sessions: [paused], windows: [], scannedAt: now, minutes: 120, now: now)
        XCTAssertEqual(long.items.map(\.kind), [.resume])
        XCTAssertEqual(long.items.first?.deadline, paused.resumesAt)
    }
}
