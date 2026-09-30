import XCTest
@testable import WardenCore

final class PresenceTests: XCTestCase {
    private func date(_ time: String) -> Date { ISO8601DateFormatter().date(from: "2026-09-26T\(time)Z")! }

    func testAWaitingSessionKeepsItsCacheAnHourAfterItsLastRequest() throws {
        // A turn that asks for approval: the tool_use reply wrote an hour-long cache. Claude Code then records a
        // synthetic reply of its own, which is no model request.
        let lines = [
            #"{"parentUuid":null,"isSidechain":false,"promptId":"p1","type":"user","message":{"role":"user","content":"Run the migration"},"uuid":"u1","timestamp":"2026-09-26T11:00:00.000Z","entrypoint":"cli","cwd":"/tmp/app","sessionId":"cache-1"}"#,
            #"{"parentUuid":"u1","isSidechain":false,"type":"assistant","uuid":"a1","timestamp":"2026-09-26T11:02:10.000Z","cwd":"/tmp/app","sessionId":"cache-1","requestId":"r1","message":{"id":"m1","model":"claude-opus-5-5","role":"assistant","stop_reason":"tool_use","content":[{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"make migrate"}}],"usage":{"input_tokens":2,"cache_creation_input_tokens":4280,"cache_read_input_tokens":395718,"output_tokens":410,"cache_creation":{"ephemeral_1h_input_tokens":4280,"ephemeral_5m_input_tokens":0}}}}"#,
            #"{"parentUuid":"a1","isSidechain":false,"type":"assistant","uuid":"a2","timestamp":"2026-09-26T11:02:11.000Z","cwd":"/tmp/app","sessionId":"cache-1","message":{"id":"m2","model":"<synthetic>","role":"assistant","stop_reason":"stop_sequence","content":[{"type":"text","text":"No response requested."}],"usage":{"input_tokens":0,"output_tokens":0}}}"#
        ]
        let data = Data(lines.joined(separator: "\n").appending("\n").utf8)
        let session = try XCTUnwrap(TelemetryParser.claude(head: data, tail: Data("\n".utf8) + data,
                                                            filename: "cache-1.jsonl", modifiedAt: date("11:02:12")))
        XCTAssertEqual(session.modelID, "claude-opus-5-5")
        XCTAssertEqual(session.model, "claude-opus-5-5", "Claude Code's own replies do not name a model.")
        let cache = try XCTUnwrap(PromptCache(session))
        XCTAssertEqual(cache.tokens, 400_000)
        XCTAssertEqual(cache.minutes, 60)
        XCTAssertEqual(cache.expiresAt, date("12:02:10"))
        XCTAssertEqual(cache.remaining(now: date("11:57:10")), 300)
        // Opus 5.5 reads a cached token at $0.20 per million and writes one for an hour at $8.
        XCTAssertEqual(try XCTUnwrap(cache.warm), 0.08, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(cache.cold), 3.2, accuracy: 1e-9)

        // At $1.56 of API value per point of the 5-hour window, a cold start takes about 2 points.
        var period = QuotaPeriod(window: "Claude-five_hour", resetsAt: date("14:00:00"), percent: 40)
        period.dollars = 62.4
        period.pricedPoints = 40
        let quota = QuotaSummary(charges: [], windows: [:], current: ["Claude-five_hour": period], finished: [], coverage: nil)
        let points = try XCTUnwrap(quota.points(forAPIValue: try XCTUnwrap(cache.penalty), window: "Claude-five_hour"))
        XCTAssertEqual(points, 3.12 / 1.56, accuracy: 1e-9)
        XCTAssertTrue(PromptCache.matters(tokens: cache.tokens, points: points))
        XCTAssertFalse(PromptCache.matters(tokens: 60_000, points: 0.3), "A small context is not worth a reminder.")
        XCTAssertNil(quota.points(forAPIValue: 3, window: "Claude-seven_day"), "No rate yet: no estimate.")
    }

    func testAnAbsenceRunsFromYourLastInputUntilYouReturn() throws {
        var tracker = PresenceTracker()
        XCTAssertNil(tracker.update(idle: 30, locked: false, now: date("10:00:00")))
        XCTAssertNil(tracker.awaySince)
        // Two minutes without input start an absence at the last input.
        XCTAssertNil(tracker.update(idle: 130, locked: false, now: date("10:02:10")))
        XCTAssertEqual(tracker.awaySince, date("10:00:00"))
        XCTAssertNil(tracker.update(idle: 1500, locked: true, now: date("10:25:00")))
        // Input four seconds before the scan ends it there.
        let away = try XCTUnwrap(tracker.update(idle: 4, locked: false, now: date("10:40:04")))
        XCTAssertEqual(away, DateInterval(start: date("10:00:00"), end: date("10:40:00")))
        XCTAssertNil(tracker.awaySince)
        // A locked screen counts as away at once, even with recent input.
        XCTAssertNil(tracker.update(idle: 5, locked: true, now: date("11:00:00")))
        XCTAssertEqual(tracker.awaySince, date("10:59:55"))
    }

