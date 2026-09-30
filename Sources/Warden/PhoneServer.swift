import Darwin
import Foundation
import Network
import WardenCore

/// Serves the phone page and its API over HTTPS on the local network. Only a phone paired from this Mac gets the state
/// or can answer a prompt, and only over the Wi-Fi or Ethernet network the Mac is on. All state lives on `queue`.
final class PhoneServer: @unchecked Sendable {
    enum Status: Equatable {
        case stopped
        case listening
        case failed(String)
    }

    /// Called on the main queue.
    var onStatus: ((Status) -> Void)?
    var onDevices: (([PhoneDevice]) -> Void)?
    /// A pairing window closed: a phone paired, or wrong tries closed it.
    var onPairingClosed: ((PhoneDevice?) -> Void)?
    /// Answers a prompt from a phone and says whether it still waited. Called on the main queue.
    var onAnswer: ((_ approval: String, _ choice: String) -> Bool)?

    private let queue = DispatchQueue(label: "Warden.phone")
    private var listener: NWListener?
    private var origin = ""
    private var hostHeader = ""
    private var clients: [ObjectIdentifier: Client] = [:]
    private var devices: [PhoneDevice] = []
    private var pairing: PairingWindow?
    private var state = Data("{}".utf8)
    private var version = 0
    private var files: [String: (data: Data, type: String)] = [:]
    private var devicesFile: URL?

    private static let maxClients = 16
    /// How long a state request waits for a change before it answers with the same state.
    private static let pollSeconds = 25
    private static let idleSeconds = 30

    private final class Client {
        let connection: NWConnection
        var buffer = Data()
        var timer: DispatchSourceTimer?
        /// A state request held until the state moves past this version.
        var held: Int?
        init(_ connection: NWConnection) { self.connection = connection }
    }

    // MARK: Control

    func start(certificate: PhoneCertificate, port: UInt16, interface: NWInterface.InterfaceType, devicesFile: URL) {
        queue.async { self.listen(certificate: certificate, port: port, interface: interface, devicesFile: devicesFile) }
    }

    func stop() {
        queue.async {
            self.listener?.cancel()
            self.listener = nil
            for key in Array(self.clients.keys) { self.close(key) }
            self.report(.stopped)
        }
    }

    /// The latest state for phones, with its version, which wakes the requests waiting for a change.
    func publish(_ data: Data, version: Int) {
        queue.async {
            self.state = data
            self.version = version
            for (key, client) in self.clients where client.held != nil && client.held != version {
                client.held = nil
                self.respond(key, .json(data), keepAlive: true)
            }
        }
    }

    func openPairing(_ window: PairingWindow) {
        queue.async { self.pairing = window }
    }

    func closePairing() {
        queue.async { self.pairing = nil }
    }

    func forget(device id: String) {
        queue.async {
            self.devices.removeAll { $0.id == id }
            self.saveDevices()
        }
    }

    /// Paired devices from disk, read on the queue that uses them.
    func loadDevices(from file: URL) {
        queue.async {
            self.devicesFile = file
            self.devices = PhoneFiles.devices(file)
            let devices = self.devices
            DispatchQueue.main.async { self.onDevices?(devices) }
        }
    }

    // MARK: Listening

