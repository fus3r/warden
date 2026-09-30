import XCTest
@testable import WardenCore

final class SignalsTests: XCTestCase {
    private func date(_ time: String) -> Date { ISO8601DateFormatter().date(from: "2026-09-26T\(time)Z")! }

    private func transcript(_ lines: [String], id: String, modified: String) throws -> AgentSession {
        let data = Data(lines.joined(separator: "\n").appending("\n").utf8)
        return try XCTUnwrap(TelemetryParser.claude(head: data, tail: Data("\n".utf8) + data, filename: "\(id).jsonl",
                                                    modifiedAt: date(modified)))
    }

    private let waitingForApproval = [
        #"{"parentUuid":null,"isSidechain":false,"promptId":"p1","type":"user","message":{"role":"user","content":"Deploy it"},"uuid":"u1","timestamp":"2026-09-26T11:00:00.000Z","entrypoint":"cli","cwd":"/tmp/app","sessionId":"s1"}"#,
        #"{"parentUuid":"u1","isSidechain":false,"type":"assistant","uuid":"a1","timestamp":"2026-09-26T11:02:00.000Z","cwd":"/tmp/app","sessionId":"s1","requestId":"r1","message":{"id":"m1","model":"claude-opus-5-5","role":"assistant","stop_reason":"tool_use","content":[{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"make deploy"}}],"usage":{"input_tokens":2,"cache_creation_input_tokens":2000,"cache_read_input_tokens":298000,"output_tokens":90,"cache_creation":{"ephemeral_1h_input_tokens":2000,"ephemeral_5m_input_tokens":0}}}}"#
    ]

