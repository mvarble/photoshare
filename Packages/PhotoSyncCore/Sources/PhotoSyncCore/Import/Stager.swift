import Crypto
import Foundation

/// Downloads a photo's files into Staging/<uuid>/ under their original names,
/// verifying size and computing SHA-256 while streaming.
public struct Stager: Sendable {
    public let fs: any RemoteFS
    public let stagingDir: URL

    public init(fs: any RemoteFS, stagingDir: URL) {
        self.fs = fs
        self.stagingDir = stagingDir
    }

    public struct Staged: Sendable {
        public var resource: StagedResource
        public var sha256: Data
    }

    public func stage(_ file: RemoteFile, uuid: String) async throws -> Staged {
        let dir = stagingDir.appendingPathComponent(uuid, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent(file.name)
        let hasher = LockedHasher()
        try await fs.download(file.remotePath, size: UInt64(file.size), to: dest, onChunk: { hasher.update($0) }, progress: { _ in })
        let got = (try FileManager.default.attributesOfItem(atPath: dest.path)[.size] as? NSNumber)?.int64Value ?? -1
        guard got == file.size else {
            throw RemoteFSError.shortFile(path: file.remotePath, expected: UInt64(file.size), got: UInt64(max(0, got)))
        }
        return Staged(resource: StagedResource(url: dest, filename: file.name, uti: file.kind.uti), sha256: hasher.finalize())
    }

    public func cleanup(uuid: String) {
        try? FileManager.default.removeItem(at: stagingDir.appendingPathComponent(uuid, isDirectory: true))
    }

    /// Removes staging leftovers older than a day (e.g. after a crash).
    public func purgeStale(olderThan age: TimeInterval = 24 * 3600) {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: stagingDir, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        for u in items {
            let d = (try? u.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            if Date().timeIntervalSince(d) > age { try? fm.removeItem(at: u) }
        }
    }
}

final class LockedHasher: @unchecked Sendable {
    private let lock = NSLock()
    private var h = SHA256()
    func update(_ d: Data) { lock.withLock { h.update(data: d) } }
    func finalize() -> Data { lock.withLock { Data(h.finalize()) } }
}
