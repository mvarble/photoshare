import Foundation
import GRDB

public struct ScanProgress: Sendable, Equatable {
    public enum Phase: String, Sendable { case listing, reading, pairing, done }
    public var phase: Phase
    public var filesFound: Int
    public var filesToRead: Int
    public var filesRead: Int
}

public struct ScanSummary: Sendable, Equatable {
    public var filesSeen = 0
    public var filesRead = 0
    public var filesRemoved = 0
    public var photos = 0
    public var failures: [String] = []
}

/// Walks the configured roots, diffs against the index by (size, mtime), reads
/// headers only for new/changed files, and rebuilds RAW+JPEG pairing.
public struct LibraryScanner: Sendable {
    public let fs: any RemoteFS
    public let db: AppDatabase
    public let roots: [String]
    /// Parallel header reads (spike 0b: ~12.5 ms/file at 8; the lane also limits).
    public var concurrency = 16

    public init(fs: any RemoteFS, db: AppDatabase, roots: [String]) {
        self.fs = fs
        self.db = db
        self.roots = roots
    }

    struct Listed: Sendable { var root: String; var rel: String; var entry: RemoteEntry; var kind: FileKind }

    public func scan(progress: @escaping @Sendable (ScanProgress) -> Void = { _ in }) async throws -> ScanSummary {
        var summary = ScanSummary()

        // 1. List every directory (dot-entries skipped), level by level in parallel.
        var listed: [Listed] = []
        for root in roots {
            var frontier = [""]
            while !frontier.isEmpty {
                let levels = try await withThrowingTaskGroup(of: (String, [RemoteEntry]).self) { g in
                    for rel in frontier { g.addTask { (rel, try await fs.list(remoteJoin(root, rel))) } }
                    return try await g.reduce(into: []) { $0.append($1) }
                }
                frontier = []
                for (rel, entries) in levels {
                    // Skip dot-entries, and empty files (seen: a 0-byte CR3 on the server).
                    for e in entries where !e.name.hasPrefix(".") {
                        let childRel = rel.isEmpty ? e.name : rel + "/" + e.name
                        if e.isDirectory { frontier.append(childRel) }
                        else if e.size > 0, let kind = FileKind(filename: e.name) { listed.append(Listed(root: root, rel: childRel, entry: e, kind: kind)) }
                    }
                }
                progress(ScanProgress(phase: .listing, filesFound: listed.count, filesToRead: 0, filesRead: 0))
            }
        }
        summary.filesSeen = listed.count

        // 2. Diff against the index.
        let existing = try await db.writer.read { db in try RemoteFile.fetchAll(db) }
        var byKey: [String: RemoteFile] = [:]
        for f in existing { byKey["\(f.rootPath)\u{0}\(f.relPath)"] = f }
        var seen = Set<String>()
        var toRead: [Listed] = []
        for l in listed {
            let key = "\(l.root)\u{0}\(l.rel)"
            seen.insert(key)
            if let f = byKey[key], f.size == Int64(l.entry.size), f.mtime == l.entry.mtime, f.fp != nil { continue }
            toRead.append(l)
        }
        let removed = existing.filter { !seen.contains("\($0.rootPath)\u{0}\($0.relPath)") }.compactMap(\.id)
        summary.filesRemoved = removed.count
        if !removed.isEmpty {
            try await db.writer.write { db in _ = try RemoteFile.deleteAll(db, keys: removed) }
        }

        // 3. Read headers for new/changed files; save in batches.
        let total = toRead.count
        var done = 0
        progress(ScanProgress(phase: .reading, filesFound: listed.count, filesToRead: total, filesRead: 0))
        var batch: [RemoteFile] = []
        var failures: [String] = []
        try await withThrowingTaskGroup(of: Result<RemoteFile, Error>.self) { g in
            var it = toRead.makeIterator()
            var inflight = 0
            func launch() {
                guard let l = it.next() else { return }
                inflight += 1
                let prior = byKey["\(l.root)\u{0}\(l.rel)"]
                g.addTask {
                    do { return .success(try await probe(l, existing: prior)) } catch { return .failure(error) }
                }
            }
            for _ in 0..<concurrency { launch() }
            while inflight > 0, let r = try await g.next() {
                inflight -= 1
                switch r {
                case .success(let f): batch.append(f)
                case .failure(let e): failures.append("\(e)")
                }
                done += 1
                if batch.count >= 250 {
                    try await save(batch); batch = []
                    // Pair periodically so a long first scan fills the gallery as it goes.
                    // Photos only appear once their dates are known, so nothing jumps around.
                    if done % 2000 < 250 { _ = try await pair() }
                    progress(ScanProgress(phase: .reading, filesFound: listed.count, filesToRead: total, filesRead: done))
                }
                launch()
            }
        }
        try await save(batch)
        summary.filesRead = done - failures.count
        summary.failures = failures

        // 4. Pair into photos.
        progress(ScanProgress(phase: .pairing, filesFound: listed.count, filesToRead: total, filesRead: done))
        summary.photos = try await pair()
        progress(ScanProgress(phase: .done, filesFound: listed.count, filesToRead: total, filesRead: done))
        return summary
    }

