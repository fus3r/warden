import IOKit.pwr_mgt
import XCTest
@testable import WardenCore

final class KeepAwakeTests: XCTestCase {
    func testWorkPowerAndBatteryReserve() {
        func policy(enabled: Bool = true, working: Bool = true, fresh: Bool = true,
                    battery: Bool = false, adapter: Bool = false, percent: Int? = 80) -> KeepAwakePolicy {
            KeepAwakePolicy.evaluate(enabled: enabled, working: working, fresh: fresh,
                                     allowBattery: battery, power: MacPowerState(onAdapter: adapter, batteryPercent: percent))
        }
        XCTAssertEqual(policy(enabled: false, adapter: true), .off)
        XCTAssertEqual(policy(working: false, adapter: true), .noWork)
        XCTAssertEqual(policy(fresh: false, adapter: true), .stale)
        XCTAssertEqual(policy(), .needsPower)
        XCTAssertEqual(policy(adapter: true, percent: nil), .awake)
        XCTAssertEqual(policy(battery: true, percent: 21), .awake)
        XCTAssertEqual(policy(battery: true, percent: 20), .lowBattery)
        XCTAssertEqual(policy(battery: true, percent: nil), .unknownBattery)
    }

    func testPhoneRepliesAndSupervisedWorkRetainWakeWithTheSameSafetyLimits() {
        let ac = MacPowerState(onAdapter: true, batteryPercent: 90)
        let low = MacPowerState(onAdapter: false, batteryPercent: 20)
        for (jobs, phone) in [(true, false), (false, true)] {
            XCTAssertEqual(KeepAwakePolicy.evaluate(enabled: true, working: false, fresh: true,
                allowBattery: false, power: ac, guardedJobs: jobs, phoneAwaitingReply: phone), .awake)
            XCTAssertEqual(KeepAwakePolicy.evaluate(enabled: false, working: false, fresh: true,
                allowBattery: false, power: ac, guardedJobs: jobs, phoneAwaitingReply: phone), .off)
            XCTAssertEqual(KeepAwakePolicy.evaluate(enabled: true, working: false, fresh: true,
                allowBattery: true, power: low, guardedJobs: jobs, phoneAwaitingReply: phone), .lowBattery)
            XCTAssertEqual(KeepAwakePolicy.evaluate(enabled: true, working: false, fresh: false,
                allowBattery: false, power: ac, guardedJobs: jobs, phoneAwaitingReply: phone), .stale)
        }
        XCTAssertEqual(KeepAwakePolicy.evaluate(enabled: true, working: false, fresh: true,
            allowBattery: false, power: ac), .noWork)
    }

    func testHelperExpiresRequestsAndChecksPowerIndependently() {
        let pluggedIn = MacPowerState(onAdapter: true, batteryPercent: 15)
        let battery = MacPowerState(onAdapter: false, batteryPercent: 80)
        let acOnly = WakeLease(now: 100, allowBattery: false)
        XCTAssertTrue(acOnly.permitsWake(now: 124, power: pluggedIn))
        XCTAssertFalse(acOnly.permitsWake(now: 125, power: pluggedIn), "A stalled or dead client cannot keep renewing.")
        XCTAssertFalse(acOnly.permitsWake(now: 101, power: battery), "Unplugging is checked in the privileged service.")
        let portable = WakeLease(now: 100, allowBattery: true)
        XCTAssertTrue(portable.permitsWake(now: 101, power: battery))
        XCTAssertFalse(portable.permitsWake(now: 101, power: MacPowerState(onAdapter: false, batteryPercent: 20)))
        XCTAssertFalse(portable.permitsWake(now: 101, power: MacPowerState(onAdapter: false, batteryPercent: nil)))
        XCTAssertFalse(portable.permitsWake(now: 101, power: MacPowerState(onAdapter: true, batteryPercent: 80, thermalCritical: true)))
    }

    func testSleepSettingIsBackedUpBeforeMutationAndRestoredOnlyWhenOwned() throws {
        var disabled = false
        var pending = false
        var writes: [Bool] = []
        let control = SleepOverride(needsRestore: false, read: { disabled }, write: { value in
            XCTAssertTrue(pending, "The recovery marker must exist before any pmset write.")
            disabled = value; writes.append(value)
        }, saveRestore: { pending = $0 })
        try control.setActive(true)
        try control.setActive(true)
        XCTAssertEqual(writes, [true], "Refreshes do not repeatedly rewrite global preferences.")
        XCTAssertEqual(control.state, .held)
        try control.setActive(false)
        XCTAssertEqual(writes, [true, false])
        XCTAssertFalse(pending)
        XCTAssertFalse(disabled)
        disabled = true // Already set by the user or another app before this session.
        try control.setActive(true)
        XCTAssertEqual(control.state, .alreadyDisabled)
        try control.setActive(false)
        XCTAssertTrue(disabled)
        XCTAssertEqual(writes, [true, false], "Never reset a setting Warden did not change.")
    }

    func testFailedRestoreKeepsRecoveryMarkerForNextLaunch() throws {
        var disabled = true
        var pending = true
        var fail = true
        let make = {
            SleepOverride(needsRestore: pending, read: { disabled }, write: { value in
                if fail { throw PowerError("Simulated pmset failure") }
                disabled = value
            }, saveRestore: { pending = $0 })
        }
        let interrupted = make()
        XCTAssertThrowsError(try interrupted.setActive(false))
        XCTAssertTrue(pending)
        fail = false
        let restarted = make()
        try restarted.setActive(false)
        XCTAssertFalse(disabled)
        XCTAssertFalse(pending)
    }

    func testUnconfirmedActivationIsNeverReportedAsHeld() throws {
        var pending = false
        let control = SleepOverride(needsRestore: false, read: { false }, write: { _ in }, saveRestore: { pending = $0 })
        XCTAssertThrowsError(try control.setActive(true))
        XCTAssertEqual(control.state, .inactive)
        XCTAssertTrue(pending)
        try control.setActive(false)
        XCTAssertFalse(pending)
    }

    func testPMSetOutputWithAndWithoutSystemWidePreference() throws {
        XCTAssertTrue(try PMSet.sleepDisabled(in: "System-wide power settings:\n SleepDisabled\t\t1\nCurrently in use:\n sleep 1"))
        XCTAssertFalse(try PMSet.sleepDisabled(in: "System-wide power settings:\n SleepDisabled\t\t0\nCurrently in use:\n sleep 1"))
        XCTAssertFalse(try PMSet.sleepDisabled(in: "Currently in use:\n standby 1\n sleep 1 (sleep prevented by powerd)"))
        XCTAssertThrowsError(try PMSet.sleepDisabled(in: "pmset: error"))
        XCTAssertThrowsError(try PMSet.sleepDisabled(in: "System-wide power settings:\n SleepDisabled unknown\nCurrently in use:"))
    }

    func testRealIdleAssertionIsReleasedWithoutChangingGlobalSleep() throws {
        let before = try PMSet.readSleepDisabled()
        let assertion = IdleSleepAssertion()
        try assertion.setHeld(true)
        XCTAssertTrue(assertion.isHeld)
        try assertion.setHeld(false)
        XCTAssertFalse(assertion.isHeld)
        XCTAssertEqual(try PMSet.readSleepDisabled(), before)
    }
}
