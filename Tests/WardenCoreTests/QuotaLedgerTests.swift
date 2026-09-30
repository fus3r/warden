import XCTest
@testable import WardenCore

final class QuotaLedgerTests: XCTestCase {
    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private func date(_ time: String) -> Date { ISO8601DateFormatter().date(from: "2026-09-26T\(time)Z")! }

    private func directory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }

    /// The Claude 5-hour window, as the status line reports it: whole percentages and a reset on the hour.
    private func fiveHour(_ used: Double, at time: String, resets: String = "12:00:00") -> UsageWindow {
        UsageWindow(id: "Claude-five_hour", provider: .claude, label: "5h", usedPercent: used,
                    resetsAt: date(resets), observedAt: date(time), evidence: .provider, minutes: 300)
    }

    private func use(_ session: String, _ project: String, at time: String, model: String = "claude-opus-5-5",
                     output: Int = 1_000, provider: AgentProvider = .claude) -> UsageEvent {
        UsageEvent(at: date(time), provider: provider, session: session, project: project, model: model,
                   usage: TokenUsage(input: 10, cacheRead: 40_000, output: output, requests: 1))
    }

    func testRisesAreSplitAmongTheSessionsThatUsedTokensBeforeThem() throws {
        let ledger = QuotaLedger(directory: directory(), calendar: utc)
        let a = use("s1", "/tmp/app", at: "07:30:00")
        let b = use("s2", "/tmp/site", at: "08:00:00", model: "claude-sonnet-5")
        // The window started at 07:00, before the logs' coverage ends, so its first 20% is split from its start.
        var summary = ledger.update(events: [a, b], readings: [fiveHour(20, at: "09:00:00")], readAt: date("09:00:10"),
                                    coverage: date("06:00:00"))
        let first = try XCTUnwrap(summary.current["Claude-five_hour"])
        let weights = [a.weight, b.weight]
        XCTAssertEqual(first.sessions["s1"] ?? 0, 20 * weights[0] / (weights[0] + weights[1]), accuracy: 1e-9)
        XCTAssertEqual(first.attributed, 20, accuracy: 1e-9)
        XCTAssertEqual(first.dollars, weights.reduce(0, +), accuracy: 1e-9)

        // An idle session's status line repeats an older value; only the rise to 26% counts, all of it to s1.
        summary = ledger.update(events: [use("s1", "/tmp/app", at: "09:10:00")],
                                readings: [fiveHour(19, at: "09:20:00"), fiveHour(26, at: "09:30:00")], readAt: date("09:30:02"))
        XCTAssertEqual(summary.current["Claude-five_hour"]?.attributed ?? 0, 20, accuracy: 1e-9,
                       "A reading waits until the logs are read past its time.")
        summary = ledger.update(events: [], readings: [], readAt: date("09:31:00"))
        let points = summary.points(session: "s1")
        XCTAssertEqual(points.first?.window.id, "Claude-five_hour")
        XCTAssertEqual(points.first?.points ?? 0, 20 * weights[0] / (weights[0] + weights[1]) + 6, accuracy: 1e-9)
        XCTAssertEqual(summary.projects(window: "Claude-five_hour", firstDay: "2026-09-26").map(\.project), ["/tmp/app", "/tmp/site"])

        // A rise with no local use is someone else's, such as a chat on the web.
        summary = ledger.update(events: [], readings: [fiveHour(30, at: "10:00:00")], readAt: date("10:01:00"))
        XCTAssertEqual(summary.current["Claude-five_hour"]?.unexplained ?? 0, 4, accuracy: 1e-9)
        XCTAssertEqual(summary.projects(inCurrent: "Claude-five_hour").last?.project, nil)

        // The next window starts at 12:00 from zero; use after the old window's last rise is not charged to it.
        summary = ledger.update(events: [use("s1", "/tmp/app", at: "11:50:00"), use("s2", "/tmp/site", at: "12:10:00")],
                                readings: [fiveHour(3, at: "12:30:00", resets: "17:00:00")], readAt: date("12:31:00"))
        let next = try XCTUnwrap(summary.current["Claude-five_hour"])
        XCTAssertEqual(next.sessions, ["s2": 3])
        let ended = try XCTUnwrap(summary.finished.first)
        XCTAssertEqual(ended.percent, 30)
        XCTAssertEqual(ended.attributed + ended.unexplained, 30, accuracy: 1e-9)
        XCTAssertTrue(ended.sessions.isEmpty)
    }

    func testEveryLimitOfAnAccountReadForTheFirstTimeIsSplitFromItsStart() throws {
        let ledger = QuotaLedger(directory: directory(), calendar: utc)
        let week = UsageWindow(id: "Claude-seven_day", provider: .claude, label: "7d", usedPercent: 8,
                               resetsAt: date("08:00:00").addingTimeInterval(6 * 86_400), observedAt: date("09:00:00"),
                               evidence: .provider, minutes: 10_080)
        let summary = ledger.update(events: [use("s1", "/tmp/app", at: "07:30:00"), use("s2", "/tmp/site", at: "08:30:00")],
                                    readings: [fiveHour(20, at: "09:00:00"), week], readAt: date("09:00:10"),
                                    coverage: date("00:00:00").addingTimeInterval(-86_400))
        XCTAssertEqual(try XCTUnwrap(summary.current["Claude-seven_day"]).attributed, 8, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(summary.current["Claude-five_hour"]).attributed, 20, accuracy: 1e-9)
    }

    func testAWindowThatStartedBeforeTheLogsWereCoveredCountsOnlyItsLaterRises() {
        let ledger = QuotaLedger(directory: directory(), calendar: utc)
        let week = UsageWindow(id: "Claude-seven_day", provider: .claude, label: "7d", usedPercent: 40,
                               resetsAt: date("12:00:00").addingTimeInterval(86_400), observedAt: date("09:00:00"),
                               evidence: .provider, minutes: 10_080)
        var summary = ledger.update(events: [use("s1", "/tmp/app", at: "08:00:00")], readings: [week], readAt: date("09:00:10"),
                                    coverage: date("06:00:00"))
        XCTAssertEqual(summary.current["Claude-seven_day"]?.attributed, 0)
        var later = week
        later.usedPercent = 41
        later.observedAt = date("10:00:00")
        summary = ledger.update(events: [use("s1", "/tmp/app", at: "09:30:00")], readings: [later], readAt: date("10:00:10"))
        XCTAssertEqual(summary.current["Claude-seven_day"]?.sessions, ["s1": 1])
    }

    func testACodexModelWithItsOwnLimitIsNotChargedToThePlanLimit() {
        let ledger = QuotaLedger(directory: directory(), calendar: utc)
        func codex(_ id: String, _ used: Double, scope: String?, at time: String) -> UsageWindow {
            UsageWindow(id: id, provider: .codex, label: "7d", usedPercent: used, resetsAt: date("12:00:00").addingTimeInterval(3 * 86_400),
                        observedAt: date(time), evidence: .localLog, minutes: 10_080, scope: scope)
        }
        _ = ledger.update(events: [], readings: [codex("Codex-primary", 10, scope: nil, at: "08:00:00"),
                                                 codex("Codex-spark-primary", 5, scope: "Spark", at: "08:00:00")],
                          readAt: date("08:00:10"), coverage: date("07:00:00").addingTimeInterval(-8 * 86_400))
        let summary = ledger.update(events: [use("t1", "/tmp/app", at: "08:10:00", model: "gpt-6-sol", provider: .codex),
                                             use("t2", "/tmp/fast", at: "08:20:00", model: "gpt-5.3-codex-spark", provider: .codex)],
                                    readings: [codex("Codex-primary", 12, scope: nil, at: "08:30:00"),
                                               codex("Codex-spark-primary", 9, scope: "Spark", at: "08:30:00")],
                                    readAt: date("08:31:00"))
        XCTAssertEqual(summary.current["Codex-primary"]?.sessions, ["t1": 2])
        XCTAssertEqual(summary.current["Codex-spark-primary"]?.sessions, ["t2": 4])
        // Codex models have no bundled price, so the rise is split without an API value.
        XCTAssertNil(summary.exchange(window: "Codex-primary").current)
    }

    func testTheLedgerKeepsItsStateAcrossRelaunches() {
        let folder = directory()
        let ledger = QuotaLedger(directory: folder, calendar: utc)
        _ = ledger.update(events: [use("s1", "/tmp/app", at: "07:30:00")], readings: [fiveHour(10, at: "08:00:00")],
                          readAt: date("08:00:10"), coverage: date("06:00:00"))
        ledger.flush(now: date("08:00:10"))
        let relaunched = QuotaLedger(directory: folder, calendar: utc)
        XCTAssertFalse(relaunched.needsBackfill)
        let summary = relaunched.update(events: [use("s1", "/tmp/app", at: "08:10:00")], readings: [fiveHour(12, at: "08:20:00")],
                                        readAt: date("08:21:00"))
        XCTAssertEqual(summary.current["Claude-five_hour"]?.sessions, ["s1": 12])
    }

    func testALimitThatNeverRisesKeepsNoOtherUse() {
        let ledger = QuotaLedger(directory: directory(), calendar: utc)
        let fable = UsageWindow(id: "Claude-model-fable", provider: .claude, label: "7d", usedPercent: 0,
                                resetsAt: date("12:00:00").addingTimeInterval(3 * 86_400), observedAt: date("08:00:00"),
                                evidence: .provider, minutes: 10_080, scope: "Fable")
        _ = ledger.update(events: [use("s1", "/tmp/app", at: "07:30:00")], readings: [fiveHour(10, at: "08:00:00"), fable],
                          readAt: date("08:00:10"), coverage: date("06:00:00"))
        XCTAssertEqual(ledger.heldUses, 0, "Opus use before the last rise of the 5-hour limit can no longer be split.")
        _ = ledger.update(events: [use("s1", "/tmp/app", at: "08:10:00")], readings: [], readAt: date("08:20:00"))
        XCTAssertEqual(ledger.heldUses, 1)
    }

    private func week(_ used: Double, at time: String, resets: Date) -> UsageWindow {
        UsageWindow(id: "Claude-seven_day", provider: .claude, label: "7d", usedPercent: used, resetsAt: resets,
                    observedAt: date(time), evidence: .provider, minutes: 10_080)
    }

    /// A provider can move a window's reset later without starting a new window; the rise is split once.
    func testAResetMovedLaterInTheSameWindowIsNotANewWindow() throws {
        let ledger = QuotaLedger(directory: directory(), calendar: utc)
        let reset = date("12:00:00").addingTimeInterval(3 * 86_400)
        _ = ledger.update(events: [use("s1", "/tmp/app", at: "08:30:00")], readings: [week(60, at: "09:00:00", resets: reset)],
                          readAt: date("09:00:10"), coverage: date("00:00:00"))
        let summary = ledger.update(events: [use("s3", "/tmp/site", at: "09:10:00")],
                                    readings: [week(61, at: "09:20:00", resets: reset.addingTimeInterval(3600))], readAt: date("09:21:00"))
        XCTAssertEqual(summary.current["Claude-seven_day"]?.sessions["s3"] ?? 0, 1, accuracy: 1e-9)
        XCTAssertTrue(summary.finished.isEmpty)
        XCTAssertEqual(summary.current["Claude-seven_day"]?.resetsAt, reset.addingTimeInterval(3600))
    }

    /// A reading without a reset time, as when no window is open, must not make an older reading look new.
    func testAReadingWithoutAResetKeepsTheKnownOne() throws {
        let ledger = QuotaLedger(directory: directory(), calendar: utc)
        _ = ledger.update(events: [use("s1", "/tmp/app", at: "08:30:00")], readings: [fiveHour(30, at: "09:00:00")],
                          readAt: date("09:00:10"), coverage: date("06:00:00"))
        var empty = fiveHour(0, at: "09:10:00")
        empty.resetsAt = nil
        let stale = fiveHour(30, at: "09:20:00")
        let summary = ledger.update(events: [use("s2", "/tmp/site", at: "09:15:00")], readings: [empty, stale], readAt: date("09:21:00"))
        XCTAssertEqual(summary.current["Claude-five_hour"]?.attributed ?? 0, 30, accuracy: 1e-9)
        XCTAssertTrue(summary.finished.isEmpty)
    }

    /// A single low reading is an idle session's old answer; a drop that holds for ten minutes restarts the window.
    func testOnlyALastingDropRestartsAWindow() throws {
        let ledger = QuotaLedger(directory: directory(), calendar: utc)
        _ = ledger.update(events: [use("s1", "/tmp/app", at: "07:30:00")], readings: [fiveHour(80, at: "08:00:00")],
                          readAt: date("08:00:10"), coverage: date("06:00:00"))
        var summary = ledger.update(events: [], readings: [fiveHour(5, at: "08:05:00"), fiveHour(80, at: "08:06:00")], readAt: date("08:07:00"))
        XCTAssertTrue(summary.finished.isEmpty)
        summary = ledger.update(events: [use("s2", "/tmp/site", at: "08:12:00")],
                                readings: [fiveHour(5, at: "08:10:00"), fiveHour(40, at: "08:30:00")], readAt: date("08:31:00"))
        XCTAssertEqual(summary.finished.first?.percent, 80)
        XCTAssertEqual(summary.current["Claude-five_hour"]?.sessions["s2"] ?? 0, 35, accuracy: 1e-9)
    }

    /// Lines read again, as after a crash that lost the logs' read positions, do not weigh twice.
    func testUseReadTwiceWeighsOnce() throws {
        let ledger = QuotaLedger(directory: directory(), calendar: utc)
        _ = ledger.update(events: [], readings: [fiveHour(10, at: "08:00:00")], readAt: date("08:00:10"), coverage: date("06:00:00"))
        let once = use("s1", "/tmp/app", at: "08:10:00")
        let summary = ledger.update(events: [once, once, use("s2", "/tmp/site", at: "08:12:00")],
                                    readings: [fiveHour(12, at: "08:20:00")], readAt: date("08:21:00"))
        XCTAssertEqual(summary.current["Claude-five_hour"]?.sessions["s1"] ?? 0, 1, accuracy: 1e-9)
    }

    /// An account whose limits are never read keeps six hours of use once the ledger has run an hour. A first reading
    /// later is split from its window's start only if that start is within the use still held.
    func testAnAccountWithoutReadingsKeepsSixHoursOfUse() throws {
        let ledger = QuotaLedger(directory: directory(), calendar: utc)
        let dayBefore = date("00:30:00").addingTimeInterval(-86_400)
        _ = ledger.update(events: [UsageEvent(at: dayBefore, provider: .claude, session: "s0", project: "/tmp/app", model: "claude-opus-5-5",
                                              usage: TokenUsage(input: 10, cacheRead: 40_000, output: 1_000, requests: 1))],
                          readings: [], readAt: date("01:00:00"), coverage: date("00:00:00").addingTimeInterval(-3 * 86_400))
        _ = ledger.update(events: [use("s1", "/tmp/app", at: "08:30:00")], readings: [], readAt: date("09:00:00"))
        XCTAssertEqual(ledger.heldUses, 1, "Use older than six hours goes once the ledger has run an hour.")
        // The week began yesterday, before the use let go: only its later rises can be split.
        let week = UsageWindow(id: "Claude-seven_day", provider: .claude, label: "7d", usedPercent: 12,
                               resetsAt: date("00:00:00").addingTimeInterval(6 * 86_400), observedAt: date("09:10:00"),
                               evidence: .provider, minutes: 10_080)
        // The five hours began at 07:00, after it: the held use takes its whole rise.
        let summary = ledger.update(events: [], readings: [week, fiveHour(20, at: "09:10:00", resets: "12:00:00")], readAt: date("09:11:00"))
        XCTAssertEqual(summary.current["Claude-seven_day"]?.attributed ?? -1, 0)
        XCTAssertEqual(summary.current["Claude-five_hour"]?.sessions["s1"] ?? 0, 20, accuracy: 1e-9)
    }

    func testHistoryReplaysLinesItAlreadyCountedForTheirTimesOnlyOnce() throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let account = AgentAccount(provider: .claude, folder: root.appendingPathComponent("claude"), name: nil)
        let folder = account.sessions.appendingPathComponent("-tmp-app")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("s1.jsonl")
        func reply(_ id: String, at time: String) -> String {
            #"{"type":"assistant","timestamp":"2026-09-26T\#(time)Z","cwd":"/tmp/app","sessionId":"s1","requestId":"r\#(id)","message":{"id":"m\#(id)","model":"claude-opus-5-5","role":"assistant","usage":{"input_tokens":5,"cache_read_input_tokens":1000,"output_tokens":50}}}"#
        }
        try Data((reply("1", at: "08:00:00") + "\n").utf8).write(to: file)
        let history = UsageHistory(directory: root.appendingPathComponent("history"))
        let now = date("09:00:00")
        let first = history.update(accounts: [account], now: now)
        XCTAssertEqual(first.records.first?.usage.requests, 1)
        XCTAssertTrue(first.events.isEmpty)

        try Data((reply("1", at: "08:00:00") + "\n" + reply("2", at: "08:30:00") + "\n").utf8).write(to: file)
        let second = history.update(accounts: [account], now: now.addingTimeInterval(60), events: true,
                                    eventsSince: date("00:00:00"))
        XCTAssertEqual(second.events.map { $0.at }, [date("08:00:00"), date("08:30:00")])
        XCTAssertEqual(second.events.map(\.session), ["s1", "s1"])
        XCTAssertEqual(second.records.reduce(0) { $0 + $1.usage.requests }, 2)

        // A branch copied the first reply before Warden kept owners: the one-time replay still weighs it once.
        let copy = reply("1", at: "08:00:00").replacingOccurrences(of: #""sessionId":"s1""#, with: #""sessionId":"s2""#)
        let branch = folder.appendingPathComponent("s2.jsonl")
        try Data((copy + "\n").utf8).write(to: branch)
        let fresh = UsageHistory(directory: root.appendingPathComponent("history-2"))
        _ = fresh.update(accounts: [account], now: now)
        let replayed = fresh.update(accounts: [account], now: now.addingTimeInterval(60), events: true, eventsSince: date("00:00:00"))
        XCTAssertEqual(replayed.events.filter { $0.at == date("08:00:00") }.count, 1)
    }
}
