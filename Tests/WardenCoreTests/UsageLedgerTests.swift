import XCTest
@testable import WardenCore

final class UsageLedgerTests: XCTestCase {
    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    /// Claude Code writes one entry per content block of a reply. Each repeats the reply's usage, and the output
    /// count can grow in the last one while the reply streams.
    private let claudeLines = [
        #"{"parentUuid":null,"isSidechain":false,"promptId":"p1","type":"user","message":{"role":"user","content":"Fix the parser"},"uuid":"u1","timestamp":"2026-09-24T08:00:00.000Z","cwd":"/tmp/app","sessionId":"s1"}"#,
        #"{"parentUuid":"u1","isSidechain":false,"message":{"model":"claude-opus-5-5","id":"msg_1","type":"message","role":"assistant","content":[{"type":"thinking","thinking":"","signature":"x"}],"stop_reason":null,"usage":{"input_tokens":2,"cache_creation_input_tokens":3000,"cache_read_input_tokens":40000,"cache_creation":{"ephemeral_5m_input_tokens":1000,"ephemeral_1h_input_tokens":2000},"output_tokens":7}},"requestId":"req_1","type":"assistant","uuid":"a1","timestamp":"2026-09-24T08:00:05.000Z","cwd":"/tmp/app","sessionId":"s1"}"#,
        #"{"parentUuid":"a1","isSidechain":false,"message":{"model":"claude-opus-5-5","id":"msg_1","type":"message","role":"assistant","content":[{"type":"text","text":"Reading it."}],"stop_reason":null,"usage":{"input_tokens":2,"cache_creation_input_tokens":3000,"cache_read_input_tokens":40000,"cache_creation":{"ephemeral_5m_input_tokens":1000,"ephemeral_1h_input_tokens":2000},"output_tokens":7}},"requestId":"req_1","type":"assistant","uuid":"a2","timestamp":"2026-09-24T08:00:05.100Z","cwd":"/tmp/app","sessionId":"s1"}"#,
        #"{"parentUuid":"a2","isSidechain":false,"message":{"model":"claude-opus-5-5","id":"msg_1","type":"message","role":"assistant","content":[{"type":"tool_use","id":"toolu_1","name":"Read","input":{"file_path":"/tmp/app/parser.swift"}}],"stop_reason":"tool_use","usage":{"input_tokens":2,"cache_creation_input_tokens":3000,"cache_read_input_tokens":40000,"cache_creation":{"ephemeral_5m_input_tokens":1000,"ephemeral_1h_input_tokens":2000},"output_tokens":150}},"requestId":"req_1","type":"assistant","uuid":"a3","timestamp":"2026-09-24T08:00:06.000Z","cwd":"/tmp/app","sessionId":"s1"}"#,
        #"{"parentUuid":"a3","isSidechain":false,"promptId":"p1","type":"user","message":{"role":"user","content":[{"tool_use_id":"toolu_1","type":"tool_result","content":"struct Parser {}"}]},"uuid":"u2","timestamp":"2026-09-24T08:00:06.500Z","cwd":"/tmp/app","sessionId":"s1"}"#,
        #"{"parentUuid":"u2","isSidechain":false,"message":{"model":"claude-opus-5-5","id":"msg_2","type":"message","role":"assistant","content":[{"type":"text","text":"Fixed."}],"stop_reason":"end_turn","usage":{"input_tokens":1,"cache_creation_input_tokens":500,"cache_read_input_tokens":43000,"cache_creation":{"ephemeral_5m_input_tokens":0,"ephemeral_1h_input_tokens":500},"output_tokens":40}},"requestId":"req_2","type":"assistant","uuid":"a4","timestamp":"2026-09-24T08:00:09.000Z","cwd":"/tmp/app","sessionId":"s1"}"#,
        // A failed request is written as a synthetic reply without usage that counts.
        #"{"parentUuid":"a4","isSidechain":false,"type":"assistant","uuid":"a5","timestamp":"2026-09-24T08:01:00.000Z","error":"rate_limit","isApiErrorMessage":true,"cwd":"/tmp/app","sessionId":"s1","message":{"id":"m3","model":"<synthetic>","role":"assistant","content":[{"type":"text","text":"You've hit your limit"}],"usage":{"input_tokens":0,"output_tokens":0}}}"#
    ]

