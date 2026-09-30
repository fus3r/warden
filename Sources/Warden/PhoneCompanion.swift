import AppKit
import Combine
import Network
import SystemConfiguration
import UniformTypeIdentifiers
import WardenCore

/// Files of the phone companion, in a folder only the user can open.
enum PhoneFiles {
    static var folder: URL { WardenPaths.support.appendingPathComponent("Phone", isDirectory: true) }
    static var devicesFile: URL { folder.appendingPathComponent("devices.json") }
    static var certificateFile: URL { folder.appendingPathComponent("certificate.json") }

    static func devices(_ file: URL) -> [PhoneDevice] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? Data(contentsOf: file)).flatMap { try? decoder.decode([PhoneDevice].self, from: $0) } ?? []
    }

    static func save(_ devices: [PhoneDevice], to file: URL) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(devices) { write(data, to: file) }
    }

    static func certificate() -> PhoneCertificate? {
        (try? Data(contentsOf: certificateFile)).flatMap { try? JSONDecoder().decode(PhoneCertificate.self, from: $0) }
    }

    static func save(_ certificate: PhoneCertificate) {
        if let data = try? JSONEncoder().encode(certificate) { write(data, to: certificateFile) }
    }

    /// Writes a file only the user can read, in a folder only the user can open.
    private static func write(_ data: Data, to file: URL) {
        let manager = FileManager.default
        try? manager.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        chmod(folder.path, 0o700)
        try? data.write(to: file, options: .atomic)
        chmod(file.path, 0o600)
    }

    /// The page's files from the app's resources, by the path the browser asks for.
    static func page() -> [String: (data: Data, type: String)] {
        guard let folder = Bundle.main.resourceURL?.appendingPathComponent("Phone") else { return [:] }
        let types = ["index.html": "text/html; charset=utf-8", "app.js": "text/javascript; charset=utf-8",
                     "app.css": "text/css; charset=utf-8", "manifest.webmanifest": "application/manifest+json",
                     "icon.png": "image/png", "icon-192.png": "image/png", "icon-512.png": "image/png"]
        var files: [String: (data: Data, type: String)] = [:]
        for (name, type) in types {
            if let data = try? Data(contentsOf: folder.appendingPathComponent(name)) { files["/" + name] = (data, type) }
        }
        return files
    }
}

/// The phone companion: an HTTPS page on this Mac's local network where a paired phone sees what needs you and
/// answers prompts. Off by default. It listens only while it is on and a phone is paired or a pairing is open.
@MainActor
final class PhoneCompanion: ObservableObject {
    @Published private(set) var status: PhoneServer.Status = .stopped
    @Published private(set) var devices: [PhoneDevice] = []
    @Published private(set) var pairing: PairingWindow?
    /// The phone that paired last, for Settings to confirm it.
    @Published private(set) var justPaired: PhoneDevice?
    /// A pairing window that closed after wrong tries.
    @Published private(set) var pairingFailed = false
    @Published private(set) var certificate: PhoneCertificate?
    /// The Wi-Fi or Ethernet connection the page is served on. Nil without one.
    @Published private(set) var interface: NWInterface.InterfaceType?

    /// Answers a prompt, by approval id and choice; set by the store. Returns whether the prompt still waited.
    var answer: ((String, String) -> Bool)?
    /// What the phone shows now, from the store, sent as soon as the server starts.
    var currentState: (() -> PhoneState?)?
    var onAvailabilityChange: (() -> Void)?

    let remote = RemotePhone()
    private let server = PhoneServer()
    private let monitor = NWPathMonitor()
    private var running: (host: String, port: UInt16, interface: NWInterface.InterfaceType)?
    private var sent: PhoneState?
    private var version = 0
    private var pairingTimer: Timer?
    private let defaults = UserDefaults.standard

    var enabled: Bool { defaults.bool(forKey: "phoneEnabled") }
    var usesRelay: Bool {
        RemotePhone.relayURL != nil && (defaults.string(forKey: "phoneMode") ?? "remote") == "remote"
    }
    var pairedCount: Int { usesRelay ? remote.devices.count : devices.count }
    func setMode(_ relay: Bool) {
        endPairing()
        defaults.set(relay ? "remote" : "local", forKey: "phoneMode")
        if enabled, !relay, certificate == nil { issueCertificate() }
        update(); objectWillChange.send()
    }
    /// Whether the server runs, so the store builds states only for it.
    var isServing: Bool { usesRelay ? enabled && RemotePhone.relayURL != nil : running != nil }

    /// The port, chosen at random once so a bookmark on the phone keeps working.
    var port: UInt16 {
        if let saved = defaults.object(forKey: "phonePort") as? Int, (49_152...65_535).contains(saved) { return UInt16(saved) }
        let chosen = Int.random(in: 49_152...65_535)
        defaults.set(chosen, forKey: "phonePort")
        return UInt16(chosen)
    }

    /// This Mac's name on the local network, such as "Studio-MacBook-Pro.local".
    static var localHost: String? {
        (SCDynamicStoreCopyLocalHostName(nil) as String?).map { "\($0).local" }
    }

    /// The Mac's name as its owner knows it, such as "Ada's MacBook Pro".
    static var macName: String {
        (SCDynamicStoreCopyComputerName(nil, nil) as String?) ?? Host.current().localizedName ?? "this Mac"
    }

    var url: URL? { usesRelay ? RemotePhone.relayURL : certificate.flatMap { URL(string: "https://\($0.host.lowercased()):\(port)/") } }

