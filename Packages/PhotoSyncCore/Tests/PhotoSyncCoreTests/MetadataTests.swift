import XCTest
@testable import PhotoSyncCore

final class MetadataTests: XCTestCase {
    func testSyntheticJPEGExif() {
        let m = MetadataReader.read(head: Fixtures.jpeg(orientation: 6), kind: .jpeg)
        XCTAssertEqual(m.captureDate, MetadataReader.exifDateFormatter.date(from: "2026:08:29 19:01:34"))
        XCTAssertEqual(m.orientation, 6)
    }

    func testGarbageIsHarmless() {
        XCTAssertEqual(MetadataReader.read(head: Data(repeating: 0xAB, count: 1000), kind: .jpeg), ImageMetadata())
        XCTAssertEqual(MetadataReader.read(head: Data(repeating: 0xAB, count: 1000), kind: .cr3), ImageMetadata())
        XCTAssertEqual(MetadataReader.read(head: Data(), kind: .cr3), ImageMetadata())
    }

    func testTruncatedJPEGHeaderDoesNotCrash() {
        let full = Fixtures.jpeg()
        for n in [3, 10, 20, 40, 60, 90] { _ = MetadataReader.read(head: full.prefix(n), kind: .jpeg) }
    }

    func testFileKinds() {
        XCTAssertEqual(FileKind(filename: "899A6627.CR3"), .cr3)
        XCTAssertEqual(FileKind(filename: "x.JPEG"), .jpeg)
        XCTAssertEqual(FileKind(filename: "x.jpg"), .jpeg)
        XCTAssertNil(FileKind(filename: "GOPR1392.GPR"))
        XCTAssertNil(FileKind(filename: "GH011364.MP4"))
        XCTAssertNil(FileKind(filename: ".imgselect.sqlite"))
        XCTAssertEqual(stemKey("IMG_1234.CR3"), "img_1234")
    }

    /// Real Canon EOS R7 files (skipped unless <repo>/samples exists).
    func testR7Samples() throws {
        let dir = try XCTUnwrap(Fixtures.samplesDir, "samples/ not present")
        let date = MetadataReader.exifDateFormatter.date(from: "2026:08:29 19:01:34")

        let cr3Head = try FileHandle(forReadingFrom: dir.appendingPathComponent("899A6627.CR3")).read(upToCount: MetadataReader.headLength(for: .cr3))!
        let cr3 = MetadataReader.read(head: cr3Head, kind: .cr3)
        XCTAssertEqual(cr3.captureDate!.timeIntervalSince(date!), 0, accuracy: 0.999) // + SubSecTimeOriginal
        XCTAssertEqual(cr3.model, "Canon EOS R7")
        XCTAssertEqual(cr3.previewRange, 115_656..<319_968) // PRVW, 1620x1080

        let jpgHead = try FileHandle(forReadingFrom: dir.appendingPathComponent("899A6627.JPG")).read(upToCount: MetadataReader.headLength(for: .jpeg))!
        let jpg = MetadataReader.read(head: jpgHead, kind: .jpeg)
        XCTAssertEqual(jpg.captureDate!.timeIntervalSince(date!), 0, accuracy: 0.999)
        XCTAssertEqual(jpg.previewRange, 28_672..<38_703) // EXIF thumbnail, 160x120
    }
}
