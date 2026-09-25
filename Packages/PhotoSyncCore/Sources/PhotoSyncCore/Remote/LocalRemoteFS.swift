import Foundation

/// `RemoteFS` backed by a local directory. Used by tests and offline development.
public struct LocalRemoteFS: RemoteFS {
    public let base: URL

    public init(base: URL) { self.base = base }

    private func url(_ path: String) -> URL {
        path.hasPrefix("/") ? URL(fileURLWithPath: path) : base.appendingPathComponent(path)
    }

    public func list(_ path: String) async throws -> [RemoteEntry] {
        let dir = url(path)
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
        return try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys)
            .map { u in
                let v = try u.resourceValues(forKeys: Set(keys))
                return RemoteEntry(
                    name: u.lastPathComponent,
                    isDirectory: v.isDirectory ?? false,
                    size: UInt64(v.fileSize ?? 0),
                    mtime: Int64(v.contentModificationDate?.timeIntervalSince1970 ?? 0)
                )
            }
    }

    public func read(_ path: String, offset: UInt64, length: Int) async throws -> Data {
        try readRangesSync(path, [offset..<(offset + UInt64(length))])[0]
    }

    func readRangesSync(_ path: String, _ ranges: [Range<UInt64>]) throws -> [Data] {
        let h = try FileHandle(forReadingFrom: url(path))
        defer { try? h.close() }
        return try ranges.map { r in
            try h.seek(toOffset: r.lowerBound)
            return try h.read(upToCount: Int(r.upperBound - r.lowerBound)) ?? Data()
        }
    }

    public func readRanges(_ path: String, _ ranges: [Range<UInt64>]) async throws -> [Data] {
        try readRangesSync(path, ranges)
    }

    public func download(
        _ path: String, size: UInt64, to destination: URL,
        onChunk: @Sendable (Data) -> Void, progress: @Sendable (UInt64) -> Void
    ) async throws {
        let data = try Data(contentsOf: url(path))
        onChunk(data)
        try data.write(to: destination)
        progress(UInt64(data.count))
    }
}
