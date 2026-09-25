import XCTest
@testable import PhotoSyncCore

final class PairingTests: XCTestCase {
    func file(_ rel: String, id: Int64, date: Date? = nil, mtime: Int64 = 0) -> RemoteFile {
        let name = (rel as NSString).lastPathComponent
        return RemoteFile(id: id, rootPath: "r", relPath: rel, dir: (rel as NSString).deletingLastPathComponent,
                          name: name, stemKey: stemKey(name), kind: FileKind(filename: name)!, size: 1, mtime: mtime,
                          fp: nil, captureDate: date, orientation: nil, previewOffset: nil, previewLength: nil, photoId: nil)
    }

    func testPairsWithinDirectoryOnly() {
        let groups = Pairing.group([
            file("a/IMG_1.JPG", id: 1), file("a/img_1.CR3", id: 2),
            file("b/IMG_1.CR3", id: 3), // same name, other folder: separate photo
            file("a/IMG_2.JPG", id: 4),
        ])
        XCTAssertEqual(groups.count, 3)
        let a1 = groups.first { $0.dir == "a" && $0.stemKey == "img_1" }!
        XCTAssertEqual(a1.primary?.id, 1)
        XCTAssertEqual(a1.raw?.id, 2)
        let b1 = groups.first { $0.dir == "b" }!
        XCTAssertNil(b1.primary)
        XCTAssertEqual(b1.raw?.id, 3)
    }

    func testPreferences() {
        let g = Pairing.group([file("x.png", id: 1), file("x.JPG", id: 2), file("x.dng", id: 3), file("x.CR3", id: 4)])[0]
        XCTAssertEqual(g.primary?.id, 2)
        XCTAssertEqual(g.raw?.id, 4)
    }

    func testSortDateFallsBackToMtime() {
        let d = Date(timeIntervalSince1970: 1000)
        XCTAssertEqual(Pairing.group([file("x.JPG", id: 1, mtime: 50), file("x.CR3", id: 2, date: d)])[0].sortDate, d)
        XCTAssertEqual(Pairing.group([file("y.JPG", id: 1, mtime: 50)])[0].sortDate, Date(timeIntervalSince1970: 50))
    }
}
