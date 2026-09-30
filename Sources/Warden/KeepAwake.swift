import AppKit
import Combine
import Foundation
import ServiceManagement
import WardenCore

@MainActor
final class KeepAwake: ObservableObject {
    @Published private(set) var status = "Off"
    @Published private(set) var detail = "The Mac follows its usual sleep settings."
    @Published private(set) var isAwake = false
    @Published private(set) var closedLidActive = false
    @Published private(set) var helperStatus: SMAppService.Status = .notRegistered
    @Published private(set) var error: String?
    @Published private(set) var isRemovingHelper = false

    private let defaults = UserDefaults.standard
    private let assertion = IdleSleepAssertion()
    private let service = SMAppService.daemon(plistName: WardenPowerService.plist)
    private var connection: NSXPCConnection?
    private var connectionID: UUID?
    private var timer: Timer?
    private var working = false
    private var guardedJobs = false
    private var phoneAwaitingReply = false
    private var observedAt = Date.distantPast
    private var requestNumber = 0
    private var removalID: UUID?
    private var helperRepliedAt: TimeInterval?
    private var helperNote = ""
    private var assertionError: String?
    private var policy: KeepAwakePolicy = .off

    var canAuthorizeHelper: Bool {
        Bundle.main.bundleIdentifier == "com.fus3r.Warden"
            && WardenPowerService.signingRequirement(identifier: WardenPowerService.name) != nil
    }

    private var isFixture: Bool {
        #if DEBUG
        return DebugSupport.usesFixture
        #else
        return false
        #endif
    }

