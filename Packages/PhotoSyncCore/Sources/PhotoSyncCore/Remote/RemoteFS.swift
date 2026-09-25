import Foundation

/// One entry from a remote directory listing.
public struct RemoteEntry: Sendable, Hashable {
    public var name: String
    public var isDirectory: Bool
    public var size: UInt64
    /// Seconds since 1970 (SFTP v3 mtime resolution).
    public var mtime: Int64

    public init(name: String, isDirectory: Bool, size: UInt64, mtime: Int64) {
        self.name = name
        self.isDirectory = isDirectory
        self.size = size
        self.mtime = mtime
    }
}

/// Read-only view of a remote file tree. Paths are server paths (absolute or
/// relative to the SFTP login directory); implementations never write.
public protocol RemoteFS: Sendable {
    func list(_ path: String) async throws -> [RemoteEntry]

    /// Reads up to `length` bytes starting at `offset`, looping over short reads
    /// (the server caps one SFTP read at ~255 KB). Returns fewer bytes only at EOF.
    func read(_ path: String, offset: UInt64, length: Int) async throws -> Data

    /// Reads several ranges of one file with a single open/close.
    func readRanges(_ path: String, _ ranges: [Range<UInt64>]) async throws -> [Data]

    /// Streams the whole file to `destination`, calling `onChunk` with each
    /// chunk in order (used for hashing) and `progress` with bytes written.
    func download(
        _ path: String,
        size: UInt64,
        to destination: URL,
        onChunk: @Sendable (Data) -> Void,
        progress: @Sendable (UInt64) -> Void
    ) async throws
}

public enum RemoteFSError: Error, Equatable, LocalizedError {
    case notConnected
    case shortFile(path: String, expected: UInt64, got: UInt64)
    case hostKeyMismatch
    case authenticationFailed
    case missingKey

    public var errorDescription: String? {
        switch self {
        case .notConnected: "Can't reach the photo server right now."
        case .shortFile(let path, let e, let g): "Download of \(path) was incomplete (\(g) of \(e) bytes)."
        case .hostKeyMismatch: "The photo server's identity has changed. For safety, PhotoSync won't connect until this is checked."
        case .authenticationFailed: "The photo server didn't accept this Mac's key."
        case .missingKey: "No connection key is set up yet."
        }
    }
}

/// Joins a root and a relative path without doubling slashes.
public func remoteJoin(_ root: String, _ rel: String) -> String {
    if rel.isEmpty { return root }
    if root.isEmpty || root == "." { return rel }
    return root.hasSuffix("/") ? root + rel : root + "/" + rel
}
