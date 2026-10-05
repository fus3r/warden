import XCTest
@testable import WardenCore

final class RemoteFeedTests: XCTestCase {
    func testSystemOpenSSLPacketCanBeOpenedAndTamperingFails() throws {
        var feed = RemoteFeed(relay: "https://relay.example")
        feed.room = "example-room"; feed.key = String(repeating: "A", count: 43)
        // Generated through OpenSSL EVP AES-256-GCM with HKDF-SHA256 in the Python publisher.
        let packet = "MNr-jnolNzG4VSotL6OlGe-me7GOnFhoGbpiFXyRXqOWho7nof3o9SJumf_cAa3e4zPmvPj0bBw"
        XCTAssertEqual(String(decoding: try feed.open(packet), as: UTF8.self), "Warden compatibility fixture")
        XCTAssertThrowsError(try feed.open("A" + packet.dropFirst()))
        feed.room = "another-room"
        XCTAssertThrowsError(try feed.open(packet))
    }

    func testReleaseRelayURLsCannotContainSecretsOrRedirectPathsAndOldSSHHostsStillLoad() throws {
        XCTAssertNotNil(RemoteFeed.url("https://relay.example"))
        for value in ["http://relay.example", "https://user:secret@relay.example", "https://relay.example/publish", "https://relay.example?token=secret"] {
            XCTAssertNil(RemoteFeed.url(value))
        }
        let host = try JSONDecoder().decode(RemoteSSHHost.self, from: Data("{\"id\":\"h\",\"name\":\"Lab\",\"destination\":\"cluster\",\"enabled\":true}".utf8))
        XCTAssertNil(host.feed)
        XCTAssertEqual(host.destination, "cluster")
    }
}
