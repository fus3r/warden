import Network
import Security
import XCTest
@testable import Warden
import WardenCore

final class PhoneServerTests: XCTestCase {
    func testForgettingAPhoneWithdrawsItsWaitingStateRequest() async throws {
        try await checkRevocation(unpairFromPhone: false)
    }

    func testUnpairingAPhoneWithdrawsItsOtherWaitingStateRequest() async throws {
        try await checkRevocation(unpairFromPhone: true)
    }

    private func checkRevocation(unpairFromPhone: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let previous = ProcessInfo.processInfo.environment["WARDEN_SUPPORT_DIR"]
        setenv("WARDEN_SUPPORT_DIR", root.path, 1)
        defer {
            if let previous { setenv("WARDEN_SUPPORT_DIR", previous, 1) }
            else { unsetenv("WARDEN_SUPPORT_DIR") }
            try? FileManager.default.removeItem(at: root)
        }
        guard WardenPaths.support.standardizedFileURL.path == root.standardizedFileURL.path else {
            throw XCTSkip("The phone fixture requires debug storage isolation.")
        }
        let first = PhonePairing.pair(name: "First", now: Date(timeIntervalSince1970: 0))
        let second = PhonePairing.pair(name: "Second")
        PhoneFiles.save([first.device, second.device], to: PhoneFiles.devicesFile)
        let certificate = try PhoneCertificate.issue(host: "localhost", macName: "Phone Test")
        let trust = LocalTrust(root: try XCTUnwrap(SecCertificateCreateWithData(nil, certificate.root as CFData)))
        let session = URLSession(configuration: .ephemeral, delegate: trust, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let server = PhoneServer()
        defer { server.stop() }
        let ready = expectation(description: "HTTPS listener ready")
        server.onStatus = { status in
            if status == .listening { ready.fulfill() }
            if case .failed(let error) = status { XCTFail(error); ready.fulfill() }
        }
        let waiting = expectation(description: "First phone's state request authenticated")
        server.onDevices = { devices in
            if (devices.first(where: { $0.id == first.device.id })?.lastSeen.timeIntervalSince1970 ?? 0) > 0 {
                waiting.fulfill()
            }
        }
        server.loadDevices(from: PhoneFiles.devicesFile)
        server.publish(Data(#"{"version":1}"#.utf8), version: 1)
        let port = UInt16.random(in: 49_152...65_535)
        server.start(certificate: certificate, port: port, interface: .loopback, devicesFile: PhoneFiles.devicesFile)
        await fulfillment(of: [ready], timeout: 3)

        let origin = "https://localhost:\(port)"
        func request(_ path: String, cookie: String) throws -> URLRequest {
            var request = URLRequest(url: try XCTUnwrap(URL(string: origin + path)))
            request.timeoutInterval = 3
            request.setValue("\(PhonePairing.cookieName)=\(cookie)", forHTTPHeaderField: "Cookie")
            return request
        }
        let completed = expectation(description: "Revoked state request ended")
        let held = session.dataTask(with: try request("/api/state?since=1", cookie: first.cookie)) { data, response, _ in
            XCTAssertNotEqual((response as? HTTPURLResponse)?.statusCode, 200,
                              "A revoked phone must not receive a successful state response.")
            XCTAssertFalse(String(decoding: data ?? Data(), as: UTF8.self).contains("private-update"))
            completed.fulfill()
        }
        held.resume()
        await fulfillment(of: [waiting], timeout: 3)
        server.onDevices = nil
        if unpairFromPhone {
            var unpair = try request("/api/unpair", cookie: first.cookie)
            unpair.httpMethod = "POST"
            unpair.setValue(origin, forHTTPHeaderField: "Origin")
            unpair.setValue("1", forHTTPHeaderField: "X-Warden")
            let (_, response) = try await session.data(for: unpair)
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        } else {
            server.forget(device: first.device.id)
        }
        server.publish(Data(#"{"version":2,"message":"private-update"}"#.utf8), version: 2)
        await fulfillment(of: [completed], timeout: 3)

        let (_, revoked) = try await session.data(for: request("/api/state", cookie: first.cookie))
        XCTAssertEqual((revoked as? HTTPURLResponse)?.statusCode, 401)
        let (data, kept) = try await session.data(for: request("/api/state", cookie: second.cookie))
        XCTAssertEqual((kept as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("private-update"),
                      "Other paired phones must keep receiving state.")
    }

    private final class LocalTrust: NSObject, URLSessionDelegate {
        let root: SecCertificate
        init(root: SecCertificate) { self.root = root }

        func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
            guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
                  let trust = challenge.protectionSpace.serverTrust else {
                return completionHandler(.performDefaultHandling, nil)
            }
            SecTrustSetAnchorCertificates(trust, [root] as CFArray)
            SecTrustSetAnchorCertificatesOnly(trust, true)
            if SecTrustEvaluateWithError(trust, nil) { completionHandler(.useCredential, URLCredential(trust: trust)) }
            else { completionHandler(.cancelAuthenticationChallenge, nil) }
        }
    }
}