    private func listen(certificate: PhoneCertificate, port: UInt16, interface: NWInterface.InterfaceType, devicesFile: URL) {
        listener?.cancel()
        listener = nil
        self.devicesFile = devicesFile
        files = PhoneFiles.page()
        guard let identity = certificate.identity().flatMap(sec_identity_create) else {
            return report(.failed("Warden could not load its certificate. Renew it in Settings."))
        }
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_local_identity(tls.securityProtocolOptions, identity)
        sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
        let parameters = NWParameters(tls: tls)
        // Wi-Fi or Ethernet only: never loopback, a VPN, or AirDrop's peer-to-peer link.
        parameters.requiredInterfaceType = interface
        parameters.includePeerToPeer = false
        guard let endpointPort = NWEndpoint.Port(rawValue: port),
              let listener = try? NWListener(using: parameters, on: endpointPort) else {
            return report(.failed("Warden could not listen on port \(port)."))
        }
        origin = "https://\(certificate.host):\(port)".lowercased()
        hostHeader = "\(certificate.host):\(port)".lowercased()
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            switch state {
            case .ready: self?.report(.listening)
            case .failed(let error):
                listener?.cancel()
                if case .posix(let code) = error, code == .EADDRINUSE {
                    self?.report(.failed("Another app uses port \(port)."))
                } else {
                    self?.report(.failed(error.localizedDescription))
                }
            default: break
            }
        }
        self.listener = listener
        listener.start(queue: queue)
    }

    private func report(_ status: Status) {
        DispatchQueue.main.async { self.onStatus?(status) }
    }

    private func accept(_ connection: NWConnection) {
        guard clients.count < Self.maxClients else { return connection.cancel() }
        let client = Client(connection)
        let key = ObjectIdentifier(client)
        clients[key] = client
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                // Traffic routed from elsewhere, such as a global IPv6 peer, never gets past the handshake.
                guard PhoneNetwork.isOnLink(connection) else { self?.close(key); return }
                self?.receive(key)
            case .failed, .cancelled:
                self?.drop(key)
            default: break
            }
        }
        arm(key, seconds: Self.idleSeconds)
        connection.start(queue: queue)
    }

    private func receive(_ key: ObjectIdentifier) {
        guard let client = clients[key] else { return }
        client.connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, complete, error in
            guard let self, let client = self.clients[key] else { return }
            if let data, !data.isEmpty { client.buffer.append(data) }
            if error != nil || (complete && client.buffer.isEmpty) { return self.close(key) }
            self.process(key)
        }
    }

    private func process(_ key: ObjectIdentifier) {
        guard let client = clients[key], client.held == nil else { return }
        switch HTTPRequest.parse(client.buffer) {
        case .incomplete:
            receive(key)
        case .invalid:
            respond(key, .status(400, "Bad Request"), keepAlive: false)
        case .complete(let request, let consumed):
            client.buffer.removeFirst(consumed)
            handle(request, key)
        }
    }

    private func arm(_ key: ObjectIdentifier, seconds: Int) {
        guard let client = clients[key] else { return }
        client.timer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + .seconds(seconds))
        timer.setEventHandler { [weak self] in
            guard let self, let client = self.clients[key] else { return }
            if client.held != nil {
                // Nothing changed while the phone waited: it gets the same state and asks again.
                client.held = nil
                self.respond(key, .json(self.state), keepAlive: true)
            } else {
                self.close(key)
            }
        }
        client.timer = timer
        timer.resume()
    }

    private func close(_ key: ObjectIdentifier) {
        clients[key]?.connection.cancel()
        drop(key)
    }

    private func drop(_ key: ObjectIdentifier) {
        guard let client = clients.removeValue(forKey: key) else { return }
        client.timer?.cancel()
    }

    // MARK: Requests

    private func handle(_ request: HTTPRequest, _ key: ObjectIdentifier) {
        let keepAlive = request.header("connection")?.lowercased() != "close"
        // Another name in the Host header means a request meant for another site, as in DNS rebinding.
        guard request.header("host")?.lowercased() == hostHeader else {
            return respond(key, .status(421, "Misdirected Request"), keepAlive: false)
        }
        switch (request.method, request.path) {
        case ("GET", "/api/state"):
            guard authenticate(request) != nil else { return respond(key, .unpaired, keepAlive: keepAlive) }
            if let since = request.query["since"].flatMap(Int.init), since == version {
                clients[key]?.held = since
                arm(key, seconds: Self.pollSeconds)
            } else {
                respond(key, .json(state), keepAlive: keepAlive)
            }
        case ("POST", "/api/pair"):
            guard sameOrigin(request) else { return respond(key, .status(403, "Forbidden"), keepAlive: false) }
            pair(request, key)
        case ("POST", "/api/answer"):
            guard sameOrigin(request) else { return respond(key, .status(403, "Forbidden"), keepAlive: false) }
            guard authenticate(request) != nil else { return respond(key, .unpaired, keepAlive: keepAlive) }
            let body = (try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any] ?? [:]
            guard let approval = body["approval"] as? String, let choice = body["choice"] as? String else {
                return respond(key, .status(400, "Bad Request"), keepAlive: keepAlive)
            }
            DispatchQueue.main.async {
                let waited = self.onAnswer?(approval, choice) ?? false
                self.queue.async {
                    self.respond(key, waited ? .json(Data(#"{"ok":true}"#.utf8)) : .status(409, "Conflict"), keepAlive: keepAlive)
                }
            }
        case ("POST", "/api/unpair"):
            guard sameOrigin(request) else { return respond(key, .status(403, "Forbidden"), keepAlive: false) }
            if let device = authenticate(request) {
                devices.removeAll { $0.id == device.id }
                saveDevices()
            }
            var response = Response.json(Data(#"{"ok":true}"#.utf8))
            response.headers.append(("Set-Cookie", PhonePairing.clearCookie))
            respond(key, response, keepAlive: keepAlive)
        case ("GET", _), ("HEAD", _):
            // The page itself, which any browser on the network may load; it holds no state.
            guard let file = files[request.path == "/" ? "/index.html" : request.path] else {
                return respond(key, .status(404, "Not Found"), keepAlive: keepAlive)
            }
            var response = Response(status: 200, reason: "OK", type: file.type, body: request.method == "HEAD" ? Data() : file.data)
            if file.type.hasPrefix("text/html") {
                response.headers.append(("Content-Security-Policy", "default-src 'none'; script-src 'self'; style-src 'self'; img-src 'self'; connect-src 'self'; manifest-src 'self'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'"))
            }
            respond(key, response, keepAlive: keepAlive)
        default:
            respond(key, .status(405, "Method Not Allowed"), keepAlive: false)
        }
    }

    /// A change must come from Warden's own page: its Origin, and a header another site's form or image cannot send.
    private func sameOrigin(_ request: HTTPRequest) -> Bool {
        request.header("x-warden") == "1" && request.header("origin")?.lowercased() == origin
    }

    private func authenticate(_ request: HTTPRequest) -> PhoneDevice? {
        guard let device = PhonePairing.device(cookieHeader: request.header("cookie"), in: devices) else { return nil }
        let now = Date()
        // The last time a phone checked in, for Settings, saved at most once a minute.
        if now.timeIntervalSince(device.lastSeen) >= 60, let index = devices.firstIndex(where: { $0.id == device.id }) {
            devices[index].lastSeen = now
            saveDevices()
        }
        return device
    }

    private func pair(_ request: HTTPRequest, _ key: ObjectIdentifier) {
        let body = (try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any] ?? [:]
        guard var window = pairing else { return respond(key, .status(403, "Forbidden"), keepAlive: false) }
        let accepted = window.accepts(token: body["token"] as? String, code: body["code"] as? String)
        pairing = window.isOpen() && !accepted ? window : nil
        guard accepted else {
            if pairing == nil { DispatchQueue.main.async { self.onPairingClosed?(nil) } }
            return respond(key, .status(403, "Forbidden"), keepAlive: false)
        }
        let (device, cookie) = PhonePairing.pair(name: PhonePairing.deviceName(userAgent: request.header("user-agent")))
        devices.append(device)
        saveDevices()
        DispatchQueue.main.async { self.onPairingClosed?(device) }
        var response = Response.json(Data(#"{"ok":true}"#.utf8))
        response.headers.append(("Set-Cookie", PhonePairing.setCookie(cookie)))
        respond(key, response, keepAlive: true)
    }

    private func saveDevices() {
        if let devicesFile { PhoneFiles.save(devices, to: devicesFile) }
        let devices = self.devices
        DispatchQueue.main.async { self.onDevices?(devices) }
    }

    private func respond(_ key: ObjectIdentifier, _ response: Response, keepAlive: Bool) {
        guard let client = clients[key] else { return }
        client.connection.send(content: response.encoded(keepAlive: keepAlive), completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            if error != nil || !keepAlive { return self.close(key) }
            self.arm(key, seconds: Self.idleSeconds)
            self.process(key)
        })
    }

    struct Response {
        var status: Int
        var reason: String
        var type: String?
        var body = Data()
        var headers: [(String, String)] = []

        init(status: Int, reason: String, type: String? = nil, body: Data = Data()) {
            self.status = status
            self.reason = reason
            self.type = type
            self.body = body
        }

        static func status(_ code: Int, _ reason: String) -> Response { Response(status: code, reason: reason) }
        static func json(_ body: Data) -> Response { Response(status: 200, reason: "OK", type: "application/json", body: body) }
        static var unpaired: Response {
            Response(status: 401, reason: "Unauthorized", type: "application/json", body: Data(#"{"error":"unpaired"}"#.utf8))
        }

        func encoded(keepAlive: Bool) -> Data {
            var lines = ["HTTP/1.1 \(status) \(reason)", "Content-Length: \(body.count)", "Cache-Control: no-store",
                         "X-Content-Type-Options: nosniff", "Referrer-Policy: no-referrer", "X-Frame-Options: DENY",
                         "Connection: \(keepAlive ? "keep-alive" : "close")"]
            if let type { lines.append("Content-Type: \(type)") }
            lines += headers.map { "\($0.0): \($0.1)" }
            return Data((lines.joined(separator: "\r\n") + "\r\n\r\n").utf8) + body
        }
    }
}

/// Which peers may talk to the phone server.
enum PhoneNetwork {
    /// Whether a peer is on the network its connection came in through: an address in one of that interface's subnets,
    /// or a link-local IPv6 address, which is never routed. The listener already takes Wi-Fi or Ethernet only.
    static func isOnLink(_ connection: NWConnection) -> Bool {
        guard case .hostPort(let host, _) = connection.endpoint,
              let interface = connection.currentPath?.availableInterfaces.first?.name else { return false }
        let peer: [UInt8]
        switch host {
        case .ipv4(let address): peer = Array(address.rawValue)
        case .ipv6(let address):
            if let mapped = address.asIPv4 { peer = Array(mapped.rawValue) }
            else if address.isLinkLocal { return true }
            else { peer = Array(address.rawValue) }
        default: return false
        }
        return subnets(of: interface).contains { address, mask in
            address.count == peer.count && zip(zip(address, mask), peer).allSatisfy { ($0.0 & $0.1) == ($1 & $0.1) }
        }
    }

    /// The addresses and masks of an interface.
    private static func subnets(of interface: String) -> [(address: [UInt8], mask: [UInt8])] {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0 else { return [] }
        defer { freeifaddrs(list) }
        var result: [(address: [UInt8], mask: [UInt8])] = []
        var cursor = list
        while let entry = cursor?.pointee {
            defer { cursor = entry.ifa_next }
            guard String(cString: entry.ifa_name) == interface, let address = entry.ifa_addr, let mask = entry.ifa_netmask,
                  let addressBytes = bytes(address), let maskBytes = bytes(mask), addressBytes.count == maskBytes.count else { continue }
            result.append((addressBytes, maskBytes))
        }
        return result
    }

    private static func bytes(_ pointer: UnsafeMutablePointer<sockaddr>) -> [UInt8]? {
        switch Int32(pointer.pointee.sa_family) {
        case AF_INET:
            return pointer.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { withUnsafeBytes(of: $0.pointee.sin_addr) { Array($0) } }
        case AF_INET6:
            return pointer.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { withUnsafeBytes(of: $0.pointee.sin6_addr) { Array($0) } }
        default:
            return nil
        }
    }
}