    func start() {
        guard timer == nil else { return }
        refresh()
        let timer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func update(working: Bool, guardedJobs: Bool = false, phoneAwaitingReply: Bool = false, observedAt: Date = Date()) {
        self.working = working
        self.guardedJobs = guardedJobs
        self.phoneAwaitingReply = phoneAwaitingReply
        self.observedAt = observedAt
        refresh()
    }

    func refresh() {
        helperStatus = service.status
        if closedLidActive, let replied = helperRepliedAt,
           ProcessInfo.processInfo.systemUptime - replied >= WardenPowerService.leaseSeconds {
            closedLidActive = false
            helperNote = "The power service has not confirmed protection recently. Keep the lid open and check the service."
        }
        let allowBattery = defaults.bool(forKey: "keepAwakeOnBattery")
        policy = KeepAwakePolicy.evaluate(enabled: defaults.bool(forKey: "keepAwake"), working: working,
            fresh: Date().timeIntervalSince(observedAt) < 60, allowBattery: allowBattery, power: MacPowerState.read(),
            guardedJobs: guardedJobs, phoneAwaitingReply: phoneAwaitingReply)
        do {
            try assertion.setHeld(policy == .awake && !isFixture)
            isAwake = assertion.isHeld
            assertionError = nil
        } catch { assertionError = error.localizedDescription }
        let wantsLid = policy == .awake && defaults.bool(forKey: "keepAwakeClosedLid") && !isRemovingHelper
        if !isFixture, canAuthorizeHelper, helperStatus == .enabled,
           wantsLid || connection != nil {
            renewHelper(awake: wantsLid, allowBattery: allowBattery)
        } else if connection != nil {
            disconnect()
        }
        describeStatus()
    }

    func setClosedLid(_ enabled: Bool) {
        error = nil
        if enabled {
            guard canAuthorizeHelper else {
                error = "Enable closed-lid work in the signed, installed Warden app. Previews only support idle sleep."
                return
            }
            do {
                if service.status == .notRegistered || service.status == .notFound { try service.register() }
            } catch {
                self.error = "Could not enable the power service: \(error.localizedDescription)"
                return
            }
        }
        defaults.set(enabled, forKey: "keepAwakeClosedLid")
        refresh()
    }

    func openApprovalSettings() { SMAppService.openSystemSettingsLoginItems() }

    /// Restore first and wait for acknowledgement before asking launchd to remove the service.
    func removeHelper() {
        guard !isRemovingHelper else { return }
        guard canAuthorizeHelper, !isFixture else {
            error = "Manage the power service from the signed, installed Warden app."
            return
        }
        error = nil
        defaults.set(false, forKey: "keepAwakeClosedLid")
        isRemovingHelper = true
        let id = UUID()
        removalID = id
        let finish: (Bool, String) -> Void = { [weak self] held, message in
            Task { @MainActor in
                guard let self, self.removalID == id else { return }
                self.removalID = nil
                defer { self.isRemovingHelper = false }
                guard !held, message.isEmpty else {
                    self.error = message.isEmpty ? "Another Warden instance still needs the power service." : message
                    return
                }
                do {
                    try await self.service.unregister()
                    self.disconnect()
                    self.refresh()
                } catch { self.error = "Could not remove the power service: \(error.localizedDescription)" }
            }
        }
        if service.status == .enabled {
            DispatchQueue.main.asyncAfter(deadline: .now() + 10) {
                finish(true, "The power service did not confirm normal sleep within 10 seconds. It remains installed so it can restore sleep. Try removing it again once it responds.")
            }
            guard let proxy = helperProxy(onError: { finish(true, $0) }) else {
                finish(true, "The power service is unavailable. Try again before removing it.")
                return
            }
            proxy.renew(awake: false, allowBattery: false, reply: finish)
        } else {
            finish(false, "")
        }
    }

    func shutdown() {
        timer?.invalidate()
        timer = nil
        try? assertion.setHeld(false)
        disconnect() // The service restores on XPC disconnect, with lease expiry as a fallback.
    }

    private func disconnect() {
        requestNumber += 1
        connectionID = nil
        connection?.invalidate()
        connection = nil
        closedLidActive = false
        helperRepliedAt = nil
        helperNote = ""
    }

    private func helperProxy(onError: @escaping (String) -> Void) -> WardenPowerProtocol? {
        if connection == nil {
            guard let requirement = WardenPowerService.signingRequirement(identifier: WardenPowerService.name) else { return nil }
            let connection = NSXPCConnection(machServiceName: WardenPowerService.name, options: .privileged)
            let id = UUID()
            connectionID = id
            connection.remoteObjectInterface = NSXPCInterface(with: WardenPowerProtocol.self)
            connection.setCodeSigningRequirement(requirement)
            connection.invalidationHandler = { [weak self] in
                Task { @MainActor in
                    guard let self, self.connectionID == id else { return }
                    self.disconnect()
                    self.helperNote = "Power service disconnected. Closed-lid sleep protection is unavailable."
                    self.describeStatus()
                }
            }
            connection.interruptionHandler = connection.invalidationHandler
            connection.resume()
            self.connection = connection
        }
        return connection?.remoteObjectProxyWithErrorHandler { error in onError(error.localizedDescription) } as? WardenPowerProtocol
    }

    private func renewHelper(awake: Bool, allowBattery: Bool) {
        requestNumber += 1
        let number = requestNumber
        let receive: (Bool, String) -> Void = { [weak self] held, message in
            Task { @MainActor in
                guard let self, self.requestNumber == number else { return }
                self.closedLidActive = held
                self.helperRepliedAt = ProcessInfo.processInfo.systemUptime
                self.helperNote = message
                self.describeStatus()
            }
        }
        helperProxy(onError: { receive(false, "Power service unavailable: \($0)") })?
            .renew(awake: awake, allowBattery: allowBattery, reply: receive)
    }

    private func describeStatus() {
        switch policy {
        case .off:
            status = "Off"; detail = "The Mac follows its usual sleep settings."
        case .noWork:
            status = "Ready for the next task"; detail = "No agent or supervised job is running, and no paired phone has an answerable prompt waiting."
        case .stale:
            status = "Waiting for an activity update"; detail = "Sleep protection pauses when Warden has no fresh scan for a minute."
        case .needsPower:
            status = "Paused on battery"; detail = "Connect the power adapter or allow battery use below."
        case .lowBattery:
            status = "Paused at 20% battery or less"; detail = "The Mac can sleep normally to preserve its battery."
        case .unknownBattery:
            status = "Battery level unavailable"; detail = "Connect the power adapter to keep working."
        case .tooHot:
            status = "Paused to let the Mac cool"; detail = "macOS reports critical thermal pressure. Sleep protection is released."
        case .awake:
            let reason = working ? "agents work" : guardedJobs ? "supervised jobs run" : "a phone reply is pending"
            status = isAwake ? (closedLidActive ? "Keeping awake, including with lid closed" : "Keeping awake while " + reason) : "Sleep protection unavailable"
            detail = "The display can turn off and the screen can lock. Protection follows running agents, active train-guard jobs and answerable prompts for a paired phone."
        }
        if defaults.bool(forKey: "keepAwakeClosedLid"), helperStatus == .requiresApproval {
            detail += " Closed-lid work is waiting for approval in System Settings."
        } else if defaults.bool(forKey: "keepAwakeClosedLid"), !closedLidActive, policy == .awake {
            detail += " Closed-lid protection is not active."
        }
        if !helperNote.isEmpty { detail += " " + helperNote }
        if closedLidActive, policy != .awake || !defaults.bool(forKey: "keepAwakeClosedLid") {
            status = "Restoring normal sleep…"
        }
        if closedLidActive, !helperNote.isEmpty { status = "Sleep setting needs attention" }
        if let error = error ?? assertionError { detail = error }
        if isFixture {
            status = "Preview"
            detail = "This window does not change macOS sleep settings."
        }
    }
}
