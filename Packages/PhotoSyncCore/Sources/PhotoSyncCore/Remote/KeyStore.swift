import Citadel
import Crypto
import Foundation

/// Holds this Mac's Ed25519 SSH key.
///
/// Stored as a 0600 file inside the app's sandbox container rather than the
/// Keychain: with ad-hoc / free-account signing the code signature changes on
/// every rebuild, and legacy Keychain ACLs would then prompt for her password —
/// breaking "no password prompts, ever". The container is private to the app.
public struct KeyStore: Sendable {
    public let url: URL

    public init(url: URL) { self.url = url }

    public func load() -> Curve25519.Signing.PrivateKey? {
        guard let raw = try? Data(contentsOf: url) else { return nil }
        return try? Curve25519.Signing.PrivateKey(rawRepresentation: raw)
    }

    @discardableResult
    public func generate() throws -> Curve25519.Signing.PrivateKey {
        let key = Curve25519.Signing.PrivateKey()
        try save(key)
        return key
    }

    /// Imports an unencrypted OpenSSH Ed25519 private key (the `id_ed25519` file format).
    @discardableResult
    public func importOpenSSH(_ text: String) throws -> Curve25519.Signing.PrivateKey {
        let key = try Self.parseOpenSSH(text)
        try save(key)
        return key
    }

    public static func parseOpenSSH(_ text: String) throws -> Curve25519.Signing.PrivateKey {
        try Curve25519.Signing.PrivateKey(sshEd25519: text)
    }

    public func save(_ key: Curve25519.Signing.PrivateKey) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try key.rawRepresentation.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    /// The `authorized_keys` line for a key: `ssh-ed25519 AAAA… comment`.
    public static func publicKeyLine(_ key: Curve25519.Signing.PrivateKey, comment: String = "photosync") -> String {
        func sshString(_ d: Data) -> Data {
            var len = UInt32(d.count).bigEndian
            return Data(bytes: &len, count: 4) + d
        }
        let blob = sshString(Data("ssh-ed25519".utf8)) + sshString(key.publicKey.rawRepresentation)
        return "ssh-ed25519 \(blob.base64EncodedString()) \(comment)"
    }
}