    func probe(_ l: Listed, existing: RemoteFile?) async throws -> RemoteFile {
        let size = l.entry.size
        let path = remoteJoin(l.root, l.rel)
        let tail = Fingerprint.tailRange(size: size)
        let headLen = tail == nil ? size : UInt64(MetadataReader.headLength(for: l.kind))
        var ranges = [0..<headLen]
        if let tail { ranges.append(tail) }
        let parts = try await fs.readRanges(path, ranges)
        let meta = MetadataReader.read(head: parts[0], kind: l.kind)
        let dir = (l.rel as NSString).deletingLastPathComponent
        return RemoteFile(
            id: existing?.id, rootPath: l.root, relPath: l.rel, dir: dir, name: l.entry.name,
            stemKey: stemKey(l.entry.name), kind: l.kind, size: Int64(size), mtime: l.entry.mtime,
            fp: Fingerprint.compute(size: size, head: parts[0], tail: parts.count > 1 ? parts[1] : nil),
            captureDate: meta.captureDate, orientation: meta.orientation,
            previewOffset: meta.previewRange.map { Int64($0.lowerBound) },
            previewLength: meta.previewRange.map { Int64($0.upperBound - $0.lowerBound) },
            photoId: existing?.photoId
        )
    }

    func save(_ files: [RemoteFile]) async throws {
        guard !files.isEmpty else { return }
        try await db.writer.write { db in
            for var f in files { try f.save(db) }
        }
    }

    /// Rebuilds photo rows from all files, keeping existing photo ids stable.
    func pair() async throws -> Int {
        try await db.writer.write { db in
            let files = try RemoteFile.fetchAll(db)
            let groups = Pairing.group(files)
            var photos: [String: Photo] = [:]
            for p in try Photo.fetchAll(db) { photos["\(p.rootPath)\u{0}\(p.dir)\u{0}\(p.stemKey)"] = p }
            var keep = Set<Int64>()
            var fileToPhoto: [Int64: Int64] = [:]
            for g in groups where g.primary != nil || g.raw != nil {
                let key = "\(g.rootPath)\u{0}\(g.dir)\u{0}\(g.stemKey)"
                var p = photos[key] ?? Photo(id: nil, rootPath: g.rootPath, dir: g.dir, stemKey: g.stemKey,
                                              primaryFileId: nil, rawFileId: nil, sortDate: g.sortDate, sortKey: g.sortKey)
                let updated = Photo(id: p.id, rootPath: g.rootPath, dir: g.dir, stemKey: g.stemKey,
                                    primaryFileId: g.primary?.id, rawFileId: g.raw?.id,
                                    sortDate: g.sortDate, sortKey: g.sortKey)
                if p.id == nil || p != updated { p = updated; try p.save(db) }
                keep.insert(p.id!)
                if let id = g.primary?.id { fileToPhoto[id] = p.id }
                if let id = g.raw?.id { fileToPhoto[id] = p.id }
            }
            let stale = photos.values.compactMap(\.id).filter { !keep.contains($0) }
            if !stale.isEmpty { _ = try Photo.deleteAll(db, keys: stale) }
            for f in files where f.photoId != fileToPhoto[f.id!] {
                var f = f
                f.photoId = fileToPhoto[f.id!]
                try f.update(db)
            }
            return keep.count
        }
    }
}
