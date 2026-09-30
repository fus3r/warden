import Foundation
import Security

@objc public protocol WardenPowerProtocol {
    /// A request expires after 25 seconds without another message from this connection.
    func renew(awake: Bool, allowBattery: Bool, reply: @escaping (Bool, String) -> Void)
}

public enum WardenPowerService {
    public static let name = "com.fus3r.Warden.Power"
    public static let plist = name + ".plist"
    public static let leaseSeconds: TimeInterval = 25

    /// Bind both ends of XPC to this build's signing team and the other executable's fixed identifier.
    /// Ad-hoc previews may use idle assertions, but cannot authorize a root service.
    public static func signingRequirement(identifier: String) -> String? {
        var code: SecCode?
        var staticCode: SecStaticCode?
        var info: CFDictionary?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let values = info as? [String: Any], let team = values[kSecCodeInfoTeamIdentifier as String] as? String,
              !team.isEmpty, team.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }),
              ["com.fus3r.Warden", name].contains(identifier) else { return nil }
        return "anchor apple generic and identifier \"\(identifier)\" and certificate leaf[subject.OU] = \"\(team)\""
    }
}

/// Owns only changes from SleepDisabled=0 to 1. The root service supplies a durable restore marker.
/// A failed write or restore keeps that marker so the next tick or service launch can retry.
public final class SleepOverride {
    public enum State: Equatable { case inactive, held, alreadyDisabled }
    public private(set) var state: State = .inactive
    private var needsRestore: Bool
    private let read: () throws -> Bool
    private let write: (Bool) throws -> Void
    private let saveRestore: (Bool) throws -> Void

    public init(needsRestore: Bool, read: @escaping () throws -> Bool,
                write: @escaping (Bool) throws -> Void, saveRestore: @escaping (Bool) throws -> Void) {
        self.needsRestore = needsRestore
        self.read = read
        self.write = write
        self.saveRestore = saveRestore
    }

    public func setActive(_ active: Bool) throws {
        if active {
            guard state == .inactive else { return }
            // Finish any interrupted change before taking a fresh snapshot.
            if needsRestore { try setActive(false) }
            if try read() { state = .alreadyDisabled; return }
            try saveRestore(true)
            needsRestore = true
            try write(true)
            guard try read() else { throw PowerError("macOS did not disable sleep.") }
            state = .held
        } else {
            if needsRestore {
                if try read() { try write(false) }
                guard try !read() else { throw PowerError("macOS has not restored sleep. Warden will retry.") }
                try saveRestore(false)
                needsRestore = false
            }
            state = .inactive
        }
    }
}

public struct WakeLease {
    public var expiresAt: TimeInterval
    public var allowBattery: Bool

    public init(now: TimeInterval, allowBattery: Bool) {
        expiresAt = now + WardenPowerService.leaseSeconds
        self.allowBattery = allowBattery
    }

    public func permitsWake(now: TimeInterval, power: MacPowerState) -> Bool {
        now < expiresAt && !power.thermalCritical && (power.onAdapter || (allowBattery && power.allowsBatteryUse))
    }
}

public struct PowerError: LocalizedError {
    public var errorDescription: String?
    public init(_ message: String) { errorDescription = message }
}
