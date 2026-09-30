import Foundation
import XCTest
@testable import WardenCore

final class RemotePhoneCryptoTests: XCTestCase {
    func testNodeCipherCanBeReadAndCannotBeReplayedInAnotherDirectionOrRoom() throws {
        // Generated independently with Node crypto.hkdfSync + createCipheriv('aes-256-gcm').
        let secret = "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8" // gitleaks:allow (test vector, bytes 0...31)
        let packet = "AAECAwQFBgcICQoLymzeNuHnj0d9n6E80Gk_lLbV32E3d_6n_TujGfO_v-ML3RaiHfBlIEPXCf9acHY"
        let plaintext = try RemotePhoneCrypto.open(packet, secret: secret, room: "test-room", direction: .toMac)
        XCTAssertEqual(String(decoding: plaintext, as: UTF8.self), #"{"type":"hello","name":"Phone"}"#)
        XCTAssertThrowsError(try RemotePhoneCrypto.open(packet, secret: secret, room: "another-room", direction: .toMac))
        XCTAssertThrowsError(try RemotePhoneCrypto.open(packet, secret: secret, room: "test-room", direction: .toPhone))
        var corrupted = try XCTUnwrap(RemotePhoneCrypto.decode(packet)); corrupted[15] ^= 1
        XCTAssertThrowsError(try RemotePhoneCrypto.open(RemotePhoneCrypto.encode(corrupted), secret: secret, room: "test-room", direction: .toMac))
    }
}
