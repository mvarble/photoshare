import Foundation
import GRDB
import Observation

/// A run of consecutive timeline entries taken in the same month.
public struct MonthSection: Identifiable, Sendable, Equatable {
    /// "2026-09"
    public var id: String
    /// "September, 2026"
    public var title: String
    /// Indices into `TimelineStore.entries`.
    public var range: Range<Int>

    /// EXIF dates are naive wall-clock times stored as UTC, so group in UTC.
    static let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    static let titleFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.setLocalizedDateFormatFromTemplate("MMMM")
        return f
    }()

    static func sections(for entries: [PhotoEntry]) -> [MonthSection] {
        var out: [MonthSection] = []
        for (i, e) in entries.enumerated() {
            let c = calendar.dateComponents([.year, .month], from: e.sortDate)
            let id = String(format: "%04d-%02d", c.year ?? 0, c.month ?? 0)
            if out.last?.id == id {
                out[out.count - 1].range = out[out.count - 1].range.lowerBound..<(i + 1)
            } else {
                out.append(MonthSection(id: id, title: "\(titleFormatter.string(from: e.sortDate)), \(c.year ?? 0)", range: i..<(i + 1)))
            }
        }
        return out
    }
}

/// The single chronological timeline shown in the gallery, kept live from the
/// database: photos change on scans, statuses change as imports progress.
@MainActor
@Observable
public final class TimelineStore {
    public private(set) var entries: [PhotoEntry] = []
    public private(set) var statuses: [Int64: PhotoStatus] = [:]
    public private(set) var selectedID: Int64?
    public private(set) var sections: [MonthSection] = []
    private var indexByID: [Int64: Int] = [:]
    private var records: [ImportRecord] = []
    @ObservationIgnored private var observations: [AnyDatabaseCancellable] = []
    @ObservationIgnored public var onSelectionChange: ((Int64) -> Void)?

    public init() {}

    public func start(db: AppDatabase, initialSelection: Int64?) {
        observations = [
            ValueObservation.tracking { try PhotoEntry.fetchAll($0) }
                .start(in: db.writer, scheduling: .mainActor, onError: { _ in }) { [weak self] entries in
                    self?.setEntries(entries, fallbackSelection: initialSelection)
                },
            ValueObservation.tracking { try ImportRecord.fetchAll($0) }
                .start(in: db.writer, scheduling: .mainActor, onError: { _ in }) { [weak self] records in
                    self?.records = records
                    self?.recomputeStatuses()
                },
        ]
    }

    func setEntries(_ new: [PhotoEntry], fallbackSelection: Int64?) {
        entries = new
        sections = MonthSection.sections(for: new)
        indexByID = Dictionary(uniqueKeysWithValues: new.enumerated().map { ($1.id, $0) })
        recomputeStatuses()
        if let s = selectedID, indexByID[s] != nil { return }
        // Restore the last-viewed photo, else start at the newest.
        if let f = fallbackSelection, indexByID[f] != nil { select(f) } else if let last = new.last { select(last.id) }
    }

    private func recomputeStatuses() {
        statuses = StatusCalculator.statuses(entries: entries, records: records)
    }

    public var selectedIndex: Int? { selectedID.flatMap { indexByID[$0] } }
    public var selected: PhotoEntry? { selectedIndex.map { entries[$0] } }

    public func status(_ id: Int64) -> PhotoStatus { statuses[id] ?? .notImported }

    public func select(_ id: Int64) {
        guard indexByID[id] != nil, selectedID != id else { return }
        selectedID = id
        onSelectionChange?(id)
    }

    /// Moves the selection by `delta` positions in the timeline, clamped to the ends.
    public func move(by delta: Int) {
        guard !entries.isEmpty else { return }
        let i = min(max((selectedIndex ?? 0) + delta, 0), entries.count - 1)
        select(entries[i].id)
    }

    /// Moves one grid row up (-1) or down (+1). Each month starts a new row in
    /// the grid, so rows are counted within the month and continue into the
    /// neighbouring month at the same column where possible.
    public func moveVertically(_ direction: Int, columns: Int) {
        guard let i = selectedIndex, let si = sections.firstIndex(where: { $0.range.contains(i) }) else { return }
        let cols = max(1, columns)
        let sec = sections[si]
        let pos = i - sec.range.lowerBound, col = pos % cols
        let lastRowStart = (sec.range.count - 1) / cols * cols
        var target = i
        if direction < 0 {
            if pos >= cols {
                target = i - cols
            } else if si > 0 {
                let prev = sections[si - 1]
                let prevLastRow = (prev.range.count - 1) / cols * cols
                target = prev.range.lowerBound + min(prevLastRow + col, prev.range.count - 1)
            }
        } else {
            if pos + cols < sec.range.count {
                target = i + cols
            } else if pos < lastRowStart {
                target = sec.range.upperBound - 1 // short last row below
            } else if si + 1 < sections.count {
                let next = sections[si + 1]
                target = next.range.lowerBound + min(col, next.range.count - 1)
            }
        }
        select(entries[target].id)
    }

    public func entries(around index: Int, before: Int, after: Int) -> ArraySlice<PhotoEntry> {
        guard !entries.isEmpty else { return [] }
        let lo = max(0, index - before), hi = min(entries.count - 1, index + after)
        return entries[lo...hi]
    }

    public var importedCount: Int { statuses.values.filter(\.isImported).count }
}
