import Security
import XCTest
@testable import WardenCore

final class PhoneTests: XCTestCase {
    /// A phone that trusts Warden's root accepts the server for the Mac's name, in any case, and for no other name.
    func testServerCertificateIsTrustedForTheMacNameOnly() throws {
        let issued = try PhoneCertificate.issue(host: "Test-Mac.local", macName: "Test’s Mac")
        let root = try XCTUnwrap(SecCertificateCreateWithData(nil, issued.root as CFData))
        let server = try XCTUnwrap(SecCertificateCreateWithData(nil, issued.server as CFData))
        func trusted(_ host: String) -> Bool {
            var trust: SecTrust?
            guard SecTrustCreateWithCertificates(server, SecPolicyCreateSSL(true, host as CFString), &trust) == errSecSuccess,
                  let trust else { return false }
            SecTrustSetAnchorCertificates(trust, [root] as CFArray)
            SecTrustSetAnchorCertificatesOnly(trust, true)
            return SecTrustEvaluateWithError(trust, nil)
        }
        XCTAssertTrue(trusted("Test-Mac.local"))
        // Safari sends the name in lowercase.
        XCTAssertTrue(trusted("test-mac.local"))
        XCTAssertFalse(trusted("other.local"))
        XCTAssertFalse(trusted("example.com"))

        // The root carries critical name constraints, so it could not vouch for another site even if its key leaked.
        let values = try XCTUnwrap(SecCertificateCopyValues(root, ["2.5.29.30"] as CFArray, nil) as? [String: Any])
        XCTAssertNotNil(values["2.5.29.30"])

        // Apple refuses server certificates valid for more than 825 days.
        let expiry = try XCTUnwrap(issued.expiresAt)
        XCTAssertLessThanOrEqual(expiry.timeIntervalSinceNow, 825 * 86_400)

        // The listener's identity holds the server certificate and its key in memory.
        var certificate: SecCertificate?
        XCTAssertEqual(SecIdentityCopyCertificate(try XCTUnwrap(issued.identity()), &certificate), errSecSuccess)
        XCTAssertEqual(certificate.map { SecCertificateCopyData($0) as Data }, issued.server)

        // The profile installs the root, named after the Mac, and replaces an older one for the same name.
        let profile = try XCTUnwrap(PropertyListSerialization.propertyList(from: issued.profile(macName: "Test’s Mac"), format: nil) as? [String: Any])
        XCTAssertEqual(profile["PayloadIdentifier"] as? String, "com.fus3r.Warden.phone.test-mac.local")
        let payload = try XCTUnwrap((profile["PayloadContent"] as? [[String: Any]])?.first)
        XCTAssertEqual(payload["PayloadType"] as? String, "com.apple.security.root")
        XCTAssertEqual(payload["PayloadContent"] as? Data, issued.root)
    }

    func testPairingCookieNamesItsDeviceOnlyWithTheRightSecret() throws {
        let (device, cookie) = PhonePairing.pair(name: "iPhone")
        let other = PhonePairing.pair(name: "iPad").device
        let header = "theme=dark; \(PhonePairing.cookieName)=\(cookie)"
        XCTAssertEqual(PhonePairing.device(cookieHeader: header, in: [other, device])?.id, device.id)

        let id = try XCTUnwrap(cookie.split(separator: ".").first)
        XCTAssertNil(PhonePairing.device(cookieHeader: "\(PhonePairing.cookieName)=\(id).wrong", in: [device]))
        XCTAssertNil(PhonePairing.device(cookieHeader: header, in: [other]))
        XCTAssertNil(PhonePairing.device(cookieHeader: "warden=\(cookie)", in: [device]))
        XCTAssertNil(PhonePairing.device(cookieHeader: nil, in: [device]))
        // Warden keeps a hash, never the secret.
        XCTAssertFalse(String(decoding: device.secretHash, as: UTF8.self).contains(cookie))

        let set = PhonePairing.setCookie(cookie)
        for attribute in ["Secure", "HttpOnly", "SameSite=Strict", "Path=/"] { XCTAssertTrue(set.contains(attribute), attribute) }
        XCTAssertFalse(set.contains("Domain"))
        XCTAssertEqual(PhonePairing.deviceName(userAgent: "Mozilla/5.0 (iPhone; CPU iPhone OS 26_1 like Mac OS X) AppleWebKit/605.1.15"), "iPhone")
    }

    func testPairingWindowTakesItsTokenOrCodeAndClosesAfterWrongTries() {
        let start = Date()
        var window = PairingWindow(now: start)
        XCTAssertEqual(window.code.count, 6)
        XCTAssertTrue(window.accepts(token: window.token, code: nil, now: start))
        // The code as the Mac shows it, with a space.
        XCTAssertTrue(window.accepts(token: nil, code: "\(window.code.prefix(3)) \(window.code.suffix(3))", now: start))

        var guessed = PairingWindow(now: start)
        for _ in 0..<PairingWindow.maxFailures { XCTAssertFalse(guessed.accepts(token: "wrong", code: nil, now: start)) }
        XCTAssertFalse(guessed.isOpen(now: start))
        XCTAssertFalse(guessed.accepts(token: guessed.token, code: nil, now: start))

        var late = PairingWindow(now: start)
        XCTAssertFalse(late.accepts(token: late.token, code: nil, now: start.addingTimeInterval(PairingWindow.lifetime + 1)))
    }

    func testRequestsParseAsSafariSendsThemAndOversizeOnesAreRefused() {
        let body = #"{"approval":"a1","choice":"allow"}"#
        let post = "POST /api/answer HTTP/1.1\r\nHost: test-mac.local:50123\r\nContent-Type: application/json\r\n" +
            "Origin: https://test-mac.local:50123\r\nX-Warden: 1\r\nCookie: a=1\r\nCookie: b=2\r\nContent-Length: \(body.utf8.count)\r\n\r\n"
        let poll = "GET /api/state?since=42 HTTP/1.1\r\nHost: test-mac.local:50123\r\n\r\n"
        let bytes = Data((post + body + poll).utf8)

        // A body cut in the middle waits for the rest.
        XCTAssertEqual(HTTPRequest.parse(bytes.prefix(post.utf8.count + 5)), .incomplete)
        guard case .complete(let first, let consumed) = HTTPRequest.parse(bytes) else { return XCTFail("POST not parsed") }
        XCTAssertEqual(first.method, "POST")
        XCTAssertEqual(first.path, "/api/answer")
        XCTAssertEqual(first.header("X-Warden"), "1")
        XCTAssertEqual(first.header("cookie"), "a=1; b=2")
        XCTAssertEqual(String(decoding: first.body, as: UTF8.self), body)
        // The next request on the same connection follows.
        guard case .complete(let second, _) = HTTPRequest.parse(bytes.dropFirst(consumed)) else { return XCTFail("GET not parsed") }
        XCTAssertEqual(second.path, "/api/state")
        XCTAssertEqual(second.query["since"], "42")

        XCTAssertEqual(HTTPRequest.parse(Data("POST / HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n".utf8)), .invalid)
        XCTAssertEqual(HTTPRequest.parse(Data("POST / HTTP/1.1\r\nContent-Length: 999999\r\n\r\n".utf8)), .invalid)
        XCTAssertEqual(HTTPRequest.parse(Data("GET http://evil/ HTTP/1.1\r\n\r\n".utf8)), .invalid)
        XCTAssertEqual(HTTPRequest.parse(Data(("GET / HTTP/1.1\r\nX: " + String(repeating: "a", count: 20_000)).utf8)), .invalid)
    }
}
