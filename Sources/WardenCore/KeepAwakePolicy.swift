import Foundation
import IOKit.ps
import IOKit.pwr_mgt

public struct MacPowerState {
    public var onAdapter: Bool
    public var batteryPercent: Int?
    public var thermalCritical: Bool

    public init(onAdapter: Bool, batteryPercent: Int?, thermalCritical: Bool = false) {
        self.onAdapter = onAdapter
        self.batteryPercent = batteryPercent
        self.thermalCritical = thermalCritical
    }

    public var allowsBatteryUse: Bool { (batteryPercent ?? 0) > 20 }

    public static func read() -> Self {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let source = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() else {
            return Self(onAdapter: false, batteryPercent: nil)
        }
        let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] ?? []
        let percent = sources.compactMap { source -> Int? in
            guard let values = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  values[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  let current = values[kIOPSCurrentCapacityKey] as? Int,
                  let maximum = values[kIOPSMaxCapacityKey] as? Int, maximum > 0 else { return nil }
            return max(0, min(100, current * 100 / maximum))
        }.first
        return Self(onAdapter: (source as String) == kIOPMACPowerKey, batteryPercent: percent,
                    thermalCritical: ProcessInfo.processInfo.thermalState == .critical)
    }
}

public enum KeepAwakePolicy: Equatable {
    case off, noWork, stale, needsPower, lowBattery, unknownBattery, tooHot, awake

    public static func evaluate(enabled: Bool, working: Bool, fresh: Bool,
                                allowBattery: Bool, power: MacPowerState,
                                guardedJobs: Bool = false, phoneAwaitingReply: Bool = false) -> Self {
        guard enabled else { return .off }
        guard working || guardedJobs || phoneAwaitingReply else { return .noWork }
        guard fresh else { return .stale }
        guard !power.thermalCritical else { return .tooHot }
        if power.onAdapter { return .awake }
        guard allowBattery else { return .needsPower }
        guard power.batteryPercent != nil else { return .unknownBattery }
        return power.allowsBatteryUse ? .awake : .lowBattery
    }
}

/// A closed-lid work period must be observed before an idle scan can request sleep.
/// A short quiet period accommodates the gap between consecutive agent turns.
public struct SleepAfterWork {
    public private(set) var armed = false
    public private(set) var quietSince: TimeInterval?
    public static let quietSeconds: TimeInterval = 30

    public init() {}

    public mutating func update(enabled: Bool, lidClosed: Bool, busy: Bool, fresh: Bool,
                                protected: Bool, now: TimeInterval, observedAt: TimeInterval? = nil) -> Bool {
        guard enabled, lidClosed else { reset(); return false }
        guard fresh else { quietSince = nil; return false }
        if busy {
            quietSince = nil
            if protected { armed = true }
            return false
        }
        guard armed else { return false }
        if quietSince == nil { quietSince = now }
        return (observedAt ?? now) - (quietSince ?? now) >= Self.quietSeconds
    }

    public mutating func reset() { armed = false; quietSince = nil }
}

public enum MacLid {
    /// Unavailable readings never authorize automatic sleep.
    public static func isClosed() -> Bool {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard service != 0 else { return false }
        defer { IOObjectRelease(service) }
        return IORegistryEntryCreateCFProperty(service, "AppleClamshellState" as CFString,
                                               kCFAllocatorDefault, 0)?.takeRetainedValue() as? Bool == true
    }
}

/// macOS releases this assertion if the owning process exits. It does not hold the display on.
public final class IdleSleepAssertion {
    private var assertion: IOPMAssertionID = 0
    public private(set) var isHeld = false

    public init() {}

    public func setHeld(_ wanted: Bool) throws {
        guard wanted != isHeld else { return }
        let result: IOReturn
        if wanted {
            result = IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn), "Warden: active work or a phone reply is pending" as CFString, &assertion)
        } else {
            result = IOPMAssertionRelease(assertion)
        }
        guard result == kIOReturnSuccess else {
            throw NSError(domain: "Warden.Power", code: Int(result),
                          userInfo: [NSLocalizedDescriptionKey: "macOS could not update Warden's sleep assertion (\(result))."])
        }
        isHeld = wanted
    }

    deinit { if isHeld { IOPMAssertionRelease(assertion) } }
}
