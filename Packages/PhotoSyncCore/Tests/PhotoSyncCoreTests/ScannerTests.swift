import GRDB
import XCTest
@testable import PhotoSyncCore

final class ScannerTests: XCTestCase {
    var dir: URL!
    var db: AppDatabase!

    override func setUpWithError() throws {
        dir = try Fixtures.tempDir()
        db = try AppDatabase.inMemory()
        let fm = FileManager.default
        try fm.createDirectory(at: dir.appendingPathComponent("card1/.hidden"), withIntermediateDirectories: true)
        try Fixtures.jpeg(date: "2026:01:01 10:00:00", seed: 1).write(to: dir.appendingPathComponent("card1/IMG_1.JPG"))
        try Data(repeating: 7, count: 300_000).write(to: dir.appendingPathComponent("card1/IMG_1.CR3"))
        try Fixtures.jpeg(date: "2026:01:01 09:00:00", seed: 2).write(to: dir.appendingPathComponent("card1/IMG_2.JPG"))
        try Data([1, 2, 3]).write(to: dir.appendingPathComponent("card1/GH01.MP4"))
        try Data().write(to: dir.appendingPathComponent("card1/EMPTY.CR3"))
        try Data([1, 2, 3]).write(to: dir.appendingPathComponent("card1/.hidden/IMG_9.JPG"))
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    func scanner() -> LibraryScanner { LibraryScanner(fs: LocalRemoteFS(base: dir), db: db, roots: ["."]) }

    func photos() async throws -> [Photo] {
        try await db.writer.read { try Photo.order(Column("sortDate"), Column("sortKey")).fetchAll($0) }
    }

    func testInitialScanPairsAndSorts() async throws {
        let s = try await scanner().scan()
        XCTAssertEqual(s.filesSeen, 3) // MP4 and dot-directories ignored
        XCTAssertEqual(s.photos, 2)
        let p = try await photos()
        XCTAssertEqual(p.map(\.stemKey), ["img_2", "img_1"]) // by EXIF date, not name
        XCTAssertNotNil(p[1].rawFileId)
    }

    func testRescanUnchangedReadsNothing() async throws {
        _ = try await scanner().scan()
        let s = try await scanner().scan()
        XCTAssertEqual(s.filesRead, 0)
        XCTAssertEqual(s.photos, 2)
    }

    func testTouchKeepsFingerprint() async throws {
        _ = try await scanner().scan()
        let before = try await db.writer.read { try RemoteFile.filter(Column("name") == "IMG_2.JPG").fetchOne($0)! }
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: 3600)],
                                              ofItemAtPath: dir.appendingPathComponent("card1/IMG_2.JPG").path)
        let s = try await scanner().scan()
        XCTAssertEqual(s.filesRead, 1)
        let after = try await db.writer.read { try RemoteFile.filter(Column("name") == "IMG_2.JPG").fetchOne($0)! }
        XCTAssertEqual(before.fp, after.fp)
    }

    func testContentChangeChangesFingerprint() async throws {
        _ = try await scanner().scan()
        let before = try await db.writer.read { try RemoteFile.filter(Column("name") == "IMG_2.JPG").fetchOne($0)! }
        // Same size, new content. Detection relies on the mtime moving, as any real
        // rewrite does; a same-size rewrite within the same second is not detected.
        let url = dir.appendingPathComponent("card1/IMG_2.JPG")
        try Fixtures.jpeg(date: "2026:01:01 09:00:00", seed: 99).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: 60)], ofItemAtPath: url.path)
        _ = try await scanner().scan()
        let after = try await db.writer.read { try RemoteFile.filter(Column("name") == "IMG_2.JPG").fetchOne($0)! }
        XCTAssertNotEqual(before.fp, after.fp)
    }

    func testFolderRenameKeepsFingerprints() async throws {
        _ = try await scanner().scan()
        let fps = try await db.writer.read { try Set(RemoteFile.fetchAll($0).compactMap(\.fp)) }
        try FileManager.default.moveItem(at: dir.appendingPathComponent("card1"), to: dir.appendingPathComponent("renamed"))
        let s = try await scanner().scan()
        XCTAssertEqual(s.filesRemoved, 3)
        XCTAssertEqual(s.photos, 2)
        let after = try await db.writer.read { try Set(RemoteFile.fetchAll($0).compactMap(\.fp)) }
        XCTAssertEqual(fps, after)
        let dirs = try await photos().map(\.dir)
        XCTAssertEqual(dirs, ["renamed", "renamed"])
    }

    func testSmallFileFingerprintCoversWholeFile() {
        XCTAssertNil(Fingerprint.tailRange(size: 1000))
        XCTAssertNotNil(Fingerprint.tailRange(size: 1_000_000))
        let a = Fingerprint.compute(size: 3, head: Data([1, 2, 3]), tail: nil)
        let b = Fingerprint.compute(size: 3, head: Data([1, 2, 4]), tail: nil)
        XCTAssertNotEqual(a, b)
    }
}
