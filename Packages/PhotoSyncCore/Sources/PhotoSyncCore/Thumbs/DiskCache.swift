import Foundation

/// Size-capped, content-addressed file cache (LRU by modification date,
/// which is bumped on every hit). Her MacBook is disk-limited: keep caps modest.
public actor DiskCache {
    public let dir: URL
    public let limitBytes: Int64
    private var writesSinceTrim = 0

    public init(dir: URL, limitBytes: Int64) {
        self.dir = dir
        self.limitBytes = limitBytes
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    nonisolated public func url(for key: String) -> URL {
        dir.appendingPathComponent(String(key.prefix(2)), isDirectory: true).appendingPathComponent(key + ".jpg")
    }

    public func data(for key: String) -> Data? {
        let u = url(for: key)
        guard let d = try? Data(contentsOf: u) else { return nil }
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: u.path)
        return d
    }

    public func contains(_ key: String) -> Bool { FileManager.default.fileExists(atPath: url(for: key).path) }

    public func store(_ data: Data, for key: String) {
        let u = url(for: key)
        try? FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: u, options: .atomic)
        writesSinceTrim += 1
        if writesSinceTrim >= 50 { trim(); writesSinceTrim = 0 }
    }

    /// Deletes least-recently-used files until the cache is under 90% of its cap.
    public func trim() {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        guard let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: keys) else { return }
        var files: [(URL, Int64, Date)] = []
        var total: Int64 = 0
        for case let u as URL in e {
            guard let v = try? u.resourceValues(forKeys: Set(keys)), let size = v.fileSize else { continue }
            files.append((u, Int64(size), v.contentModificationDate ?? .distantPast))
            total += Int64(size)
        }
        guard total > limitBytes else { return }
        for (u, size, _) in files.sorted(by: { $0.2 < $1.2 }) {
            try? FileManager.default.removeItem(at: u)
            total -= size
            if total <= limitBytes * 9 / 10 { break }
        }
    }

    public func totalBytes() -> Int64 {
        guard let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let u as URL in e { total += Int64((try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
        return total
    }
}
