import Foundation
import GRDB

/// A photo plus its files: everything the UI, thumbnailer and importer need.
public struct PhotoEntry: Sendable, Equatable, Identifiable {
    public var photo: Photo
    public var primary: RemoteFile?
    public var raw: RemoteFile?

    public var id: Int64 { photo.id! }
    public var sortDate: Date { photo.sortDate }
    public var displayName: String { (primary ?? raw)?.name ?? photo.stemKey }
    /// Cache key root: content of the primary (or RAW), so moves don't re-download.
    public var contentKey: String? { (primary?.fp ?? raw?.fp).map { $0.map { String(format: "%02x", $0) }.joined() } }

    /// Loads all photos in timeline order with their files.
    public static func fetchAll(_ db: Database) throws -> [PhotoEntry] {
        let photos = try Photo.order(Column("sortDate"), Column("sortKey")).fetchAll(db)
        var files: [Int64: RemoteFile] = [:]
        for f in try RemoteFile.filter(Column("photoId") != nil).fetchAll(db) { files[f.id!] = f }
        return photos.map { p in
            PhotoEntry(photo: p, primary: p.primaryFileId.flatMap { files[$0] }, raw: p.rawFileId.flatMap { files[$0] })
        }
    }

    public static func fetch(_ db: Database, id: Int64) throws -> PhotoEntry? {
        guard let p = try Photo.fetchOne(db, key: id) else { return nil }
        return PhotoEntry(photo: p,
                          primary: try p.primaryFileId.flatMap { try RemoteFile.fetchOne(db, key: $0) },
                          raw: try p.rawFileId.flatMap { try RemoteFile.fetchOne(db, key: $0) })
    }
}
