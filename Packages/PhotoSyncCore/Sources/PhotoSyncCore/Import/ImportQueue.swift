import Foundation
import GRDB

/// Serial import pipeline (plan §4). Runs beside browsing: enqueueing returns
/// immediately and progress shows up through the database.
public actor ImportQueue {
    public enum EnqueueResult: Sendable, Equatable {
        case queued, alreadyQueued, alreadyImported, limitReached(Int)
    }

    public enum Presence: Sendable, Equatable {
        case present(localIdentifier: String), absent
    }

    let db: AppDatabase
    let stager: Stager
    let photos: any PhotosImporting
    let ledger: TestLedger?
    /// Debug-build safety cap on imports per session (her library, plan).
    let sessionLimit: Int?
    let maxAttempts = 3
    var retryDelay: (Int) -> Duration = { attempt in .seconds(2 << attempt) }

    private var pending: [Int64] = [] // import_record ids
    private var activePhotos = Set<Int64>()
    private var worker: Task<Void, Never>?
    private var startedThisSession = 0

    public init(db: AppDatabase, stager: Stager, photos: any PhotosImporting, ledger: TestLedger? = nil, sessionLimit: Int? = nil) {
        self.db = db
        self.stager = stager
        self.photos = photos
        self.ledger = ledger
        self.sessionLimit = sessionLimit
    }

    public func setRetryDelay(_ f: @escaping (Int) -> Duration) { retryDelay = f }

    // MARK: Enqueue

    /// `reimport` skips the "already imported" guard; callers must first check
    /// `locate` and confirm with her if the photo is still in Photos (plan §5).
    public func enqueue(photoId: Int64, reimport: Bool = false) async throws -> EnqueueResult {
        if activePhotos.contains(photoId) { return .alreadyQueued }
        guard let entry = try await db.writer.read({ try PhotoEntry.fetch($0, id: photoId) }) else { throw ImportError.nothingToImport }
        if !reimport {
            let records = try await db.writer.read { try ImportRecord.fetchAll($0) }
            if StatusCalculator.statuses(entries: [entry], records: records)[photoId]?.isImported == true { return .alreadyImported }
        }
        if let sessionLimit, startedThisSession >= sessionLimit { return .limitReached(sessionLimit) }
        startedThisSession += 1

        var record = ImportRecord(
            id: nil, uuid: UUID().uuidString, photoId: photoId, state: .queued,
            primaryFp: entry.primary?.fp, rawFp: entry.raw?.fp,
            primaryName: entry.primary?.name, rawName: entry.raw?.name,
            primarySha256: nil, rawSha256: nil, rawAttached: false, localIdentifier: nil,
            isReimport: reimport, error: nil, attempts: 0, createdAt: Date(), completedAt: nil)
        let inserted = record
        record = try await db.writer.write { db in
            var r = inserted
            try r.insert(db)
            return r
        }
        activePhotos.insert(photoId)
        pending.append(record.id!)
        startWorker()
        return .queued
    }

    /// Is this photo still in Photos? Checks the stored identifier, then falls
    /// back to filename + date (library rebuilt, identifiers changed).
    public func locate(photoId: Int64) async throws -> Presence {
        let (records, entry) = try await db.writer.read { db in
            (try ImportRecord.filter(Column("photoId") == photoId && Column("state") == ImportState.done.rawValue)
                .order(Column("id").desc).fetchAll(db),
             try PhotoEntry.fetch(db, id: photoId))
        }
        for r in records {
            if let id = r.localIdentifier, await photos.assetExists(id) { return .present(localIdentifier: id) }
        }
        if let name = entry?.primary?.name ?? entry?.raw?.name,
           let id = await photos.findAsset(filename: name, near: entry?.sortDate) {
            return .present(localIdentifier: id)
        }
        return .absent
    }

    public var queuedCount: Int { activePhotos.count }

    // MARK: Startup recovery

    /// Call once at launch: resolves imports interrupted by a crash or quit.
    public func recover() async throws {
        stager.purgeStale()
        let open = try await db.writer.read {
            try ImportRecord.filter([ImportState.queued, .downloading, .importing, .inDoubt].map(\.rawValue).contains(Column("state"))).fetchAll($0)
        }
        for var r in open {
            if r.state == .importing || r.state == .inDoubt {
                // performChanges may have committed before we recorded it.
                r.state = .inDoubt
                try await save(r)
                let pid = r.photoId
                let photo = try await db.writer.read { db in try pid.flatMap { try PhotoEntry.fetch(db, id: $0) } }
                let name = r.primaryName ?? r.rawName
                if let name, let id = await photos.findAsset(filename: name, near: photo?.sortDate) {
                    r.state = .done
                    r.localIdentifier = id
                    r.rawAttached = r.rawName != nil && r.primaryName != nil
                    r.completedAt = Date()
                    ledger?.append(id)
                } else {
                    r.state = .failed
                    r.error = "Import was interrupted. Try again."
                }
                try await save(r)
                stager.cleanup(uuid: r.uuid)
            } else if let p = r.photoId {
                // Never reached Photos: just run it again.
                r.state = .queued
                try await save(r)
                activePhotos.insert(p)
                pending.append(r.id!)
            }
        }
        startWorker()
    }

    // MARK: Worker

    private func startWorker() {
        guard worker == nil, !pending.isEmpty else { return }
        worker = Task { await self.drain() }
    }

    private func drain() async {
        while !pending.isEmpty {
            let id = pending.removeFirst()
            await process(recordId: id)
        }
        worker = nil
    }

    private func process(recordId: Int64) async {
        guard var r = try? await db.writer.read({ try ImportRecord.fetchOne($0, key: recordId) }),
              let photoId = r.photoId else { return }
        do {
            try await runImport(&r)
            activePhotos.remove(photoId)
        } catch {
            r.attempts += 1
            r.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            let permanent = (error as? ImportError).map { [.photosAccessDenied, .nothingToImport].contains($0) } ?? false
            if !permanent, r.attempts < maxAttempts {
                // Retry later without holding up other imports; the photo stays "queued".
                r.state = .queued
                try? await save(r)
                let delay = retryDelay(r.attempts)
                Task {
                    try? await Task.sleep(for: delay)
                    await self.requeue(recordId)
                }
            } else {
                r.state = .failed
                try? await save(r)
                activePhotos.remove(photoId)
            }
        }
        stager.cleanup(uuid: r.uuid)
    }

    private func requeue(_ recordId: Int64) {
        pending.append(recordId)
        startWorker()
    }

    private func runImport(_ r: inout ImportRecord) async throws {
        guard await photos.authorize() else { throw ImportError.photosAccessDenied }
        guard let pid = r.photoId, let entry = try await db.writer.read({ try PhotoEntry.fetch($0, id: pid) }),
              entry.primary != nil || entry.raw != nil else { throw ImportError.nothingToImport }

        r.state = .downloading
        r.primaryFp = entry.primary?.fp
        r.rawFp = entry.raw?.fp
        r.primaryName = entry.primary?.name
        r.rawName = entry.raw?.name
        try await save(r)

        let primaryFile = entry.primary ?? entry.raw!
        let altFile = entry.primary != nil ? entry.raw : nil
        let primary = try await stager.stage(primaryFile, uuid: r.uuid)
        try verifyUnchanged(primary.resource.url, against: primaryFile)
        var alternate: Stager.Staged?
        if let altFile {
            alternate = try await stager.stage(altFile, uuid: r.uuid)
            try verifyUnchanged(alternate!.resource.url, against: altFile)
        }
        if entry.primary != nil { r.primarySha256 = primary.sha256 } else { r.rawSha256 = primary.sha256 }
        r.rawSha256 = alternate?.sha256 ?? r.rawSha256

        // Persist "importing" BEFORE touching Photos so a crash is recoverable.
        r.state = .importing
        try await save(r)

        let id: String
        if let alternate {
            do {
                id = try await photos.createAsset(primary: primary.resource, alternate: alternate.resource)
                r.rawAttached = true
            } catch {
                // e.g. a RAW this macOS can't decode. Each attempt is atomic, so no duplicate.
                id = try await photos.createAsset(primary: primary.resource, alternate: nil)
                r.rawAttached = false
                r.error = "RAW not attached: \(error.localizedDescription)"
            }
        } else {
            id = try await photos.createAsset(primary: primary.resource, alternate: nil)
            r.rawAttached = entry.primary == nil // RAW-only import
        }
        ledger?.append(id)
        r.state = .done
        r.localIdentifier = id
        r.completedAt = Date()
        if r.rawAttached || altFile == nil { r.error = nil }
        try await save(r)
    }

    /// Re-fingerprints the staged copy: the server file must not have changed since indexing.
    private func verifyUnchanged(_ url: URL, against f: RemoteFile) throws {
        guard let expected = f.fp else { return }
        let h = try FileHandle(forReadingFrom: url)
        defer { try? h.close() }
        let size = UInt64(f.size)
        let tailRange = Fingerprint.tailRange(size: size)
        let head = try h.read(upToCount: tailRange == nil ? Int(size) : Fingerprint.headBytes) ?? Data()
        var tail: Data?
        if let tailRange {
            try h.seek(toOffset: tailRange.lowerBound)
            tail = try h.read(upToCount: Int(tailRange.upperBound - tailRange.lowerBound))
        }
        guard Fingerprint.compute(size: size, head: head, tail: tail) == expected else { throw ImportError.fileChangedDuringImport }
    }

    private func save(_ r: ImportRecord) async throws {
        try await db.writer.write { try r.update($0) }
    }
}