    func testClaudeRepliesCountOnceWithTheirFinalOutput() throws {
        let data = Data((claudeLines.joined(separator: "\n") + "\n").utf8)
        var cursor = LedgerCursor()
        XCTAssertTrue(UsageLedger.read(data, provider: .claude, cursor: &cursor, calendar: utc))
        XCTAssertEqual(cursor.offset, UInt64(data.count))
        let record = try XCTUnwrap(cursor.records.first)
        XCTAssertEqual(cursor.records.count, 1)
        XCTAssertEqual(record.day, "2026-09-24")
        XCTAssertEqual(record.model, "claude-opus-5-5")
        XCTAssertEqual(record.project, "/tmp/app")
        XCTAssertEqual(record.usage, TokenUsage(input: 3, cacheWrite: 1000, cacheWriteHour: 2500, cacheRead: 83000,
                                                output: 190, requests: 2))

        // Opus 5.5 at $4 input, $20 output, $0.20 cache reads; writes at 1.25x and 2x input.
        let price = try XCTUnwrap(Pricing.price(for: record.model))
        let dollars: [Double] = [3 * 4, 190 * 20, 1000 * 5, 2500 * 8, 83000 * 0.2]
        XCTAssertEqual(price.cost(of: record.usage), dollars.reduce(0, +) / 1_000_000, accuracy: 1e-9)
    }

    func testReadingInPiecesMatchesOneRead() {
        let data = Data((claudeLines.joined(separator: "\n") + "\n").utf8)
        var whole = LedgerCursor()
        UsageLedger.read(data, provider: .claude, cursor: &whole, calendar: utc)

        // The log grows while it is read: pieces end mid-line, and the rest is read with the next piece.
        var pieces = LedgerCursor()
        for cut in [700, 1500, 2600, data.count] {
            let chunk = data.subdata(in: Int(pieces.offset)..<cut)
            UsageLedger.read(chunk, provider: .claude, cursor: &pieces, calendar: utc)
        }
        XCTAssertEqual(pieces.offset, whole.offset)
        XCTAssertEqual(pieces.records, whole.records)
    }

    func testCodexUsesResponseRecordsAndIgnoresTheirRunningTotals() throws {
        let lines = [
            #"{"timestamp":"2026-09-23T18:47:58.000Z","ordinal":1,"type":"session_meta","payload":{"id":"t1","cwd":"/tmp/site","originator":"codex-tui","source":"cli"}}"#,
            #"{"timestamp":"2026-09-23T18:47:58.500Z","ordinal":2,"type":"turn_context","payload":{"cwd":"/tmp/site","model":"gpt-6-sol","effort":"high"}}"#,
            #"{"timestamp":"2026-09-23T18:48:11.491Z","ordinal":3,"type":"token_usage_record","payload":{"thread_id":"t1","turn_id":"r1","response_id":"resp_1","usage":{"input_tokens":26846,"cached_input_tokens":12416,"cache_write_input_tokens":0,"output_tokens":426,"reasoning_output_tokens":110,"total_tokens":27272}}}"#,
            #"{"timestamp":"2026-09-23T18:48:12.287Z","ordinal":4,"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":26846,"cached_input_tokens":12416,"output_tokens":426,"reasoning_output_tokens":110,"total_tokens":27272},"last_token_usage":{"input_tokens":26846,"cached_input_tokens":12416,"output_tokens":426,"reasoning_output_tokens":110,"total_tokens":27272},"model_context_window":258400},"rate_limits":{"primary":{"used_percent":11.0,"window_minutes":10080,"resets_at":1790760451}}}}"#,
            #"{"timestamp":"2026-09-23T18:49:02.000Z","ordinal":5,"type":"token_usage_record","payload":{"thread_id":"t1","turn_id":"r1","response_id":"resp_2","usage":{"input_tokens":30000,"cached_input_tokens":26000,"cache_write_input_tokens":0,"output_tokens":1000,"reasoning_output_tokens":600,"total_tokens":31000}}}"#
        ]
        var cursor = LedgerCursor()
        UsageLedger.read(Data((lines.joined(separator: "\n") + "\n").utf8), provider: .codex, cursor: &cursor, calendar: utc)
        let record = try XCTUnwrap(cursor.records.first)
        XCTAssertEqual(cursor.records.count, 1)
        XCTAssertEqual(record.model, "gpt-6-sol")
        XCTAssertEqual(record.project, "/tmp/site")
        // Cached input is counted inside input_tokens, and reasoning inside output_tokens.
        XCTAssertEqual(record.usage, TokenUsage(input: 18430, cacheRead: 38416, output: 1426, requests: 2))
        XCTAssertEqual(record.usage.total, 27272 + 31000)
    }

