import AppKit
import Foundation
import WardenCore

struct RemotePhoneDevice: Codable, Identifiable {
    var id = UUID()
    var name = "Phone"
    var room = RemotePhoneCrypto.token()
    var ownerToken = RemotePhoneCrypto.token()
    var phoneToken = RemotePhoneCrypto.token()
    var key = RemotePhoneCrypto.token()
    var pairedAt: Date?
    var expiresAt = Date().addingTimeInterval(300)
}

/// Outbound connections only. The public relay routes opaque packets between one Mac and one paired device.
@MainActor
final class RemotePhone: ObservableObject {
    @Published private(set) var devices: [RemotePhoneDevice] = []
    @Published private(set) var pending: RemotePhoneDevice?
    @Published private(set) var status = "Off"
    @Published private(set) var connected = false
    var currentState: (() -> PhoneState?)?
    var answer: ((String, String) -> Bool)?
    var onChange: (() -> Void)?
    private var enabled = false
    private var links: [UUID: RemotePhoneLink] = [:]
    private var expiry: Timer?
    private var loaded = false
    private var loadFailed = false
    private let file = PhoneFiles.folder.appendingPathComponent("remote-devices.json")

    static var relayURL: URL? {
        var value = Bundle.main.object(forInfoDictionaryKey: "WardenPhoneRelayURL") as? String
        #if DEBUG
        value = ProcessInfo.processInfo.environment["WARDEN_PHONE_RELAY_URL"] ?? value
        #endif
        guard let value, let url = URL(string: value), url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil, url.path.isEmpty || url.path == "/" else { return nil }
        if url.scheme == "https", url.host != nil { return url }
        #if DEBUG
        if url.scheme == "http", ["127.0.0.1", "localhost"].contains(url.host ?? "") { return url }
        #endif
        return nil
    }

    var pairingURL: URL? {
        guard let url = Self.relayURL, let pending,
              let data = try? JSONSerialization.data(withJSONObject: ["room": pending.room, "token": pending.phoneToken, "key": pending.key]) else { return nil }
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.fragment = "connect=" + RemotePhoneCrypto.encode(data)
        return components?.url
    }

    func setEnabled(_ value: Bool) {
        if !loaded {
            loaded = true
            if FileManager.default.fileExists(atPath: file.path) {
                do { devices = try JSONDecoder().decode([RemotePhoneDevice].self, from: Data(contentsOf: file)) }
                catch { loadFailed = true; status = "Saved phone pairings could not be read. They were left unchanged." }
            }
        }
        enabled = value
        if !value {
            cancelPairing()
            for link in links.values { link.stop() }
            links.removeAll(); connected = false; status = "Off"; onChange?(); return
        }
        guard !loadFailed else { onChange?(); return }
        guard Self.relayURL != nil else { status = "Remote phone service is not configured in this build."; onChange?(); return }
        for device in devices { connect(device) }
        if devices.isEmpty { status = "Ready to pair a phone" }
        onChange?()
    }