    func testClaudeCodesOwnCacheReportWinsOverTheLogWhenItIsNewer() throws {
        let session = try transcript(waitingForApproval, id: "s1", modified: "11:02:01")
        // The status line Claude Code 2.1.283 prints after that reply, as its `prompt_cache` object documents it.
        let line = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(#"""
        {"warm":true,"caching_observed":true,"ttl":"1h","expires_at":1790427721,"requests":41,"misses":2,
         "expected_rebuilds":1,"hit_ratio":0.962,"cache_write_tokens":912000,"miss_recache_tokens":520000,
         "last_miss_at":1790420000,"last_miss_cause":{"causes":["tools_changed"],"tools_added":3},
         "miss_causes":{"tools_changed":1,"ttl_expired_1h":1},"recache_tokens_if_cold":301500}
        """#.utf8)) as? [String: Any])
        let cache = try XCTUnwrap(StatusCache(statusLine: line))
        XCTAssertEqual(cache.minutes, 60)
        XCTAssertEqual(cache.lastMissCauses, ["tools_changed"])
        let status = BridgeStatus(sessionID: "s1", cwd: "/tmp/app", model: "Opus 5.5", contextPercent: 30, totalTokens: nil,
                                  windows: [], updatedAt: date("11:02:02"), modelID: "claude-opus-5-5", cache: cache)
        let merged = TelemetryParser.merge(session, status: status, event: nil)
        let reported = try XCTUnwrap(PromptCache(merged))
        XCTAssertEqual(reported.evidence, .provider)
        XCTAssertEqual(reported.tokens, 301_500)
        XCTAssertEqual(reported.expiresAt, Date(timeIntervalSince1970: 1790427721))
        XCTAssertEqual(PromptCache.cause("tools_changed"), "the tools changed")
        // The status line names the long-context variant, as "claude-opus-5-5[1m]" in 2.1.283.
        XCTAssertEqual(Pricing.price(for: "claude-opus-5-5[1m]"), Pricing.price(for: "claude-opus-5-5"))
        XCTAssertNil(Pricing.price(for: "claude-opus-5-6[1m]"))

        // A status line written before the log's last request describes an older cache: the log decides.
        var older = status
        older.updatedAt = date("11:01:00")
        let estimated = try XCTUnwrap(PromptCache(TelemetryParser.merge(session, status: older, event: nil)))
        XCTAssertEqual(estimated.evidence, .localLog)
        XCTAssertEqual(estimated.tokens, 300_002)
        XCTAssertEqual(estimated.expiresAt, date("12:02:00"))

        // No cache tokens reported: no cache to lose.
        XCTAssertNil(StatusCache(statusLine: ["warm": false, "caching_observed": false, "expires_at": NSNull()]))
    }

    func testAResetSleptThroughWaitsForYouInsteadOfResumingAlone() throws {
        // The limit stopped the turn and Claude Code said it would continue at the reset.
        let lines = [
            #"{"parentUuid":null,"isSidechain":false,"promptId":"p1","type":"user","message":{"role":"user","content":"Run the audit"},"uuid":"u1","timestamp":"2026-09-26T09:38:58.000Z","entrypoint":"cli","cwd":"/tmp/audit","sessionId":"s2"}"#,
            #"{"parentUuid":"u1","isSidechain":false,"type":"assistant","uuid":"a2","timestamp":"2026-09-26T09:39:40.584Z","error":"rate_limit","isApiErrorMessage":true,"quotaLimits":{"status":"rejected","resetsAt":1790409600,"rateLimitType":"five_hour"},"cwd":"/tmp/audit","sessionId":"s2","message":{"id":"m2","model":"<synthetic>","role":"assistant","stop_reason":"stop_sequence","content":[{"type":"text","text":"You've hit your session limit"}],"usage":{"input_tokens":0,"output_tokens":0}}}"#,
            #"{"parentUuid":"a2","isSidechain":false,"type":"system","subtype":"informational","content":"Usage limit reached · continuing automatically at 10:00am · esc or type to cancel","level":"info","timestamp":"2026-09-26T09:39:40.600Z","cwd":"/tmp/audit","sessionId":"s2"}"#
        ]
        let session = try transcript(lines, id: "s2", modified: "09:39:41")
        XCTAssertNotNil(session.resumesAt)
        // The Mac slept through the reset; Claude Code now waits for Enter and says so through its Notification hook.
        let kind = try XCTUnwrap(ClaudeHookEvent.kind(event: "Notification", notification: "quota_auto_resume_stale"))
        let stale = BridgeEvent(id: "e1", sessionID: "s2", cwd: "/tmp/audit", kind: kind, at: date("12:05:00"),
                                detail: "quota_auto_resume_stale")
        let waiting = TelemetryParser.merge(session, status: nil, event: stale)
        XCTAssertEqual(waiting.phase, .needsAttention)
        XCTAssertEqual(waiting.attention, .failure)
        XCTAssertNil(waiting.resumesAt)
        XCTAssertEqual(waiting.detail, "quota_auto_resume_stale")
        // When it does continue by itself, it works again.
        let fired = BridgeEvent(id: "e2", sessionID: "s2", cwd: "/tmp/audit",
                                kind: try XCTUnwrap(ClaudeHookEvent.kind(event: "Notification", notification: "quota_auto_resume_fired")),
                                at: date("10:00:05"))
        let resumed = TelemetryParser.merge(session, status: nil, event: fired)
        XCTAssertEqual(resumed.phase, .working)
        XCTAssertNil(resumed.resumesAt)
    }

    func testAStatusPageIncidentIsNamedOnlyForTheServicesAnAgentUses() throws {
        let claude = Data(#"""
        {"page":{"id":"tymt9n04zgry","name":"Claude","url":"https://status.claude.com"},
         "status":{"indicator":"minor","description":"Partially Degraded Service"},
         "components":[{"id":"a","name":"claude.ai","status":"operational","group":false},
                       {"id":"b","name":"Claude API (api.anthropic.com)","status":"degraded_performance","group":false},
                       {"id":"c","name":"Claude Code","status":"partial_outage","group":false}],
         "incidents":[{"id":"i1","name":"Elevated errors on Claude Opus 5.5","status":"investigating","impact":"minor",
                       "components":[{"id":"b","name":"Claude API (api.anthropic.com)","status":"degraded_performance"}]}]}
        """#.utf8)
        XCTAssertEqual(ProviderStatus.incident(from: claude, provider: .claude, checkedAt: date("10:00:00"))?.summary,
                       "Elevated errors on Claude Opus 5.5")
        // OpenAI's page lists no incidents in its summary; a degraded component the CLI uses still tells.
        let openAI = Data(#"""
        {"page":{"id":"01J","name":"OpenAI"},"status":{"description":"Partial System Outage","indicator":"major"},
         "components":[{"id":"x","name":"Images","status":"major_outage"},{"id":"y","name":"CLI","status":"degraded_performance"},
                       {"id":"z","name":"Codex API","status":"operational"}]}
        """#.utf8)
        XCTAssertEqual(ProviderStatus.incident(from: openAI, provider: .codex, checkedAt: date("10:00:00"))?.summary,
                       "CLI: degraded performance")
        // An outage elsewhere, such as image generation, is not the agent's problem.
        let unrelated = Data(#"{"components":[{"name":"Images","status":"major_outage"},{"name":"CLI","status":"operational"}]}"#.utf8)
        XCTAssertNil(ProviderStatus.incident(from: unrelated, provider: .codex, checkedAt: date("10:00:00")))
        XCTAssertTrue(ProviderStatus.mayBeProvider("overloaded"))
        XCTAssertFalse(ProviderStatus.mayBeProvider("rate_limit"), "A usage limit is the account's, not an incident.")
    }

    func testAPlanPriceSpreadsOverItsWeeklyLimitOnly() throws {
        let week = UsageWindow(id: "Claude-seven_day", provider: .claude, label: "7d", usedPercent: 14, resetsAt: date("23:00:00"),
                               observedAt: date("10:00:00"), evidence: .provider, minutes: 10_080)
        let prices = [PlanPrice.key(provider: .claude, account: nil): 200.0]
        // $200 a month is $46.15 a week, so $0.46 a point.
        XCTAssertEqual(try XCTUnwrap(PlanPrice.perPoint(week, prices: prices)), 200 * 12 / 52 / 100, accuracy: 1e-9)
        var fable = week
        fable.id = "Claude-model-fable"
        fable.scope = "Fable"
        XCTAssertNil(PlanPrice.perPoint(fable, prices: prices), "A model's own limit paces use within the week.")
        var hours = week
        hours.id = "Claude-five_hour"
        hours.minutes = 300
        XCTAssertNil(PlanPrice.perPoint(hours, prices: prices))
        var work = week
        work.account = "work"
        XCTAssertNil(PlanPrice.perPoint(work, prices: prices), "Each account has its own price.")
    }
}