    func testOlderCodexLogsCountTheGrowthOfTheirRunningTotal() throws {
        func count(_ total: Int, cached: Int, output: Int, at time: String) -> String {
            #"{"timestamp":"\#(time)","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":\#(total - output),"cached_input_tokens":\#(cached),"output_tokens":\#(output),"total_tokens":\#(total)},"model_context_window":200000}}}"#
        }
        let lines = [
            #"{"timestamp":"2026-08-01T21:00:00.000Z","type":"session_meta","payload":{"id":"t2","cwd":"/tmp/api"}}"#,
            #"{"timestamp":"2026-08-01T21:00:01.000Z","type":"turn_context","payload":{"cwd":"/tmp/api","model":"gpt-5.5-codex"}}"#,
            count(10_000, cached: 2_000, output: 500, at: "2026-08-01T21:00:10.000Z"),
            // The same total again, as when only the limits changed.
            count(10_000, cached: 2_000, output: 500, at: "2026-08-01T21:00:11.000Z"),
            count(25_000, cached: 12_000, output: 1_200, at: "2026-08-01T23:30:00.000Z")
        ]
        var cursor = LedgerCursor()
        UsageLedger.read(Data((lines.joined(separator: "\n") + "\n").utf8), provider: .codex, cursor: &cursor, calendar: utc)
        let record = try XCTUnwrap(cursor.records.first)
        XCTAssertEqual(record.usage.total, 25_000)
        XCTAssertEqual(record.usage.requests, 2)
        XCTAssertEqual(record.usage.cacheRead, 12_000)
    }

    func testSummaryPricesKnownModelsAndLeavesOthersOut() {
        var calendar = utc
        calendar.firstWeekday = 2
        let now = ISO8601DateFormatter().date(from: "2026-09-24T12:00:00Z")!
        let records = [
            UsageRecord(day: "2026-09-24", provider: .claude, model: "claude-sonnet-5", project: "/tmp/app",
                        usage: TokenUsage(input: 1_000_000, output: 100_000, requests: 3)),
            UsageRecord(day: "2026-09-20", provider: .claude, model: "claude-haiku-4-5-20251001", project: "/tmp/site",
                        usage: TokenUsage(input: 2_000_000, requests: 5)),
            UsageRecord(day: "2026-09-24", provider: .codex, model: "gpt-unpriced", project: "/tmp/app",
                        usage: TokenUsage(input: 500_000, requests: 1)),
            UsageRecord(day: "2026-08-01", provider: .claude, model: "claude-sonnet-5", project: "/tmp/old",
                        usage: TokenUsage(input: 9_000_000, requests: 9))
        ]
        let summary = UsageSummary(records: records, now: now, calendar: calendar)
        let today = summary.totals(lastDays: 1)
        XCTAssertEqual(today.cost, 2 + 1, accuracy: 1e-9)
        XCTAssertEqual(today.unpricedTokens, 500_000)
        XCTAssertFalse(today.isFullyPriced)
        XCTAssertEqual(summary.totals(lastDays: 7, provider: .claude).cost, 3 + 2, accuracy: 1e-9)
        XCTAssertEqual(summary.daily(lastDays: 7).map(\.day).first, "2026-09-18")
        XCTAssertEqual(summary.projects(lastDays: 7).map(\.name), ["/tmp/site", "/tmp/app"])
        XCTAssertEqual(summary.projects(lastDays: 7, metric: .apiEquivalent).map(\.name), ["/tmp/app", "/tmp/site"])
    }