    func openPairing() {
        guard enabled, !loadFailed, Self.relayURL != nil else { return }
        cancelPairing()
        let device = RemotePhoneDevice()
        pending = device
        connect(device)
        expiry = Timer.scheduledTimer(withTimeInterval: 300, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.cancelPairing() }
        }
        onChange?()
    }

    func cancelPairing() {
        expiry?.invalidate(); expiry = nil
        if let pending { links.removeValue(forKey: pending.id)?.revoke() }
        pending = nil
        onChange?()
    }

    @discardableResult func unpair(_ id: UUID, disconnect: Bool = true) -> Bool {
        let before = devices
        devices.removeAll { $0.id == id }
        do { try save() }
        catch { devices = before; status = "Could not remove the saved pairing. Try again."; onChange?(); return false }
        let link = links.removeValue(forKey: id)
        if disconnect { link?.revoke() }
        onChange?()
        return true
    }

    func publish(_ state: PhoneState) { for link in links.values { link.publish(state) } }
    func notify() { for device in devices { links[device.id]?.send(["type": "notify"]) } }

    private func save() throws {
        try FileManager.default.createDirectory(at: PhoneFiles.folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let data = try JSONEncoder().encode(devices)
        try data.write(to: file, options: .atomic)
        chmod(file.path, 0o600)
    }

    private func connect(_ device: RemotePhoneDevice) {
        guard links[device.id] == nil, let url = Self.relayURL else { return }
        let link = RemotePhoneLink(device: device, relay: url)
        link.state = { [weak self] in self?.currentState?() }
        link.onStatus = { [weak self] in
            guard let self else { return }
            self.connected = self.links.values.contains { $0.connected }
            self.status = self.connected ? "Connected to the phone service" : "Reconnecting to the phone service…"
            self.onChange?()
        }
        link.onHello = { [weak self] name in
            guard let self else { return .rejected }
            if self.devices.contains(where: { $0.id == device.id }) { return .paired }
            guard let pending = self.pending, pending.id == device.id, pending.expiresAt > Date() else { return .rejected }
            // Exchange the short-lived QR credential for a different long-lived device key.
            // The old QR can no longer reconnect after this encrypted handoff.
            var paired = RemotePhoneDevice()
            paired.name = String(name.prefix(60)); paired.pairedAt = Date()
            self.devices.append(paired)
            do { try self.save() }
            catch { self.devices.removeAll { $0.id == paired.id }; self.status = "Could not save the pairing. Try again."; self.onChange?(); return .rejected }
            self.connect(paired)
            self.pending = nil; self.expiry?.invalidate(); self.expiry = nil
            let deadline = Date().addingTimeInterval(12)
            while self.enabled, self.links[paired.id]?.connected != true, Date() < deadline {
                do { try await Task.sleep(for: .milliseconds(100)) } catch { return .rejected }
            }
            guard self.links[paired.id]?.connected == true else {
                self.unpair(paired.id)
                self.links.removeValue(forKey: device.id)?.revoke()
                self.status = "The service did not finish pairing. Try again."; self.onChange?(); return .rejected
            }
            self.links.removeValue(forKey: device.id)
            self.onChange?()
            return .grant(paired)
        }
        link.onAnswer = { [weak self] approval, choice in
            guard let self, self.devices.contains(where: { $0.id == device.id }) else { return false }
            return self.answer?(approval, choice) ?? false
        }
        link.onUnpair = { [weak self] in self?.unpair(device.id, disconnect: false) ?? false }
        links[device.id] = link
        link.start()
    }
}

@MainActor
private final class RemotePhoneLink {
    let device: RemotePhoneDevice
    let relay: URL
    var state: (() -> PhoneState?)?
    var onStatus: (() -> Void)?
    enum Hello { case paired, grant(RemotePhoneDevice), rejected }
    var onHello: ((String) async -> Hello)?
    var onAnswer: ((String, String) -> Bool)?
    var onUnpair: (() -> Bool)?
    private(set) var connected = false
    private var socket: URLSessionWebSocketTask?
    private var task: Task<Void, Never>?
    private var challenge = ""
    private var client: String?
    private var sequence = 0
    private var answered = Set<String>()
    private var lastState: PhoneState?
    private let session = URLSession(configuration: .ephemeral)

