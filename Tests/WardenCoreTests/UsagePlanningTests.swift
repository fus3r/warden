import XCTest
@testable import WardenCore

final class UsagePlanningTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_790_424_000)

    private func window(_ id: String, used: Double, scope: String? = nil, account: String? = nil,
                        resetIn: TimeInterval = 7200, at: Date? = nil) -> UsageWindow {
        UsageWindow(id: id, provider: .claude, label: "5h", usedPercent: used,
                    resetsAt: now.addingTimeInterval(resetIn), observedAt: at ?? now,
                    evidence: .provider, minutes: 300, scope: scope, account: account)
    }

    func testOldQuotaDoesNotProduceACurrentWarningOrForecast() {
        let now = Date(timeIntervalSince1970: 1_790_424_000)
        let old = UsageWindow(id: "Claude-seven_day", provider: .claude, label: "7d", usedPercent: 96,
                              resetsAt: now.addingTimeInterval(86_400), observedAt: now.addingTimeInterval(-86_400),
                              evidence: .provider)
        XCTAssertNil(old.forecast(now: now))
        XCTAssertNil(UsageAlert.mostUrgent(in: [old], now: now))
    }

    func testAnUnknownModelVersionDoesNotInheritAnOlderPrice() {
        XCTAssertNil(Pricing.price(for: "claude-opus-5-99"))
        XCTAssertNotNil(Pricing.price(for: "claude-haiku-4-5-20251001"))
    }

    func testPlannerFindsTheTightestModelLimitWithoutMixingAccounts() throws {
        var tracker = UsagePaceTracker()
        for back in [20, 10, 0] {
            let at = now.addingTimeInterval(-Double(back) * 60)
            tracker.record([
                window("shared", used: 40 - Double(back) / 2, at: at),
                window("fable", used: 94 - Double(back) / 2, scope: "Fable", at: at),
                window("work", used: 100, account: "Work", at: at)
            ], now: at)
        }
        let windows = [window("shared", used: 40), window("fable", used: 94, scope: "Fable"), window("work", used: 100, account: "Work")]
        let routes = WorkRoute.all(in: windows)
        let shared = try XCTUnwrap(routes.first { $0.account == nil && $0.scope == nil })
        XCTAssertEqual(WorkPlan(route: shared, tracker: tracker, minutes: 60, now: now).status, .withinObservedPace)
        let fable = try XCTUnwrap(routes.first { $0.scope == "Fable" })
        let plan = WorkPlan(route: fable, tracker: tracker, minutes: 60, now: now)
        XCTAssertEqual(plan.limitingWindow?.id, "fable")
        XCTAssertEqual(plan.status, .atRisk(now.addingTimeInterval(12 * 60)))
        let work = try XCTUnwrap(routes.first { $0.account == "Work" })
        XCTAssertEqual(WorkPlan(route: work, tracker: tracker, minutes: 60, now: now).status, .limitReached)
    }

    func testPlannerLearnsAgainAfterAResetDropOrSleepAndDoesNotForecastPastAReset() throws {
        var tracker = UsagePaceTracker()
        for back in [20, 10, 0] {
            let at = now.addingTimeInterval(-Double(back) * 60)
            tracker.record([window("shared", used: 40 - Double(back) / 2, resetIn: 1800, at: at)], now: at)
        }
        let latest = window("shared", used: 40, resetIn: 1800)
        let route = try XCTUnwrap(WorkRoute.all(in: [latest]).first)
        XCTAssertEqual(WorkPlan(route: route, tracker: tracker, minutes: 60, now: now).status,
                       .resetDuringSession(now.addingTimeInterval(1800)))
        XCTAssertNotNil(tracker.pace(for: latest, now: now))
        let afterDrop = window("shared", used: 10, resetIn: 1800, at: now.addingTimeInterval(60))
        tracker.record([afterDrop], now: afterDrop.observedAt)
        XCTAssertNil(tracker.pace(for: afterDrop, now: afterDrop.observedAt))
        let afterSleep = window("shared", used: 50, resetIn: 7200, at: now.addingTimeInterval(3600))
        tracker.record([afterSleep], now: afterSleep.observedAt)
        XCTAssertNil(tracker.pace(for: afterSleep, now: afterSleep.observedAt))
        XCTAssertFalse(latest.isCurrent(now: now.addingTimeInterval(1800)))
    }

    func testAnIdleAccountDoesNotPromiseUnlimitedRunway() throws {
        var tracker = UsagePaceTracker()
        for back in [20, 10, 0] {
            let at = now.addingTimeInterval(-Double(back) * 60)
            tracker.record([window("shared", used: 10, at: at)], now: at)
        }
        let route = try XCTUnwrap(WorkRoute.all(in: [window("shared", used: 10)]).first)
        XCTAssertEqual(WorkPlan(route: route, tracker: tracker, minutes: 60, now: now).status, .learning)
    }

    func testScenarioSeparatesAnOptionalMarginFromTheProviderLimit() throws {
        var tracker = UsagePaceTracker()
        for back in [20, 10, 0] {
            let at = now.addingTimeInterval(-Double(back) * 60)
            tracker.record([window("shared", used: 40 - Double(back) / 2, at: at)], now: at)
        }
        let route = try XCTUnwrap(WorkRoute.all(in: [window("shared", used: 40)]).first)
        let recent = WorkPlan(route: route, tracker: tracker, minutes: 60, now: now, reservePercent: 20)
        XCTAssertEqual(recent.status, .withinObservedPace)
        XCTAssertEqual(recent.checks.first?.projectedUsedPercent, 70)

        let busy = WorkPlan(route: route, tracker: tracker, minutes: 60, now: now, paceMultiplier: 2, reservePercent: 20)
        XCTAssertEqual(busy.status, .reserveAtRisk(now.addingTimeInterval(40 * 60)))
        XCTAssertEqual(busy.checks.first?.exhaustsAt, now.addingTimeInterval(60 * 60))
        let high = try XCTUnwrap(WorkRoute.all(in: [window("shared", used: 85)]).first)
        XCTAssertEqual(WorkPlan(route: high, tracker: tracker, minutes: 60, now: now, reservePercent: 20).status, .reserveReached)
    }

    func testScenarioStartsNowAndCannotCrossAResetOrUseAStaleSharedLimit() throws {
        var tracker = UsagePaceTracker()
        for back in [30, 20, 10] {
            let at = now.addingTimeInterval(-Double(back) * 60)
            tracker.record([window("shared", used: 40 - Double(back) / 2, at: at)], now: at)
        }
        let last = window("shared", used: 35, at: now.addingTimeInterval(-600))
        let route = try XCTUnwrap(WorkRoute.all(in: [last]).first)
        let plan = WorkPlan(route: route, tracker: tracker, minutes: 30, now: now, paceMultiplier: 2)
        // 35% reported + 5 points since then at the observed pace + 30 points in the future scenario.
        XCTAssertEqual(plan.checks.first?.projectedUsedPercent, 70)

        let resetting = try XCTUnwrap(WorkRoute.all(in: [window("shared", used: 35, resetIn: 1800)]).first)
        let crossing = WorkPlan(route: resetting, tracker: tracker, minutes: 30, now: now)
        XCTAssertEqual(crossing.status, .resetDuringSession(now.addingTimeInterval(1800)))
        XCTAssertNil(crossing.checks.first?.projectedUsedPercent)

        let scoped = try XCTUnwrap(WorkRoute.all(in: [window("shared", used: 35, at: now.addingTimeInterval(-3600)),
                                                     window("model", used: 90, scope: "Fable")]).first { $0.scope != nil })
        XCTAssertEqual(WorkPlan(route: scoped, tracker: tracker, minutes: 30, now: now, reservePercent: 20).status, .needsRefresh)
    }

    func testAChangedResetTimeDoesNotClaimQuotaRecoveredWithoutFreshCapacity() {
        let old = window("shared", used: 100, resetIn: -60, at: now.addingTimeInterval(-600))
        XCTAssertFalse(window("shared", used: 100).confirmsRecovery(from: old, now: now))
        XCTAssertFalse(window("shared", used: 20, at: now.addingTimeInterval(-120)).confirmsRecovery(from: old, now: now))
        XCTAssertTrue(window("shared", used: 20).confirmsRecovery(from: old, now: now))
        XCTAssertFalse(window("shared", used: 20).confirmsRecovery(from: old, now: now.addingTimeInterval(3600)))
    }

    func testAWindowStaysAfterItsResetUntilTheNextReadingConfirmsRecovery() throws {
        // 95% read at 13:50, reset reported for 14:00. Scans after 14:00 keep the ended window.
        let before = window("Claude-five_hour", used: 95, resetIn: 600, at: now)
        var stored = UsageWindow.latest([:], adding: [before], now: now)
        let afterReset = now.addingTimeInterval(900)
        stored = UsageWindow.latest(stored, adding: [], now: afterReset)
        let pending = try XCTUnwrap(stored["Claude-five_hour"])
        XCTAssertTrue(pending.hasReset(now: afterReset))
        XCTAssertFalse(pending.isCurrent(now: afterReset))
        XCTAssertNil(UsageAlert.mostUrgent(in: [pending], now: afterReset))

        // An idle session's status line, written after the reset with its old window, does not win.
        var stale = before
        stale.observedAt = afterReset
        stale.usedPercent = 96
        let fresh = UsageWindow(id: "Claude-five_hour", provider: .claude, label: "5h", usedPercent: 3,
                                resetsAt: afterReset.addingTimeInterval(5 * 3600), observedAt: afterReset.addingTimeInterval(60),
                                evidence: .provider, minutes: 300)
        stored = UsageWindow.latest(stored, adding: [fresh, stale], now: afterReset.addingTimeInterval(60))
        XCTAssertEqual(stored["Claude-five_hour"], fresh)
        XCTAssertTrue(fresh.confirmsRecovery(from: pending, now: afterReset.addingTimeInterval(60)))

        // Whatever order a scan lists them in, the new window wins over an idle session's line from the old one.
        for batch in [[stale, fresh], [fresh, stale]] {
            XCTAssertEqual(UsageWindow.latest([pending.id: pending], adding: batch, now: afterReset.addingTimeInterval(60))["Claude-five_hour"], fresh)
        }
        // A reset moved earlier but still ahead corrects the same window.
        var corrected = window("Claude-five_hour", used: 41, resetIn: 5400, at: now.addingTimeInterval(60))
        corrected.minutes = 300
        XCTAssertEqual(UsageWindow.latest([before.id: before], adding: [corrected], now: now.addingTimeInterval(60))["Claude-five_hour"]?.usedPercent, 41)

        // Without a new reading, the ended window leaves after six hours.
        XCTAssertNil(UsageWindow.latest([pending.id: pending], adding: [], now: now.addingTimeInterval(7 * 3600))[pending.id])
    }
}
