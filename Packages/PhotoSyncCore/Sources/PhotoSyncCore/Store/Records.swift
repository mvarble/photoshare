import Foundation
import GRDB

/// One file on the server that PhotoSync indexes.
public struct RemoteFile: Codable, Sendable, Equatable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "remote_file"

    public var id: Int64?
    public var rootPath: String
    /// Path relative to the root, e.g. "imports/2026-09-24-1/100EOSR7/899A6627.CR3".
    public var relPath: String
    public var dir: String
    public var name: String
    public var stemKey: String
    public var kind: FileKind
    public var size: Int64
    public var mtime: Int64
    /// Content fingerprint (plan §3); nil until the header has been read.
    public var fp: Data?
    public var captureDate: Date?
    public var orientation: Int?
    public var previewOffset: Int64?
    public var previewLength: Int64?
    public var photoId: Int64?

    public var remotePath: String { remoteJoin(rootPath, relPath) }

    public var previewRange: Range<UInt64>? {
        guard let o = previewOffset, let l = previewLength, l > 0 else { return nil }
        return UInt64(o)..<UInt64(o + l)
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

/// One logical photo: a primary image (JPEG/HEIC/PNG) and/or a RAW sharing a
/// basename in the same directory.
public struct Photo: Codable, Sendable, Equatable, Identifiable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "photo"

    public var id: Int64?
    public var rootPath: String
    public var dir: String
    public var stemKey: String
    public var primaryFileId: Int64?
    public var rawFileId: Int64?
    /// Capture time (naive, as UTC) of primary, else RAW, else file mtime.
    public var sortDate: Date
    /// Stable tiebreak for identical timestamps (burst shots).
    public var sortKey: String

    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

public enum ImportState: String, Codable, Sendable {
    case queued, downloading, importing, done, failed, inDoubt
}

/// One attempt to put a photo into Photos. Matched to photos by content
/// fingerprint, so status survives server-side moves and renames.
public struct ImportRecord: Codable, Sendable, Equatable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "import_record"

    public var id: Int64?
    public var uuid: String
    public var photoId: Int64?
    public var state: ImportState
    public var primaryFp: Data?
    public var rawFp: Data?
    /// Filenames, kept for crash recovery lookups in Photos.
    public var primaryName: String?
    public var rawName: String?
    public var primarySha256: Data?
    public var rawSha256: Data?
    public var rawAttached: Bool
    public var localIdentifier: String?
    public var isReimport: Bool
    public var error: String?
    public var attempts: Int
    public var createdAt: Date
    public var completedAt: Date?

    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}