    func testTheAwaySummarySaysWhatFinishedWhatWaitsAndHowLimitsMoved() {
        let away = DateInterval(start: date("10:00:00"), end: date("10:50:00"))
        func session(_ id: String, _ phase: AgentPhase, _ attention: AttentionKind? = nil, title: String?,
                     at time: String) -> AgentSession {
            AgentSession(id: id, provider: .claude, surface: "Terminal", cwd: "/tmp/\(id)", phase: phase,
                         attention: attention, updatedAt: date(time), title: title)
        }
        let sessions = [
            session("app", .finished, title: "Fix the header", at: "10:31:00"),
            session("api", .needsAttention, .permission, title: "Harden deploy", at: "10:12:00"),
            session("old", .finished, title: "Earlier work", at: "09:40:00")
        ]
        let spans = [
            ActivitySpan(session: "app", provider: .claude, project: "/tmp/app", kind: .working, start: date("09:55:00"), end: date("10:31:00")),
            ActivitySpan(session: "api", provider: .claude, project: "/tmp/api", kind: .working, start: date("10:00:00"), end: date("10:12:00")),
            ActivitySpan(session: "api", provider: .claude, project: "/tmp/api", kind: .waiting, attention: .permission,
                         start: date("10:12:00"), end: date("10:50:00"))
        ]
        func window(_ id: String, _ used: Double, resets: String, at time: String, minutes: Int) -> UsageWindow {
            UsageWindow(id: id, provider: .claude, label: minutes == 300 ? "5h" : "7d", usedPercent: used, resetsAt: date(resets),
                        observedAt: date(time), evidence: .provider, minutes: minutes)
        }
        let before = [window("Claude-five_hour", 96, resets: "10:20:00", at: "09:59:00", minutes: 300),
                      window("Claude-seven_day", 40, resets: "23:00:00", at: "09:59:00", minutes: 10_080)]
        let after = [window("Claude-five_hour", 12, resets: "15:20:00", at: "10:48:00", minutes: 300),
                     window("Claude-seven_day", 47, resets: "23:00:00", at: "10:48:00", minutes: 10_080)]
        let digest = AwayDigest(away: away, sessions: sessions, spans: spans, before: before, windows: after, now: date("10:50:04"))
        XCTAssertEqual(digest.lines.count, 5)
        XCTAssertTrue(digest.lines[0].hasPrefix("1 session finished: “Fix the header” (app)"))
        XCTAssertTrue(digest.lines[1].contains("“Harden deploy” (api)"))
        XCTAssertTrue(digest.lines[1].contains("since \(date("10:12:00").formatted(date: .omitted, time: .shortened))"))
        // 31 minutes of one session's work fall in the absence, and 12 of the other's; it then waited 38 minutes.
        XCTAssertEqual(digest.lines[2], "Agents worked 43 min and waited 38 min for you.")
        XCTAssertTrue(digest.lines[3].hasPrefix("Claude 5h reset at"))
        XCTAssertTrue(digest.lines[3].hasSuffix("; 12% used since."))
        XCTAssertTrue(digest.lines[4].hasPrefix("Claude 7d rose 7 points to 47%."))
        XCTAssertEqual(digest.headline, "1 finished · 1 needs you · Claude 5h reset")
        XCTAssertEqual(digest.firstWaiting, "api")

        // Nothing happened: no summary.
        let quiet = AwayDigest(away: away, sessions: [sessions[2]], spans: [], before: after, windows: after, now: date("10:50:04"))
        XCTAssertTrue(quiet.isEmpty)
    }

    func testAutomationEventsNameEachAlert() throws {
        XCTAssertEqual(AutomationEvent.name(forAlert: "approval-9F2"), "needs-you")
        XCTAssertEqual(AutomationEvent.name(forAlert: "attention-s1-1790"), "needs-you")
        XCTAssertEqual(AutomationEvent.name(forAlert: "restored-Claude-five_hour-1790"), "quota-available")
        XCTAssertEqual(AutomationEvent.name(forAlert: "pace-Codex-primary-1790"), "limit-warning")
        XCTAssertEqual(AutomationEvent.name(forAlert: "cache-s1-1790"), "cache-expiring")
        let event = AutomationEvent(event: "needs-you", at: date("10:00:00"), title: "Claude · app: Fix the header",
                                    message: "Waiting for approval to use Bash", session: "s1", agent: "Claude",
                                    project: "/tmp/app", alerted: false)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: event.json) as? [String: Any])
        XCTAssertEqual(object["event"] as? String, "needs-you")
        XCTAssertEqual(object["at"] as? String, "2026-09-26T10:00:00Z")
        XCTAssertEqual(object["alerted"] as? Bool, false)
        XCTAssertEqual(event.environment["WARDEN_PROJECT"], "/tmp/app")
        XCTAssertNil(event.environment["WARDEN_ACCOUNT"])
    }
}