    /// The link in the pairing QR code. The token sits in the fragment, which the browser never sends.
    var pairingURL: URL? {
        guard let url, let pairing else { return nil }
        return URL(string: url.absoluteString + "#p=" + pairing.token)
    }

    /// The certificate names another host than this Mac's current name, so the phone cannot reach it by that name.
    var hostChanged: Bool {
        guard let certificate, let host = Self.localHost else { return false }
        return certificate.host.lowercased() != host.lowercased()
    }

    func start() {
        // Existing local setups keep their transport. New installs use the service only when included in the build.
        if defaults.object(forKey: "phoneMode") == nil, enabled { defaults.set("local", forKey: "phoneMode") }
        remote.currentState = { [weak self] in self?.currentState?() }
        remote.answer = { [weak self] id, choice in self?.answer?(id, choice) ?? false }
        remote.onChange = { [weak self] in self?.objectWillChange.send(); self?.onAvailabilityChange?() }
        server.onStatus = { [weak self] status in MainActor.assumeIsolated { self?.status = status } }
        server.onDevices = { [weak self] devices in
            MainActor.assumeIsolated {
                self?.devices = devices
                self?.update()
            }
        }
        server.onPairingClosed = { [weak self] device in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.justPaired = device
                self.pairingFailed = device == nil
                self.endPairing()
            }
        }
        server.onAnswer = { [weak self] approval, choice in
            MainActor.assumeIsolated { self?.answer?(approval, choice) ?? false }
        }
        server.loadDevices(from: PhoneFiles.devicesFile)
        certificate = PhoneFiles.certificate()
        if enabled, !usesRelay, certificate == nil { issueCertificate() }
        monitor.pathUpdateHandler = { [weak self] path in
            // Wi-Fi or Ethernet, even behind a VPN that is the path's first interface.
            let type = path.availableInterfaces.first { $0.type == .wifi || $0.type == .wiredEthernet }?.type
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.interface != type else { return }
                    self.interface = type
                    self.update()
                }
            }
        }
        monitor.start(queue: DispatchQueue(label: "Warden.phone.path"))
    }

    func setEnabled(_ enabled: Bool) {
        defaults.set(enabled, forKey: "phoneEnabled")
        if enabled, !usesRelay, certificate == nil { issueCertificate() }
        if !enabled { endPairing() }
        objectWillChange.send()
        update()
    }

    /// Makes new certificates, for a Mac whose name changed or when they expire. Phones need the new profile.
    func issueCertificate() {
        guard let host = Self.localHost, let issued = try? PhoneCertificate.issue(host: host, macName: Self.macName) else { return }
        PhoneFiles.save(issued)
        certificate = issued
        running = nil
        update()
    }

    /// Opens a pairing for five minutes and starts listening for it.
    func openPairing() {
        if usesRelay { remote.openPairing(); return }
        let window = PairingWindow()
        pairing = window
        justPaired = nil
        pairingFailed = false
        server.openPairing(window)
        pairingTimer?.invalidate()
        pairingTimer = Timer.scheduledTimer(withTimeInterval: PairingWindow.lifetime, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.endPairing() }
        }
        update()
    }

    func endPairing() {
        remote.cancelPairing()
        pairingTimer?.invalidate()
        pairingTimer = nil
        pairing = nil
        server.closePairing()
        update()
    }

    func unpair(_ device: PhoneDevice) {
        devices.removeAll { $0.id == device.id }
        server.forget(device: device.id)
        update()
    }

    /// Sends the latest state to paired phones when what they show changed.
    func publish(_ state: PhoneState) {
        if usesRelay { remote.publish(state); return }
        guard running != nil, !state.sameContent(as: sent) else { return }
        version += 1
        var state = state
        state.version = version
        sent = state
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(state) { server.publish(data, version: version) }
    }

    /// Listens only while the companion is on, with a certificate and a Wi-Fi or Ethernet connection, and while a
    /// phone is paired or a pairing is open.
    private func update() {
        defer { onAvailabilityChange?() }
        remote.setEnabled(enabled && usesRelay)
        guard enabled, !usesRelay, let certificate, let interface, !devices.isEmpty || pairing != nil else {
            if running != nil {
                running = nil
                sent = nil
                server.stop()
            }
            return
        }
        let port = self.port
        if let running, running.host == certificate.host, running.port == port, running.interface == interface { return }
        running = (certificate.host, port, interface)
        sent = nil
        server.start(certificate: certificate, port: port, interface: interface, devicesFile: PhoneFiles.devicesFile)
        if let state = currentState?() { publish(state) }
    }

    // MARK: Profile

    /// The profile that installs Warden's root on a phone, written where AirDrop and the save panel can take it.
    private func profileFile() -> URL? {
        guard let certificate else { return nil }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("Warden on \(Self.macName).mobileconfig")
        do {
            try certificate.profile(macName: Self.macName).write(to: file, options: .atomic)
            return file
        } catch {
            return nil
        }
    }

    func sendProfileWithAirDrop() {
        guard let file = profileFile(), let service = NSSharingService(named: .sendViaAirDrop) else { return }
        NSApp.activate()
        service.perform(withItems: [file])
    }

    func saveProfile() {
        guard let file = profileFile() else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = file.lastPathComponent
        panel.allowedContentTypes = [UTType(filenameExtension: "mobileconfig") ?? .data]
        panel.message = "Open this profile on your phone, for example from Files, then install it in Settings."
        NSApp.activate()
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        try? FileManager.default.removeItem(at: destination)
        try? FileManager.default.copyItem(at: file, to: destination)
    }
}
