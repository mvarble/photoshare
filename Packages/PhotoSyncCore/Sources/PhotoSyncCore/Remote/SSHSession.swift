import Citadel
import Crypto
import Foundation
import Logging
import NIOCore
import NIOSSH

/// Independent SFTP channels over one SSH connection. OpenSSH's sftp-server
/// answers requests serially per channel, so a big import download on its own
/// lane can't stall thumbnail reads (measured in spike 0b).
public enum Lane: String, CaseIterable, Sendable {
    case scan, browse, importing
}

/// Trust-on-first-use host key check: accepts and records the key on first
/// contact, then refuses any other key.
final class PinningHostKeyValidator: NIOSSHClientServerAuthenticationDelegate, @unchecked Sendable {
    let pinned: String?
    private let lock = NSLock()
    private var _seen: String?
    var seen: String? { lock.withLock { _seen } }

    init(pinned: String?) { self.pinned = pinned }

    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        let presented = String(openSSHPublicKey: hostKey)
        lock.withLock { _seen = presented }
        if let pinned, normalized(pinned) != normalized(presented) {
            validationCompletePromise.fail(RemoteFSError.hostKeyMismatch)
        } else {
            validationCompletePromise.succeed(())
        }
    }

    /// Compares "type base64" only, ignoring any trailing comment.
    private func normalized(_ line: String) -> String {
        line.split(separator: " ").prefix(2).joined(separator: " ")
    }
}

/// Owns the SSH connection and one SFTP channel per lane; reconnects on demand.
public actor SSHSession {
    public let config: ServerConfig
    private let key: Curve25519.Signing.PrivateKey
    private let onHostKeyPinned: @Sendable (String) -> Void

    private var client: SSHClient?
    private var connecting: Task<SSHClient, Error>?
    /// Keyed by lane and channel index; a lane may use several channels
    /// because each is served by its own sftp-server process on the host.
    private var channels: [String: SFTPClient] = [:]
    private var opening: [String: Task<SFTPClient, Error>] = [:]

    public init(
        config: ServerConfig,
        key: Curve25519.Signing.PrivateKey,
        onHostKeyPinned: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.config = config
        self.key = key
        self.onHostKeyPinned = onHostKeyPinned
        SSHSession.quietCitadelLogging()
    }

    /// Citadel logs every file open at `.info`; keep only warnings and errors.
    private static let loggingOnce: Void = {
        LoggingSystem.bootstrap { label in
            var h = StreamLogHandler.standardError(label: label)
            h.logLevel = .warning
            return h
        }
    }()
    static func quietCitadelLogging() { _ = loggingOnce }

    /// Connects (if needed) and returns SFTP channel `index` of `lane`.
    public func sftp(_ lane: Lane, index: Int = 0) async throws -> SFTPClient {
        let key = "\(lane.rawValue)#\(index)"
        if let ch = channels[key], ch.isActive, client?.isConnected == true { return ch }
        channels[key] = nil
        if let t = opening[key] { return try await t.value }
        let t = Task { () throws -> SFTPClient in
            let c = try await self.connectedClient()
            return try await c.openSFTP()
        }
        opening[key] = t
        defer { opening[key] = nil }
        let ch = try await t.value
        channels[key] = ch
        return ch
    }

    /// Opens all lanes up front (each costs ~600 ms against this server).
    public func warmUp() async throws {
        try await withThrowingTaskGroup(of: Void.self) { g in
            for lane in Lane.allCases { g.addTask { _ = try await self.sftp(lane) } }
            try await g.waitForAll()
        }
    }

    /// Runs `body` on a lane, reconnecting and retrying once if the connection dropped.
    public func withSFTP<T>(_ lane: Lane, index: Int = 0, _ body: (SFTPClient) async throws -> T) async throws -> T {
        let key = "\(lane.rawValue)#\(index)"
        do {
            return try await body(try await sftp(lane, index: index))
        } catch let e as RemoteFSError {
            throw e
        } catch {
            guard client?.isConnected != true || channels[key]?.isActive != true else { throw error }
            channels[key] = nil
            return try await body(try await sftp(lane, index: index))
        }
    }

    public func close() async {
        connecting?.cancel()
        for ch in channels.values { try? await ch.close() }
        channels = [:]
        try? await client?.close()
        client = nil
    }

    private func connectedClient() async throws -> SSHClient {
        if let client, client.isConnected { return client }
        if let connecting { return try await connecting.value }
        let t = Task { () throws -> SSHClient in try await self.connectNow() }
        connecting = t
        defer { connecting = nil }
        let c = try await t.value
        client = c
        channels = [:]
        return c
    }

    private func connectNow() async throws -> SSHClient {
        let validator = PinningHostKeyValidator(pinned: config.pinnedHostKey)
        do {
            let c = try await SSHClient.connect(
                host: config.host,
                port: config.port,
                authenticationMethod: .ed25519(username: config.username, privateKey: key),
                hostKeyValidator: .custom(validator),
                reconnect: .never,
                connectTimeout: .seconds(15)
            )
            if config.pinnedHostKey == nil, let seen = validator.seen { onHostKeyPinned(seen) }
            return c
        } catch {
            if let seen = validator.seen, let pinned = config.pinnedHostKey,
               seen.split(separator: " ").prefix(2) != pinned.split(separator: " ").prefix(2) {
                throw RemoteFSError.hostKeyMismatch
            }
            if "\(error)".localizedCaseInsensitiveContains("auth") { throw RemoteFSError.authenticationFailed }
            throw error
        }
    }
}
