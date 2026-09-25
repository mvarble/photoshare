import Foundation

/// What the badge on a thumbnail shows. Derived from local records only —
/// never by asking Photos (spec requirement 5).
public enum PhotoStatus: Sendable, Equatable {
    case notImported
    case queued
    case importing
    case imported(rawAttached: Bool)
    /// Imported before, but the server's file content has changed since.
    case changedSinceImport
    case failed(String)

    public var isImported: Bool { if case .imported = self { true } else { false } }
    public var isBusy: Bool { self == .queued || self == .importing }
}

public enum StatusCalculator {
    /// Import records match photos by content fingerprint, so status follows
    /// files across server-side moves and renames (plan §2–3).
    public static func statuses(entries: [PhotoEntry], records: [ImportRecord]) -> [Int64: PhotoStatus] {
        var doneByPrimary: [Data: ImportRecord] = [:]
        var doneByRaw: [Data: ImportRecord] = [:]
        var latestByPhoto: [Int64: ImportRecord] = [:]
        var everDone = Set<Int64>()
        for r in records.sorted(by: { ($0.id ?? 0) < ($1.id ?? 0) }) {
            if r.state == .done {
                if let fp = r.primaryFp { doneByPrimary[fp] = r }
                if let fp = r.rawFp { doneByRaw[fp] = r }
                if let p = r.photoId { everDone.insert(p) }
            }
            if let p = r.photoId { latestByPhoto[p] = r }
        }
        var out: [Int64: PhotoStatus] = [:]
        for e in entries {
            let latest = latestByPhoto[e.id]
            switch latest?.state {
            case .queued?, .downloading?: out[e.id] = .queued; continue
            case .importing?, .inDoubt?: out[e.id] = .importing; continue
            default: break
            }
            let done: ImportRecord? = if let fp = e.primary?.fp { doneByPrimary[fp] } else { e.raw?.fp.flatMap { doneByRaw[$0] } }
            if let done {
                out[e.id] = .imported(rawAttached: done.rawAttached || e.raw == nil)
            } else if let latest, latest.state == .failed {
                out[e.id] = .failed(latest.error ?? "Import failed")
            } else if everDone.contains(e.id) {
                out[e.id] = .changedSinceImport
            } else {
                out[e.id] = .notImported
            }
        }
        return out
    }
}