    init(device: RemotePhoneDevice, relay: URL) { self.device = device; self.relay = relay }
    func start() {
        task = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                do {
                    var url = URLComponents(url: relay, resolvingAgainstBaseURL: false)!
                    url.scheme = relay.scheme == "https" ? "wss" : "ws"; url.path = "/v1/socket"
                    let ws = session.webSocketTask(with: url.url!); socket = ws
                    client = nil; lastState = nil; challenge = RemotePhoneCrypto.token(); answered.removeAll()
                    ws.maximumMessageSize = 1_000_000; ws.resume()
                    try await write(["role": "mac", "room": device.room, "token": device.ownerToken, "phoneToken": device.phoneToken])
                    while !Task.isCancelled {
                        let message = try await ws.receive()
                        guard case .string(let text) = message, let data = text.data(using: .utf8),
                              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                        try await receive(object)
                    }
                } catch { }
                connected = false; client = nil; onStatus?()
                socket?.cancel(with: .goingAway, reason: nil); socket = nil
                do { try await Task.sleep(for: .seconds(3)) } catch { break }
            }
        }
    }
    func stop() { task?.cancel(); task = nil; socket?.cancel(with: .normalClosure, reason: nil); socket = nil; connected = false }
    func revoke() {
        Task { [self] in
            try? await write(["type": "revoke"])
            stop()
        }
    }
    func send(_ value: [String: Any]) { Task { [weak self] in try? await self?.write(value) } }
    private func write(_ value: [String: Any]) async throws {
        guard let socket else { throw URLError(.notConnectedToInternet) }
        let data = try JSONSerialization.data(withJSONObject: value)
        try await socket.send(.string(String(decoding: data, as: UTF8.self)))
    }
    private func encrypted(_ value: [String: Any]) async throws {
        let data = try JSONSerialization.data(withJSONObject: value)
        let box = try RemotePhoneCrypto.seal(data, secret: device.key, room: device.room, direction: .toPhone)
        try await write(["type": "cipher", "box": box])
    }
    func publish(_ state: PhoneState) {
        guard let client, !state.sameContent(as: lastState),
              let data = try? JSONEncoder.phone.encode(state), let value = try? JSONSerialization.jsonObject(with: data) else { return }
        lastState = state; sequence += 1
        let payload: [String: Any] = ["type": "state", "challenge": challenge, "client": client, "sequence": sequence, "state": value]
        Task { [weak self] in try? await self?.encrypted(payload) }
    }
    private func receive(_ message: [String: Any]) async throws {
        let type = message["type"] as? String
        if type == "ready" { connected = true; onStatus?() }
        if (type == "ready" && message["peer"] as? Bool == true) || (type == "peer" && message["online"] as? Bool == true) {
            challenge = RemotePhoneCrypto.token(); client = nil; lastState = nil; answered.removeAll()
            try await encrypted(["type": "challenge", "challenge": challenge]); return
        }
        if type == "peer", message["online"] as? Bool == false { client = nil; return }
        guard type == "cipher", let box = message["box"] as? String,
              let bytes = try? RemotePhoneCrypto.open(box, secret: device.key, room: device.room, direction: .toMac),
              let value = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              value["challenge"] as? String == challenge, let proposedClient = value["client"] as? String,
              UUID(uuidString: proposedClient) != nil else { return }
        if value["type"] as? String == "hello" {
            guard let result = await onHello?(value["name"] as? String ?? "Phone") else { return }
            switch result {
            case .rejected: return
            case .grant(let paired):
                do {
                    try await encrypted(["type": "paired", "challenge": challenge, "client": proposedClient,
                                         "credentials": ["room": paired.room, "token": paired.phoneToken, "key": paired.key]])
                } catch { revoke(); throw error }
                revoke()
            case .paired:
                client = proposedClient; lastState = nil
                if let state = state?() { publish(state) }
            }
            return
        }
        guard client == proposedClient, let id = value["id"] as? String, UUID(uuidString: id) != nil,
              answered.insert(id).inserted else { return }
        if answered.count > 512 { answered = [id] }
        var ok = false
        let unpair = value["type"] as? String == "unpair"
        if value["type"] as? String == "answer", let approval = value["approval"] as? String, let choice = value["choice"] as? String {
            ok = onAnswer?(approval, choice) ?? false
        } else if unpair { ok = onUnpair?() ?? false }
        try await encrypted(["type": "reply", "challenge": challenge, "client": proposedClient, "id": id, "ok": ok])
        if unpair && ok { revoke() }
    }
}

private extension JSONEncoder {
    static var phone: JSONEncoder { let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; return encoder }
}
