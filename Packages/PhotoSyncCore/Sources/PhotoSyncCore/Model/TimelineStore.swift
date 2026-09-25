import Foundation
import GRDB
import Observation

/// The single chronological timeline shown in the gallery, kept live from the
/// database: photos change on scans, statuses change as imports progress.
@MainActor
@Observable
public final class TimelineStore {
    public private(set) var entries: [PhotoEntry] = []
    public private(set) var statuses: [Int64: PhotoStatus] = [:]
    public private(set) var selectedID: Int64?
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

    public func entries(around index: Int, before: Int, after: Int) -> ArraySlice<PhotoEntry> {
        guard !entries.isEmpty else { return [] }
        let lo = max(0, index - before), hi = min(entries.count - 1, index + after)
        return entries[lo...hi]
    }

    public var importedCount: Int { statuses.values.filter(\.isImported).count }
}
