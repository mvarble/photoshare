import GRDB
import XCTest
@testable import PhotoSyncCore

/// In-memory stand-in for the Photos library.
actor FakePhotos: PhotosImporting {
    struct Asset: Equatable { var id: String; var primary: String; var alternate: String? }
    var assets: [Asset] = []
    var rejectAlternates = false
    var failNext = 0
    var authorized = true

    func setRejectAlternates(_ v: Bool) { rejectAlternates = v }
    func setFailNext(_ n: Int) { failNext = n }
    func setAuthorized(_ v: Bool) { authorized = v }
    func remove(_ id: String) { assets.removeAll { $0.id == id } }

    func authorize() async -> Bool { authorized }

    func createAsset(primary: StagedResource, alternate: StagedResource?) async throws -> String {
        XCTAssertTrue(FileManager.default.fileExists(atPath: primary.url.path))
        if failNext > 0 { failNext -= 1; throw NSError(domain: "fake", code: 1) }
        if alternate != nil, rejectAlternates { throw NSError(domain: "PHPhotosErrorDomain", code: 3302) }
        let id = "asset-\(assets.count + 1)"
        assets.append(Asset(id: id, primary: primary.filename, alternate: alternate?.filename))
        return id
    }

    func assetExists(_ id: String) async -> Bool { assets.contains { $0.id == id } }
    func findAsset(filename: String, near: Date?) async -> String? {
        assets.first { $0.primary == filename || $0.alternate == filename }?.id
    }
    func deleteAssets(_ ids: [String]) async throws { assets.removeAll { ids.contains($0.id) } }
}

final class ImportQueueTests: XCTestCase {
    var dir: URL!
    var staging: URL!
    var db: AppDatabase!
    var fake: FakePhotos!

    override func setUp() async throws {
        dir = try Fixtures.tempDir()
        staging = try Fixtures.tempDir()
        db = try AppDatabase.inMemory()
        fake = FakePhotos()
        try Fixtures.jpeg(seed: 1).write(to: dir.appendingPathComponent("IMG_1.JPG"))
        try Data(repeating: 7, count: 300_000).write(to: dir.appendingPathComponent("IMG_1.CR3"))
        try Fixtures.jpeg(seed: 2).write(to: dir.appendingPathComponent("IMG_2.JPG"))
        try Data(repeating: 9, count: 300_000).write(to: dir.appendingPathComponent("IMG_3.CR3"))
        _ = try await LibraryScanner(fs: LocalRemoteFS(base: dir), db: db, roots: ["."]).scan()
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.removeItem(at: staging)
    }

    func queue(limit: Int? = nil) -> ImportQueue {
        let q = ImportQueue(db: db, stager: Stager(fs: LocalRemoteFS(base: dir), stagingDir: staging), photos: fake, sessionLimit: limit)
        return q
    }

    func photoId(_ stem: String) async throws -> Int64 {
        try await db.writer.read { try Photo.filter(Column("stemKey") == stem).fetchOne($0)!.id! }
    }

    func status(_ stem: String) async throws -> PhotoStatus {
        let id = try await photoId(stem)
        let (entries, records) = try await db.writer.read { (try PhotoEntry.fetchAll($0), try ImportRecord.fetchAll($0)) }
        return StatusCalculator.statuses(entries: entries, records: records)[id]!
    }

    func waitIdle(_ q: ImportQueue) async throws {
        for _ in 0..<200 {
            if await q.queuedCount == 0 { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("queue never drained")
    }

    func testPairBecomesOneAssetWithAlternate() async throws {
        let q = queue()
        let r = try await q.enqueue(photoId: try await photoId("img_1"))
        XCTAssertEqual(r, .queued)
        try await waitIdle(q)
        let assets = await fake.assets
        XCTAssertEqual(assets, [.init(id: "asset-1", primary: "IMG_1.JPG", alternate: "IMG_1.CR3")])
        let s = try await status("img_1")
        XCTAssertEqual(s, .imported(rawAttached: true))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: staging.path), []) // staging cleaned
    }

    func testJPEGOnlyAndRawOnly() async throws {
        let q = queue()
        _ = try await q.enqueue(photoId: try await photoId("img_2"))
        _ = try await q.enqueue(photoId: try await photoId("img_3"))
        try await waitIdle(q)
        let assets = await fake.assets
        XCTAssertEqual(assets.map(\.primary), ["IMG_2.JPG", "IMG_3.CR3"])
        XCTAssertEqual(assets.map(\.alternate), [nil, nil])
    }

    func testDoubleTapAndAlreadyImportedAreNoOps() async throws {
        let q = queue()
        let id = try await photoId("img_1")
        let first = try await q.enqueue(photoId: id)
        let second = try await q.enqueue(photoId: id)
        XCTAssertEqual(first, .queued)
        XCTAssertEqual(second, .alreadyQueued)
        try await waitIdle(q)
        let again = try await q.enqueue(photoId: id)
        XCTAssertEqual(again, .alreadyImported)
        let count = await fake.assets.count
        XCTAssertEqual(count, 1)
    }

