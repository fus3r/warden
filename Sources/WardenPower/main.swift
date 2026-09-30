import Darwin
import Foundation
import WardenCore

/// launchd owns this process. Leases exist only in memory; a root-owned marker recovers a change after a crash/reboot.
final class PowerDaemon: NSObject, NSXPCListenerDelegate {
    private let control: SleepOverride
    private let clientRequirement: String
    private var leases: [UUID: WakeLease] = [:]
    private var timer: DispatchSourceTimer?
    private var termination: DispatchSourceSignal?

    init(serviceName: String) throws {
        guard geteuid() == 0 else { throw PowerError("WardenPower must be started by its approved macOS service.") }
        guard let requirement = WardenPowerService.signingRequirement(identifier: "com.fus3r.Warden") else {
            throw PowerError("WardenPower requires an Apple Development or Developer ID signature.")
        }
        clientRequirement = requirement
        let folder = URL(fileURLWithPath: "/Library/Application Support/\(serviceName)", isDirectory: true)
        let marker = folder.appendingPathComponent("restore-sleep")
        control = SleepOverride(needsRestore: FileManager.default.fileExists(atPath: marker.path),
                                read: PMSet.readSleepDisabled, write: PMSet.writeSleepDisabled) { pending in
            if pending {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                        attributes: [.posixPermissions: 0o700])
                try Data("0\n".utf8).write(to: marker, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: marker.path)
            } else if FileManager.default.fileExists(atPath: marker.path) {
                try FileManager.default.removeItem(at: marker)
            }
        }
        super.init()
    }

    func start() {
        _ = reconcile()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 5, repeating: 5)
        timer.setEventHandler { [weak self] in _ = self?.reconcile() }
        timer.resume()
        self.timer = timer
        signal(SIGTERM, SIG_IGN)
        let termination = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        termination.setEventHandler { [weak self] in
            self?.leases.removeAll()
            let error = self?.reconcile() ?? ""
            // A failed restoration remains on disk for the next launch; never erase the marker here.
            exit(error.isEmpty ? 0 : 1)
        }
        termination.resume()
        self.termination = termination
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        guard connection.effectiveUserIdentifier != 0 else { return false }
        let id = UUID()
        connection.setCodeSigningRequirement(clientRequirement)
        connection.exportedInterface = NSXPCInterface(with: WardenPowerProtocol.self)
        connection.exportedObject = PowerClient(daemon: self, id: id)
        connection.invalidationHandler = { [weak self] in
            DispatchQueue.main.async {
                self?.leases[id] = nil
                _ = self?.reconcile()
            }
        }
        connection.resume()
        return true
    }

    func renew(id: UUID, awake: Bool, allowBattery: Bool, reply: @escaping (Bool, String) -> Void) {
        DispatchQueue.main.async { [self] in
            leases[id] = awake ? WakeLease(now: ProcessInfo.processInfo.systemUptime, allowBattery: allowBattery) : nil
            let error = reconcile()
            let note = control.state == .alreadyDisabled
                ? "Sleep was already disabled outside Warden. Its existing setting will be left unchanged." : error
            reply(control.state == .held, note)
        }
    }

    private func reconcile() -> String {
        let now = ProcessInfo.processInfo.systemUptime
        leases = leases.filter { $0.value.expiresAt > now }
        let power = MacPowerState.read()
        let active = leases.values.contains { $0.permitsWake(now: now, power: power) }
        do {
            try control.setActive(active)
            return ""
        } catch {
            return error.localizedDescription
        }
    }
}

private final class PowerClient: NSObject, WardenPowerProtocol {
    let daemon: PowerDaemon
    let id: UUID
    init(daemon: PowerDaemon, id: UUID) { self.daemon = daemon; self.id = id }
    func renew(awake: Bool, allowBattery: Bool, reply: @escaping (Bool, String) -> Void) {
        daemon.renew(id: id, awake: awake, allowBattery: allowBattery, reply: reply)
    }
}

do {
    let daemon = try PowerDaemon(serviceName: WardenPowerService.name)
    let listener = NSXPCListener(machServiceName: WardenPowerService.name)
    listener.delegate = daemon
    daemon.start()
    listener.resume()
    withExtendedLifetime((daemon, listener)) { RunLoop.main.run() }
} catch {
    fputs("\(error.localizedDescription)\n", stderr)
    exit(1)
}
