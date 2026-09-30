import XCTest
@testable import PhotoSyncCore

@MainActor
final class TimelineTests: XCTestCase {
    func entry(_ id: Int64, _ date: String) -> PhotoEntry {
        PhotoEntry(photo: Photo(id: id, rootPath: "r", dir: "d", stemKey: "\(id)", primaryFileId: nil, rawFileId: nil,
                                sortDate: MetadataReader.exifDateFormatter.date(from: date)!, sortKey: "\(id)"))
    }

    /// Aug: 5 photos (ids 1–5), Sep: 2 photos (ids 6–7).
    func store() -> TimelineStore {
        let t = TimelineStore()
        t.setEntries([
            entry(1, "2026:08:01 10:00:00"), entry(2, "2026:08:02 10:00:00"), entry(3, "2026:08:03 10:00:00"),
            entry(4, "2026:08:04 10:00:00"), entry(5, "2026:08:31 23:59:59"),
            entry(6, "2026:09:01 00:00:00"), entry(7, "2026:09:02 10:00:00"),
        ], fallbackSelection: 1)
        return t
    }

    func testMonthSections() {
        let s = store().sections
        XCTAssertEqual(s.map(\.id), ["2026-08", "2026-09"])
        XCTAssertEqual(s.map(\.range), [0..<5, 5..<7])
        XCTAssertTrue(s[0].title.hasSuffix(", 2026"))
    }

    func testVerticalMovementRespectsMonthRows() {
        // 3 columns. Aug rows: [1 2 3] [4 5]; Sep row: [6 7]
        let t = store()
        t.select(2); t.moveVertically(1, columns: 3); XCTAssertEqual(t.selectedID, 5)
        t.select(3); t.moveVertically(1, columns: 3); XCTAssertEqual(t.selectedID, 5) // short row below
        t.select(5); t.moveVertically(1, columns: 3); XCTAssertEqual(t.selectedID, 7) // into September, same column
        t.select(6); t.moveVertically(-1, columns: 3); XCTAssertEqual(t.selectedID, 4) // back to August's last row
        t.select(7); t.moveVertically(-1, columns: 3); XCTAssertEqual(t.selectedID, 5)
        t.select(1); t.moveVertically(-1, columns: 3); XCTAssertEqual(t.selectedID, 1) // top stays put
        t.select(7); t.moveVertically(1, columns: 3); XCTAssertEqual(t.selectedID, 7) // bottom stays put
    }
}