    func testRejectedRawFallsBackToJPEGOnly() async throws {
        await fake.setRejectAlternates(true)
        let q = queue()
        _ = try await q.enqueue(photoId: try await photoId("img_1"))
        try await waitIdle(q)
        let assets = await fake.assets
        XCTAssertEqual(assets, [.init(id: "asset-1", primary: "IMG_1.JPG", alternate: nil)])
        let s = try await status("img_1")
        XCTAssertEqual(s, .imported(rawAttached: false))
    }

    func testTransientFailureRetries() async throws {
        await fake.setFailNext(4) // pair + fallback fail on attempt 1 and 2, succeed on attempt 3
        let q = queue()
        await q.setRetryDelay { _ in .milliseconds(10) }
        _ = try await q.enqueue(photoId: try await photoId("img_2"))
        try await waitIdle(q)
        let s = try await status("img_2")
        XCTAssertEqual(s, .failed(NSError(domain: "fake", code: 1).localizedDescription))
        let count = await fake.assets.count
        XCTAssertEqual(count, 0)
    }

    func testRetryEventuallySucceeds() async throws {
        await fake.setFailNext(1)
        let q = queue()
        await q.setRetryDelay { _ in .milliseconds(10) }
        _ = try await q.enqueue(photoId: try await photoId("img_2"))
        try await waitIdle(q)
        let s = try await status("img_2")
        XCTAssertEqual(s, .imported(rawAttached: true))
    }

    func testReimportGuardUsesPresence() async throws {
        let q = queue()
        let id = try await photoId("img_2")
        _ = try await q.enqueue(photoId: id)
        try await waitIdle(q)
        let present = try await q.locate(photoId: id)
        XCTAssertEqual(present, .present(localIdentifier: "asset-1"))
        await fake.remove("asset-1") // she deleted it in Photos
        let absent = try await q.locate(photoId: id)
        XCTAssertEqual(absent, .absent)
        let r = try await q.enqueue(photoId: id, reimport: true)
        XCTAssertEqual(r, .queued)
        try await waitIdle(q)
        let count = await fake.assets.count
        XCTAssertEqual(count, 1)
    }

    func testCrashDuringImportIsRecovered() async throws {
        // Simulate: asset created in Photos, app died before recording "done".
        let id = try await photoId("img_2")
        _ = try await fake.createAsset(primary: StagedResource(url: dir.appendingPathComponent("IMG_2.JPG"), filename: "IMG_2.JPG", uti: "public.jpeg"), alternate: nil)
        try await db.writer.write { db in
            var r = ImportRecord(id: nil, uuid: "u1", photoId: id, state: .importing, primaryFp: nil, rawFp: nil,
                                 primaryName: "IMG_2.JPG", rawName: nil, primarySha256: nil, rawSha256: nil,
                                 rawAttached: false, localIdentifier: nil, isReimport: false, error: nil,
                                 attempts: 0, createdAt: Date(), completedAt: nil)
            r.primaryFp = try PhotoEntry.fetch(db, id: id)?.primary?.fp
            try r.insert(db)
        }
        try await queue().recover()
        let s = try await status("img_2")
        XCTAssertEqual(s, .imported(rawAttached: true))
        let count = await fake.assets.count
        XCTAssertEqual(count, 1) // no duplicate
    }

    func testSessionLimit() async throws {
        let q = queue(limit: 1)
        let a = try await q.enqueue(photoId: try await photoId("img_2"))
        let b = try await q.enqueue(photoId: try await photoId("img_3"))
        XCTAssertEqual(a, .queued)
        XCTAssertEqual(b, .limitReached(1))
    }

    func testAccessDeniedFailsWithoutRetry() async throws {
        await fake.setAuthorized(false)
        let q = queue()
        _ = try await q.enqueue(photoId: try await photoId("img_2"))
        try await waitIdle(q)
        let s = try await status("img_2")
        XCTAssertEqual(s, .failed(ImportError.photosAccessDenied.errorDescription!))
    }

    func testChangedSinceImportBadge() async throws {
        let q = queue()
        _ = try await q.enqueue(photoId: try await photoId("img_2"))
        try await waitIdle(q)
        let url = dir.appendingPathComponent("IMG_2.JPG")
        try Fixtures.jpeg(seed: 77).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: 60)], ofItemAtPath: url.path)
        _ = try await LibraryScanner(fs: LocalRemoteFS(base: dir), db: db, roots: ["."]).scan()
        let s = try await status("img_2")
        XCTAssertEqual(s, .changedSinceImport)
    }
}