    func testHistoryFiltersDefaultAndNamedAccountsAndExportsUnknownPricesHonestly() {
        let now = ISO8601DateFormatter().date(from: "2026-09-26T12:00:00Z")!
        let records = [
            UsageRecord(day: "2026-09-26", provider: .codex, model: "gpt-unpriced", project: "/tmp/a,\"b\"",
                        usage: TokenUsage(input: 100, requests: 2)),
            UsageRecord(day: "2026-09-26", provider: .codex, model: "gpt-unpriced", project: "/tmp/work",
                        usage: TokenUsage(input: 900, requests: 3), account: "Work"),
            UsageRecord(day: "2026-09-26", provider: .claude, model: "claude-sonnet-5", project: "/tmp/work",
                        usage: TokenUsage(input: 200, requests: 1), account: "Work")
        ]
        let summary = UsageSummary(records: records, now: now, calendar: utc)
        let own = summary.filtered(to: UsageAccount(provider: .codex, name: nil))
        XCTAssertEqual(own.totals(lastDays: 7).tokens, 100)
        XCTAssertEqual(summary.filtered(to: UsageAccount(provider: .codex, name: "Work")).totals(lastDays: 7).tokens, 900)
        let csv = own.csv(lastDays: 7)
        XCTAssertFalse(csv.contains("usd"))
        XCTAssertTrue(csv.contains("\"/tmp/a,\"\"b\"\"\""))
        let priced = own.csv(lastDays: 7, includeAPIEquivalent: true)
        XCTAssertTrue(priced.contains("\"local_log\",\"\",\"unavailable\""))
        XCTAssertFalse(priced.contains("0.000000"))
        XCTAssertEqual(summary.daily(lastDays: 90).count, 90)
    }

    func testProjectAndDayDrilldownKeepCountsAndExportInTheSameScope() {
        let now = ISO8601DateFormatter().date(from: "2026-09-26T12:00:00Z")!
        let records = [
            UsageRecord(day: "2026-09-26", provider: .claude, model: "claude-sonnet-5", project: "/tmp/app",
                        usage: TokenUsage(input: 100, cacheWrite: 50, cacheWriteHour: 50, cacheRead: 800, output: 1000, requests: 2)),
            UsageRecord(day: "2026-09-25", provider: .claude, model: "claude-sonnet-5", project: "/tmp/app",
                        usage: TokenUsage(input: 999, requests: 1)),
            UsageRecord(day: "2026-09-26", provider: .claude, model: "claude-sonnet-5", project: "/tmp/other",
                        usage: TokenUsage(input: 999, requests: 1)),
            UsageRecord(day: "2026-09-26", provider: .claude, model: "claude-sonnet-5", project: "/tmp/app",
                        usage: TokenUsage(input: 999, requests: 1), account: "Work")
        ]
        let summary = UsageSummary(records: records, now: now, calendar: utc)
        let detail = summary.filtered(to: UsageAccount(provider: .claude, name: nil), project: "/tmp/app", day: "2026-09-26")
        let totals = detail.totals(lastDays: 7)
        XCTAssertEqual(totals.tokens, 2000)
        XCTAssertEqual(totals.requests, 2)
        XCTAssertEqual(totals.cacheReadFraction, 0.8)
        XCTAssertEqual(detail.csv(lastDays: 7).components(separatedBy: "\r\n").count, 3)
        XCTAssertFalse(detail.csv(lastDays: 7).contains("999"))
        XCTAssertEqual(detail.models(lastDays: 7).first?.totals, totals)
        var combined = UsageTotals()
        combined.add(totals)
        XCTAssertEqual(combined, totals)
        XCTAssertNil(UsageTotals().cacheReadFraction)
    }
}
