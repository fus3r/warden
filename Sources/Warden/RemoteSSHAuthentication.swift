import CryptoKit
import Foundation
import WardenCore

/// Sharing is authorized interactively in Terminal. Warden never captures passwords, MFA codes or approvals.
enum RemoteSSHAuthentication {
    static func controlPath(hostID: String, destination: String, root: URL = WardenPaths.support) -> URL {
        let digest = SHA256.hash(data: Data((hostID + "\0" + destination).utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
        return root.appendingPathComponent("ssh/" + digest + ".sock")
    }

    static func socketIdentity(_ path: URL) -> UInt64? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path.path),
              attributes[.type] as? FileAttributeType == .typeSocket else { return nil }
        return (attributes[.systemFileNumber] as? NSNumber)?.uint64Value
    }

    static func prepare(_ path: URL) throws {
        let directory = path.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    }

    static func required(_ message: String) -> Bool {
        ["permission denied", "authentication failed", "agent refused operation"].contains { message.lowercased().contains($0) }
    }
}
