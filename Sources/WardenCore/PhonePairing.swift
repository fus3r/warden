import CryptoKit
import Foundation

/// A phone paired with Warden. The phone keeps a secret in a cookie; Warden keeps only the secret's hash.
public struct PhoneDevice: Codable, Equatable, Identifiable {
    public var id: String
    /// "iPhone", from the browser that paired.
    public var name: String
    public var pairedAt: Date
    public var lastSeen: Date
    public var secretHash: Data

    public init(id: String, name: String, pairedAt: Date, lastSeen: Date, secretHash: Data) {
        self.id = id
        self.name = name
        self.pairedAt = pairedAt
        self.lastSeen = lastSeen
        self.secretHash = secretHash
    }
}

/// A pairing opened by a click on the Mac: a single-use token in the QR code's link, and a six-digit code for a Home
/// Screen web app, which keeps cookies apart from Safari. Both last five minutes and close after five wrong tries.
public struct PairingWindow: Equatable {
    public let token: String
    public let code: String
    public let expiresAt: Date
    public private(set) var failures = 0

    public static let lifetime: TimeInterval = 300
    public static let maxFailures = 5

    public init(now: Date = Date()) {
        token = PhonePairing.randomToken(bytes: 16)
        code = String(format: "%06d", Int.random(in: 0..<1_000_000))
        expiresAt = now.addingTimeInterval(Self.lifetime)
    }

    public func isOpen(now: Date = Date()) -> Bool { now < expiresAt && failures < Self.maxFailures }

    /// Whether a pairing request carries this window's token or code. A wrong one counts toward closing the window.
    public mutating func accepts(token given: String?, code typed: String?, now: Date = Date()) -> Bool {
        guard isOpen(now: now) else { return false }
        let digits = typed.map { $0.filter(\.isNumber) }
        if let given, PhonePairing.same(Data(given.utf8), Data(token.utf8)) { return true }
        if let digits, !digits.isEmpty, PhonePairing.same(Data(digits.utf8), Data(code.utf8)) { return true }
        failures += 1
        return false
    }
}

public enum PhonePairing {
    /// The `__Host-` prefix makes the browser refuse the cookie unless it is Secure, for the whole site, and set by
    /// this host, so another `.local` device cannot plant or overwrite it.
    public static let cookieName = "__Host-warden"

    /// A new device and the secret its cookie carries.
    public static func pair(name: String, now: Date = Date()) -> (device: PhoneDevice, cookie: String) {
        let id = randomToken(bytes: 12)
        let secret = randomToken(bytes: 32)
        let device = PhoneDevice(id: id, name: name, pairedAt: now, lastSeen: now, secretHash: hash(secret))
        return (device, "\(id).\(secret)")
    }

    /// The Set-Cookie value for a pairing. The browser keeps it for 400 days, the longest it allows.
    public static func setCookie(_ value: String) -> String {
        "\(cookieName)=\(value); Path=/; Max-Age=34560000; Secure; HttpOnly; SameSite=Strict"
    }

    /// A Set-Cookie value that makes the browser forget the pairing.
    public static let clearCookie = "\(cookieName)=; Path=/; Max-Age=0; Secure; HttpOnly; SameSite=Strict"

    /// The paired device a Cookie header names, when its secret matches.
    public static func device(cookieHeader: String?, in devices: [PhoneDevice]) -> PhoneDevice? {
        guard let header = cookieHeader else { return nil }
        for pair in header.split(separator: ";") {
            let parts = pair.trimmingCharacters(in: .whitespaces).split(separator: "=", maxSplits: 1)
            guard parts.count == 2, parts[0] == cookieName else { continue }
            let value = parts[1].split(separator: ".", maxSplits: 1)
            guard value.count == 2, let device = devices.first(where: { $0.id == value[0] }) else { continue }
            if same(hash(String(value[1])), device.secretHash) { return device }
        }
        return nil
    }

    /// "iPhone", "iPad", or "Android phone", from a browser's User-Agent.
    public static func deviceName(userAgent: String?) -> String {
        let agent = userAgent ?? ""
        if agent.contains("iPhone") { return "iPhone" }
        if agent.contains("iPad") { return "iPad" }
        if agent.contains("Android") { return "Android phone" }
        // iPadOS Safari presents itself as a Mac.
        if agent.contains("Macintosh") { return "iPad or Mac" }
        return "Phone"
    }

    static func hash(_ secret: String) -> Data { Data(SHA256.hash(data: Data(secret.utf8))) }

    /// Compares in constant time, so the time an answer takes says nothing about how much of a secret matched.
    static func same(_ left: Data, _ right: Data) -> Bool {
        guard left.count == right.count else { return false }
        return zip(left, right).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0
    }

    /// Random bytes as base64url, safe in a URL fragment and a cookie.
    static func randomToken(bytes count: Int) -> String {
        var generator = SystemRandomNumberGenerator()
        let bytes = (0..<count).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// An HTTP/1.1 request as a browser sends it: a method, an origin-form target, headers, and a body of a declared
/// length. Anything else, such as a chunked body or a folded header, is refused.
public struct HTTPRequest: Equatable {
    public var method: String
    public var path: String
    public var query: [String: String]
    /// Header values by lowercased name. Repeated headers are joined, cookies with "; ".
    public var headers: [String: String]
    public var body: Data

    public enum Parse: Equatable {
        case incomplete
        case invalid
        case complete(HTTPRequest, consumed: Int)
    }

    public func header(_ name: String) -> String? { headers[name.lowercased()] }

    public static func parse(_ buffer: Data, maxHead: Int = 16_384, maxBody: Int = 16_384) -> Parse {
        let separator = Data("\r\n\r\n".utf8)
        guard let end = buffer.range(of: separator, in: buffer.startIndex..<buffer.endIndex) else {
            return buffer.count > maxHead ? .invalid : .incomplete
        }
        let headLength = end.lowerBound - buffer.startIndex
        guard headLength <= maxHead, let head = String(data: buffer[buffer.startIndex..<end.lowerBound], encoding: .utf8) else {
            return .invalid
        }
        var lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ", omittingEmptySubsequences: false)
        guard requestLine.count == 3, requestLine[2] == "HTTP/1.1" || requestLine[2] == "HTTP/1.0",
              requestLine[1].hasPrefix("/") else { return .invalid }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":"), line.first?.isWhitespace == false else { return .invalid }
            let name = line[..<colon].lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if let old = headers[name] { headers[name] = old + (name == "cookie" ? "; " : ", ") + value }
            else { headers[name] = value }
        }
        guard headers["transfer-encoding"] == nil else { return .invalid }
        let length: Int
        if let declared = headers["content-length"] {
            guard let value = Int(declared), value >= 0, value <= maxBody else { return .invalid }
            length = value
        } else {
            length = 0
        }
        let bodyStart = end.upperBound
        guard buffer.endIndex - bodyStart >= length else { return .incomplete }
        let target = String(requestLine[1])
        let pieces = target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        var query: [String: String] = [:]
        if pieces.count == 2 {
            for item in pieces[1].split(separator: "&") {
                let pair = item.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                let key = String(pair[0]).removingPercentEncoding ?? String(pair[0])
                query[key] = pair.count == 2 ? (String(pair[1]).removingPercentEncoding ?? String(pair[1])) : ""
            }
        }
        let request = HTTPRequest(method: String(requestLine[0]), path: String(pieces[0]), query: query, headers: headers,
                                  body: Data(buffer[bodyStart..<bodyStart + length]))
        return .complete(request, consumed: headLength + separator.count + length)
    }
}
