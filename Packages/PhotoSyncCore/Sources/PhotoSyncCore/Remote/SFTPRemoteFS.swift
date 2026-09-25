import Citadel
import Foundation
import NIOCore

/// `RemoteFS` over one lane of an `SSHSession`.
public struct SFTPRemoteFS: RemoteFS {
    public let session: SSHSession
    public let lane: Lane
    public let channelCount: Int
    private let limiter: AsyncLimiter
    private let nextChannel = RoundRobin()

    /// Largest single SFTP read; the server caps replies at 261,120 bytes.
    static let chunk = 256 * 1024

    /// `channels` > 1 spreads operations over several SFTP channels (parallel
    /// server-side processes); `maxConcurrent` caps total in-flight operations.
    public init(session: SSHSession, lane: Lane, channels: Int = 1, maxConcurrent: Int) {
        self.session = session
        self.lane = lane
        self.channelCount = max(1, channels)
        self.limiter = AsyncLimiter(limit: maxConcurrent)
    }

    private func withChannel<T>(_ body: (SFTPClient) async throws -> T) async throws -> T {
        try await session.withSFTP(lane, index: nextChannel.next(channelCount), body)
    }

    public func list(_ path: String) async throws -> [RemoteEntry] {
        try await limiter.run {
            try await withChannel { sftp in
                try await sftp.listDirectory(atPath: path)
                    .flatMap(\.components)
                    .filter { $0.filename != "." && $0.filename != ".." }
                    .map { c in
                        let mode = c.attributes.permissions ?? 0
                        return RemoteEntry(
                            name: c.filename,
                            isDirectory: mode & 0o170000 == 0o040000,
                            size: c.attributes.size ?? 0,
                            mtime: Int64(c.attributes.accessModificationTime?.modificationTime.timeIntervalSince1970 ?? 0)
                        )
                    }
            }
        }
    }

    public func read(_ path: String, offset: UInt64, length: Int) async throws -> Data {
        try await readRanges(path, [offset..<(offset + UInt64(length))])[0]
    }

    public func readRanges(_ path: String, _ ranges: [Range<UInt64>]) async throws -> [Data] {
        try await limiter.run {
            try await withChannel { sftp in
                let file = try await sftp.openFile(filePath: path, flags: .read)
                do {
                    var out: [Data] = []
                    for r in ranges { out.append(try await Self.readFully(file, r)) }
                    try await file.close()
                    return out
                } catch {
                    try? await file.close()
                    throw error
                }
            }
        }
    }

    /// Loops over short reads until the range is filled or EOF.
    static func readFully(_ file: SFTPFile, _ range: Range<UInt64>) async throws -> Data {
        var data = Data()
        var offset = range.lowerBound
        while offset < range.upperBound {
            let want = UInt32(min(UInt64(chunk), range.upperBound - offset))
            var buf = try await file.read(from: offset, length: want)
            guard buf.readableBytes > 0, let bytes = buf.readBytes(length: buf.readableBytes) else { break }
            data.append(contentsOf: bytes)
            offset += UInt64(bytes.count)
        }
        return data
    }

    public func download(
        _ path: String, size: UInt64, to destination: URL,
        onChunk: @Sendable (Data) -> Void, progress: @Sendable (UInt64) -> Void
    ) async throws {
        try await limiter.run {
            try await withChannel { sftp in
                FileManager.default.createFile(atPath: destination.path, contents: nil)
                let out = try FileHandle(forWritingTo: destination)
                defer { try? out.close() }
                let file = try await sftp.openFile(filePath: path, flags: .read)
                do {
                    // Fetch `depth` chunks concurrently, then write them in order.
                    let depth = 8, step = UInt64(Self.chunk)
                    var written: UInt64 = 0
                    while written < size {
                        let starts = stride(from: written, to: min(size, written + step * UInt64(depth)), by: Int(step)).map { $0 }
                        let parts = try await withThrowingTaskGroup(of: (Int, Data).self) { g in
                            for (i, s) in starts.enumerated() {
                                g.addTask { (i, try await Self.readFully(file, s..<min(size, s + step))) }
                            }
                            var parts = [Data](repeating: Data(), count: starts.count)
                            for try await (i, d) in g { parts[i] = d }
                            return parts
                        }
                        for p in parts {
                            if p.isEmpty { throw RemoteFSError.shortFile(path: path, expected: size, got: written) }
                            try out.write(contentsOf: p)
                            onChunk(p)
                            written += UInt64(p.count)
                            progress(written)
                        }
                    }
                    try await file.close()
                } catch {
                    try? await file.close()
                    throw error
                }
            }
        }
    }
}

final class RoundRobin: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func next(_ count: Int) -> Int { lock.withLock { n += 1; return n % count } }
}
