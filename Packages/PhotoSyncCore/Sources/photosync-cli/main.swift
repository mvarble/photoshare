import Foundation
import GRDB
import PhotoSyncCore

let args = Array(CommandLine.arguments.dropFirst())
switch args.first {
case "meta":
    for path in args.dropFirst() {
        let name = (path as NSString).lastPathComponent
        guard let kind = FileKind(filename: name) else { print("\(name): ignored"); continue }
        let head = try FileHandle(forReadingFrom: URL(fileURLWithPath: path)).read(upToCount: MetadataReader.headLength(for: kind)) ?? Data()
        let m = MetadataReader.read(head: head, kind: kind)
        print("\(name): kind=\(kind) date=\(m.captureDate.map { "\($0)" } ?? "nil") orient=\(m.orientation.map(String.init) ?? "nil") model=\(m.model ?? "nil") preview=\(m.previewRange.map { "\($0)" } ?? "nil")")
    }
case "scan":
    // photosync-cli scan <host> <user> <root>… — uses ~/.ssh/id_ed25519 and pins the known_hosts key.
    let host = args[1], user = args[2], roots = Array(args.dropFirst(3))
    let paths = AppPaths.standard(name: "PhotoSync-cli")
    try paths.createDirectories()
    let keyText = try String(contentsOfFile: NSHomeDirectory() + "/.ssh/id_ed25519", encoding: .utf8)
    let key = try KeyStore.parseOpenSSH(keyText)
    let session = SSHSession(config: ServerConfig(host: host, username: user, roots: roots, pinnedHostKey: knownHostKey(host)), key: key)
    let db = try AppDatabase.open(at: paths.database)
    var scanner = LibraryScanner(fs: SFTPRemoteFS(session: session, lane: .scan, channels: Int(ProcessInfo.processInfo.environment["CHANNELS"] ?? "4")!, maxConcurrent: 16), db: db, roots: roots)
    scanner.concurrency = 16
    let t0 = Date()
    let summary = try await scanner.scan { p in
        FileHandle.standardError.write("\r\(p.phase.rawValue) found=\(p.filesFound) read=\(p.filesRead)/\(p.filesToRead)   ".data(using: .utf8)!)
    }
    print("\nscan took \(String(format: "%.1f", Date().timeIntervalSince(t0))) s: \(summary.filesSeen) files, \(summary.filesRead) read, \(summary.filesRemoved) removed, \(summary.photos) photos, \(summary.failures.count) failures")
    for f in summary.failures.prefix(5) { print("  failure: \(f)") }
    try await printStats(db)
    await session.close()
case "thumbs":
    // photosync-cli thumbs <host> <user> <outdir> <photoId>… — exercises ThumbnailService tiers.
    let host = args[1], user = args[2], out = URL(fileURLWithPath: args[3])
    let paths = AppPaths.standard(name: "PhotoSync-cli")
    try paths.createDirectories()
    let key = try KeyStore.parseOpenSSH(try String(contentsOfFile: NSHomeDirectory() + "/.ssh/id_ed25519", encoding: .utf8))
    let session = SSHSession(config: ServerConfig(host: host, username: user, roots: [], pinnedHostKey: knownHostKey(host)), key: key)
    let db = try AppDatabase.open(at: paths.database)
    let svc = ThumbnailService(fs: SFTPRemoteFS(session: session, lane: .browse, maxConcurrent: 6),
                               thumbs: DiskCache(dir: paths.thumbs, limitBytes: 300_000_000),
                               previews: DiskCache(dir: paths.previews, limitBytes: 500_000_000))
    try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    for id in args.dropFirst(4).compactMap({ Int64($0) }) {
        guard let e = try await db.writer.read({ try PhotoEntry.fetch($0, id: id) }) else { continue }
        for (label, op) in [("thumb", { await svc.thumbnail(for: e) }), ("quick", { await svc.quickPreview(for: e) }), ("full", { await svc.fullPreview(for: e) })] as [(String, () async -> Data?)] {
            let t0 = Date()
            let d = await op()
            let dims = d.flatMap(ImageCoding.decode).map { "\($0.width)x\($0.height)" } ?? "nil"
            print("\(e.displayName) \(label): \(dims) \(d?.count ?? 0) bytes in \(Int(Date().timeIntervalSince(t0) * 1000)) ms")
            if let d { try d.write(to: out.appendingPathComponent("\(id)-\(label).jpg")) }
        }
    }
    await session.close()
case "stats":
    try await printStats(try AppDatabase.open(at: AppPaths.standard(name: "PhotoSync-cli").database))
default:
    print("usage: photosync-cli meta <files…> | scan <host> <user> <root>… | stats")
}

func knownHostKey(_ host: String) -> String? {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
    p.arguments = ["-F", host]
    let pipe = Pipe()
    p.standardOutput = pipe
    try? p.run()
    p.waitUntilExit()
    let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    return out.split(separator: "\n").first { $0.contains("ssh-ed25519") }
        .map { $0.split(separator: " ").dropFirst().prefix(2).joined(separator: " ") }
}

func printStats(_ db: AppDatabase) async throws {
    let rows: [Row] = try await db.writer.read { db in
        try Row.fetchAll(db, sql: """
            SELECT (p.primaryFileId IS NOT NULL) AS hasPrimary, (p.rawFileId IS NOT NULL) AS hasRaw, COUNT(*) AS n
            FROM photo p GROUP BY 1, 2 ORDER BY n DESC
            """)
    }
    for r in rows { print("  primary=\(r["hasPrimary"] as Bool) raw=\(r["hasRaw"] as Bool): \(r["n"] as Int)") }
    let noDate: Int = try await db.writer.read { db in
        try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM remote_file WHERE captureDate IS NULL") ?? 0
    }
    let noPreview: Int = try await db.writer.read { db in
        try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM remote_file WHERE previewOffset IS NULL") ?? 0
    }
    print("  files without EXIF date: \(noDate), without embedded preview: \(noPreview)")
}
