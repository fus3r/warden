import XCTest
@testable import Warden
import WardenCore

final class AlertEngineTests: XCTestCase {
    func testAsyncQuestionAlertsWhileWorkingWithoutRepeatingAtTurnEnd() async throws {
        try await MainActor.run {
            let defaults = UserDefaults.standard
            let prior = defaults.object(forKey: "alertAttention")
            defaults.set(true, forKey: "alertAttention")
            defer {
                if let prior { defaults.set(prior, forKey: "alertAttention") }
                else { defaults.removeObject(forKey: "alertAttention") }
            }
            let engine = AlertEngine(sounds: SoundLibrary())
            var events: [AutomationEvent] = []
            engine.onEvent = { events.append($0) }
            let meta = #"{"type":"session_meta","payload":{"id":"s-async","cwd":"/tmp/app","originator":"codex-tui"}}"#
            let started = #"{"timestamp":"2026-09-30T16:00:00Z","type":"event_msg","payload":{"type":"task_started"}}"#
            let asked = #"{"timestamp":"2026-09-30T16:00:30Z","type":"response_item","payload":{"type":"function_call","name":"request_user_input_async","arguments":"{\"questions\":[{\"title\":\"Keep the snapshots?\"}]}","call_id":"call_Q1"}}"#
            let acknowledged = #"{"type":"response_item","payload":{"type":"function_call_output","call_id":"call_Q1","output":"{\"accepted\":true}"}}"#
            let continued = #"{"timestamp":"2026-09-30T16:01:00Z","type":"event_msg","payload":{"type":"token_count","info":null}}"#
            let completed = #"{"timestamp":"2026-09-30T16:15:00Z","type":"event_msg","payload":{"type":"task_complete","last_agent_message":"The build passes."}}"#
            func parse(_ lines: [String]) throws -> AgentSession {
                let data = Data((lines.joined(separator: "\n") + "\n").utf8)
                let timestamps = lines.compactMap { line in
                    let object = try? JSONSerialization.jsonObject(with: Data(line.utf8))
                    return (object as? [String: Any])?["timestamp"] as? String
                }
                let modified = try XCTUnwrap(timestamps.last.flatMap { ISO8601DateFormatter().date(from: $0) })
                return try XCTUnwrap(TelemetryParser.codex(head: data, tail: data, filename: "s-async.jsonl", modifiedAt: modified))
            }
            @MainActor func process(_ session: AgentSession, after old: AgentSession) {
                // Snooze prevents real notifications and audio; the event still records each alert decision.
                engine.process(sessions: [session], previous: [old.id: old], windows: [], previousWindows: [:],
                               styles: [session.id: .both], mode: .attention, snoozed: true)
            }
            let baseline = try parse([meta, started])
            let question = try parse([meta, started, asked, acknowledged])
            XCTAssertEqual(question.phase, .working)
            process(question, after: baseline)
            XCTAssertEqual(events.count, 1, "A question must alert even while Codex keeps working.")
            XCTAssertEqual(events.first?.event, "needs-you")
            XCTAssertEqual(events.first?.message, "Keep the snapshots?")

            let working = try parse([meta, started, asked, acknowledged, continued])
            process(working, after: question)
            let ended = try parse([meta, started, asked, acknowledged, continued, completed])
            XCTAssertEqual(ended.phase, .needsAttention)
            process(ended, after: working)
            XCTAssertEqual(events.count, 1, "Polling and finishing with the same open question must stay quiet.")

            let answered = #"{"timestamp":"2026-09-30T16:16:00Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"Yes"}]}}"#
            let next = try parse([meta, started, asked, acknowledged, answered])
            process(next, after: ended)
            let askedAgain = asked.replacingOccurrences(of: "16:00:30", with: "16:17:00")
                .replacingOccurrences(of: "call_Q1", with: "call_Q2")
            process(try parse([meta, started, asked, acknowledged, answered, askedAgain]), after: next)
            XCTAssertEqual(events.count, 2, "A later question must alert again after the earlier one was answered.")
        }
    }
}
