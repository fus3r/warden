import XCTest
@testable import Warden
import WardenCore

final class AlertEngineTests: XCTestCase {
    func testResetRemindersAreIndependentOfQuotaAlertsAndDoNotRepeat() async throws {
        try await MainActor.run {
            let defaults = UserDefaults.standard
            let keys = ["alertResetExpiry", "alertResetExpiryLeadHours", "alertQuota", "soundCodex", "soundClaude", "alertedOnce"]
            let saved = keys.map { defaults.object(forKey: $0) }
            defer {
                for (key, prior) in zip(keys, saved) {
                    if let prior { defaults.set(prior, forKey: key) } else { defaults.removeObject(forKey: key) }
                }
            }
            defaults.set(true, forKey: "alertResetExpiry")
            defaults.set(24.0, forKey: "alertResetExpiryLeadHours")
            defaults.set(false, forKey: "alertQuota")
            defaults.set("both", forKey: "soundCodex")
            defaults.set("voice", forKey: "soundClaude")
            defaults.removeObject(forKey: "alertedOnce")
            let now = Date()
            let codex = ResetReminder(provider: .codex, account: "work", expiresAt: now.addingTimeInterval(7200), source: .provider, observedAt: now)
            let claude = ResetReminder(provider: .claude, expiresAt: now.addingTimeInterval(7200), source: .manual)
            let engine = AlertEngine(sounds: SoundLibrary())
            var events: [AutomationEvent] = []
            engine.onEvent = { events.append($0) }
            engine.resetExpiry([codex, claude], mode: .all, snoozed: true, now: now)
            engine.resetExpiry([codex, claude], mode: .all, snoozed: true, now: now)
            XCTAssertEqual(events.count, 2)
            XCTAssertTrue(events.allSatisfy { $0.event == "reset-expiring" && !$0.alerted })
            XCTAssertEqual(events.first?.account, "work")
            XCTAssertTrue(events[1].message.contains("Check that the reset is still available"))
            var refreshed = codex
            refreshed.observedAt = now.addingTimeInterval(3600)
            engine.resetExpiry([refreshed, claude], mode: .all, snoozed: true, now: refreshed.observedAt)
            XCTAssertEqual(events.count, 4, "The last hour has its own reminder.")
            defaults.set([try XCTUnwrap(codex.alertKey(now: now, leadHours: 24))], forKey: "alertedOnce")
            let relaunched = AlertEngine(sounds: SoundLibrary())
            relaunched.onEvent = { events.append($0) }
            relaunched.resetExpiry([codex], mode: .all, snoozed: true, now: now)
            XCTAssertEqual(events.count, 4, "A reminder delivered before a relaunch stays dismissed.")
            defaults.set(false, forKey: "alertResetExpiry")
            relaunched.resetExpiry([claude], mode: .all, snoozed: true, now: now)
            XCTAssertEqual(events.count, 4)
        }
    }

    func testManualResetReminderPersistsAndStopsAfterRemoval() async throws {
        try await MainActor.run {
            let suite = "WardenResetTests-" + UUID().uuidString
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let account = AgentAccount(provider: .claude, folder: URL(fileURLWithPath: "/tmp/reset-claude"), name: nil)
            let expiry = Date().addingTimeInterval(2 * 86_400)
            let reminders = ResetReminders(defaults: defaults)
            reminders.add(account: account, expiryDate: expiry)
            let reopened = ResetReminders(defaults: defaults)
            let item = try XCTUnwrap(reopened.available(plans: [], accounts: [account]).first)
            XCTAssertEqual(item.expiresAt, Calendar.current.startOfDay(for: expiry))
            XCTAssertEqual(item.source, .manual)
            XCTAssertTrue(reopened.available(plans: [], accounts: []).isEmpty)
            reopened.remove(item.id)
            XCTAssertTrue(ResetReminders(defaults: defaults).items.isEmpty)
        }
    }

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
