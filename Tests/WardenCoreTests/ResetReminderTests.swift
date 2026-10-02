import XCTest
@testable import WardenCore

final class ResetReminderTests: XCTestCase {
    func testExpiryAlertsUseAvailabilityFreshnessAndSeparateReminderStages() throws {
        let now = Date(timeIntervalSince1970: 1_791_000_000)
        var plan = PlanDetails(provider: .codex, plan: "pro", resets: 2)
        plan.account = "work"
        plan.observedAt = now
        plan.resetsExpire = [now.addingTimeInterval(7200), now.addingTimeInterval(7200)]
        let offer = try XCTUnwrap(ResetReminder.reported(in: [plan]).first)
        XCTAssertEqual(ResetReminder.reported(in: [plan]).count, 1)
        XCTAssertEqual(offer.account, "work")
        XCTAssertTrue(try XCTUnwrap(offer.alertKey(now: now, leadHours: 24)).hasSuffix("soon"))
        XCTAssertNil(offer.alertKey(now: now.addingTimeInterval(900), leadHours: 24), "Old CLI readings cannot assert availability.")
        var renewed = offer
        renewed.observedAt = now.addingTimeInterval(3600)
        XCTAssertTrue(try XCTUnwrap(renewed.alertKey(now: renewed.observedAt, leadHours: 24)).hasSuffix("final"))
        XCTAssertNil(renewed.alertKey(now: offer.expiresAt, leadHours: 24))
        plan.resets = 0
        XCTAssertTrue(ResetReminder.reported(in: [plan]).isEmpty, "Consumed offers stop producing reminders.")
        let manual = ResetReminder(provider: .claude, expiresAt: now.addingTimeInterval(2 * 86_400),
                                   source: .manual, observedAt: now.addingTimeInterval(-86_400))
        XCTAssertNil(manual.alertKey(now: now, leadHours: 24))
        XCTAssertNotNil(manual.alertKey(now: now, leadHours: 72), "An explicitly entered date remains a reminder without CLI confirmation.")
        XCTAssertEqual(manual.usageURL.absoluteString, "https://claude.ai/new#settings/usage")
    }
}
