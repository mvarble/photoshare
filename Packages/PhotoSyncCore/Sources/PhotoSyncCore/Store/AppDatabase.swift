import Foundation
import GRDB

/// The local SQLite store (GRDB).
public final class AppDatabase: Sendable {
    public let writer: any DatabaseWriter

    public init(_ writer: any DatabaseWriter) throws {
        self.writer = writer
        try Self.migrator.migrate(writer)
    }

    public static func open(at url: URL) throws -> AppDatabase {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        return try AppDatabase(DatabasePool(path: url.path))
    }

    public static func inMemory() throws -> AppDatabase {
        try AppDatabase(DatabaseQueue())
    }

    static var migrator: DatabaseMigrator {
        var m = DatabaseMigrator()
        m.registerMigration("v1") { db in
            try db.create(table: "photo") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("rootPath", .text).notNull()
                t.column("dir", .text).notNull()
                t.column("stemKey", .text).notNull()
                t.column("primaryFileId", .integer)
                t.column("rawFileId", .integer)
                t.column("sortDate", .datetime).notNull()
                t.column("sortKey", .text).notNull()
                t.uniqueKey(["rootPath", "dir", "stemKey"])
            }
            try db.create(index: "photo_sort", on: "photo", columns: ["sortDate", "sortKey"])

            try db.create(table: "remote_file") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("rootPath", .text).notNull()
                t.column("relPath", .text).notNull()
                t.column("dir", .text).notNull()
                t.column("name", .text).notNull()
                t.column("stemKey", .text).notNull()
                t.column("kind", .text).notNull()
                t.column("size", .integer).notNull()
                t.column("mtime", .integer).notNull()
                t.column("fp", .blob)
                t.column("captureDate", .datetime)
                t.column("orientation", .integer)
                t.column("previewOffset", .integer)
                t.column("previewLength", .integer)
                t.column("photoId", .integer).references("photo", onDelete: .setNull)
                t.uniqueKey(["rootPath", "relPath"])
            }
            try db.create(index: "remote_file_fp", on: "remote_file", columns: ["fp"])

            try db.create(table: "import_record") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("uuid", .text).notNull().unique()
                t.column("photoId", .integer).references("photo", onDelete: .setNull)
                t.column("state", .text).notNull()
                t.column("primaryFp", .blob)
                t.column("rawFp", .blob)
                t.column("primaryName", .text)
                t.column("rawName", .text)
                t.column("primarySha256", .blob)
                t.column("rawSha256", .blob)
                t.column("rawAttached", .boolean).notNull()
                t.column("localIdentifier", .text)
                t.column("isReimport", .boolean).notNull()
                t.column("error", .text)
                t.column("attempts", .integer).notNull()
                t.column("createdAt", .datetime).notNull()
                t.column("completedAt", .datetime)
            }
            try db.create(index: "import_record_primaryFp", on: "import_record", columns: ["primaryFp"])
            try db.create(index: "import_record_rawFp", on: "import_record", columns: ["rawFp"])
        }
        return m
    }
}
