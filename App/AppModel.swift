import AppKit
import Observation
import PhotoSyncCore
import SwiftUI

/// App-wide state and wiring between the UI and PhotoSyncCore services.
@MainActor
@Observable
final class AppModel {
    enum Phase { case loading, setup, gallery }

    private(set) var phase: Phase = .loading
    let timeline = TimelineStore()
    private(set) var scanProgress: ScanProgress?
    private(set) var isScanning = false
    /// Plain-language problem shown in the footer banner (connection, Photos access…).
    var problem: String?
    /// Short-lived message ("Already in Photos ✓").
    private(set) var toast: String?
    /// Set when "Import Again…" finds the photo is still in Photos; drives a confirmation.
    var confirmDuplicateFor: Int64?
    /// Grid columns, for Up/Down navigation.
    var gridColumns = 3

    let paths = AppPaths.standard()
    private var configStore: ConfigStore { ConfigStore(url: paths.config) }
    private var keyStore: KeyStore { KeyStore(url: paths.privateKey) }

    private(set) var config: ServerConfig?
    private var session: SSHSession?
    private var db: AppDatabase?
    private(set) var thumbnails: ThumbnailService?
    private var importQueue: ImportQueue?
    private var prefetchTask: Task<Void, Never>?
    private var toastTask: Task<Void, Never>?

    #if DEBUG
    /// Her real library: debug builds import at most this many photos per launch
    /// and log them so they can be reverted.
    static let sessionImportLimit: Int? = 5
    static let useTestLedger = true
    #else
    static let sessionImportLimit: Int? = nil
    static let useTestLedger = false
    #endif

    var isReady: Bool { phase == .gallery && timeline.selected != nil && confirmDuplicateFor == nil }
    var canImportAgain: Bool { isReady && timeline.selectedID.map { timeline.status($0) } != .notImported }

    // MARK: Startup

    func start() async {
        guard phase == .loading else { return }
        try? paths.createDirectories()
        guard let config = configStore.load(), let key = keyStore.load() else {
            phase = .setup
            return
        }
        await openServices(config: config, key: key)
    }

    private func openServices(config: ServerConfig, key: Curve25519.Signing.PrivateKey) async {
        self.config = config
        let store = configStore
        let session = SSHSession(config: config, key: key) { hostKey in
            var c = config
            c.pinnedHostKey = hostKey
            try? store.save(c)
        }
        self.session = session
        do {
            let db = try AppDatabase.open(at: paths.database)
            self.db = db
            let browse = SFTPRemoteFS(session: session, lane: .browse, channels: 2, maxConcurrent: 6)
            thumbnails = ThumbnailService(
                fs: browse,
                thumbs: DiskCache(dir: paths.thumbs, limitBytes: 300_000_000),
                previews: DiskCache(dir: paths.previews, limitBytes: 500_000_000))
            let queue = ImportQueue(
                db: db,
                stager: Stager(fs: SFTPRemoteFS(session: session, lane: .importing, maxConcurrent: 1), stagingDir: paths.staging),
                photos: PhotoKitImporter(),
                ledger: Self.useTestLedger ? TestLedger(url: paths.testLedger) : nil,
                sessionLimit: Self.sessionImportLimit)
            importQueue = queue
            timeline.onSelectionChange = { [weak self] id in self?.selectionChanged(id) }
            timeline.start(db: db, initialSelection: UserDefaults.standard.object(forKey: "lastSelection") as? Int64)
            phase = .gallery
            Task { try? await queue.recover() }
            rescan()
        } catch {
            problem = "PhotoSync couldn't open its library: \(error.localizedDescription)"
            phase = .setup
        }
    }

    // MARK: Setup

    /// Tests the connection, pins the host key, and saves the configuration.
    func completeSetup(host: String, port: Int, username: String, roots: [String], key: Curve25519.Signing.PrivateKey) async throws {
        try keyStore.save(key)
        var config = ServerConfig(host: host, port: port, username: username, roots: roots)
        let pinned = PinBox()
        let probe = SSHSession(config: config, key: key) { pinned.value = $0 }
        defer { Task { await probe.close() } }
        let fs = SFTPRemoteFS(session: probe, lane: .scan, maxConcurrent: 1)
        for root in roots { _ = try await fs.list(root) }
        config.pinnedHostKey = pinned.value
        try configStore.save(config)
        await openServices(config: config, key: key)
    }

    func showSetup() {
        Task { await session?.close() }
        phase = .setup
    }

    var existingConfig: ServerConfig? { configStore.load() }

    // MARK: Scanning

    func rescan() {
        guard let db, let session, let config, !isScanning else { return }
        isScanning = true
        var scanner = LibraryScanner(fs: SFTPRemoteFS(session: session, lane: .scan, channels: 4, maxConcurrent: 16), db: db, roots: config.roots)
        scanner.concurrency = 16
        Task {
            do {
                let summary = try await scanner.scan { p in Task { @MainActor in self.scanProgress = p } }
                problem = summary.failures.isEmpty ? nil : "\(summary.failures.count) photos couldn't be read from the server."
            } catch {
                problem = Self.friendly(error)
            }
            isScanning = false
            scanProgress = nil
        }
    }

    // MARK: Selection & prefetch

    private func selectionChanged(_ id: Int64) {
        UserDefaults.standard.set(id, forKey: "lastSelection")
        guard let thumbnails, let i = timeline.selectedIndex else { return }
        let next = Array(timeline.entries(around: i, before: 1, after: 2))
        let window = Array(timeline.entries(around: i, before: 15, after: 40))
        prefetchTask?.cancel()
        prefetchTask = Task {
            // Nearest neighbours' full previews first, then thumbnails further out.
            for e in next where e.id != id {
                if Task.isCancelled { return }
                await thumbnails.prefetchPreview(for: e)
            }
            for e in window {
                if Task.isCancelled { return }
                await thumbnails.prefetchThumbnail(for: e)
            }
        }
    }

    // MARK: Importing

    func importSelected() {
        guard let id = timeline.selectedID else { return }
        importPhoto(id)
    }

    func importPhoto(_ id: Int64) {
        guard let importQueue else { return }
        Task {
            do {
                switch try await importQueue.enqueue(photoId: id) {
                case .queued: problem = nil
                case .alreadyQueued: break
                case .alreadyImported: showToast("Already in Photos ✓")
                case .limitReached(let n): showToast("Test build: \(n)-photo limit reached. Relaunch to import more.")
                }
            } catch {
                problem = Self.friendly(error)
            }
        }
    }

    /// "Import Again…": imports silently if the photo is gone from Photos,
    /// otherwise asks before creating a second copy (plan §5).
    func requestImportAgain() {
        guard let id = timeline.selectedID, let importQueue else { return }
        Task {
            guard await PhotoKitImporter().authorize() else { problem = ImportError.photosAccessDenied.errorDescription; return }
            switch try? await importQueue.locate(photoId: id) {
            case .present?: confirmDuplicateFor = id
            default: reimport(id)
            }
        }
    }

    func reimport(_ id: Int64) {
        guard let importQueue else { return }
        Task {
            do {
                if case .limitReached(let n) = try await importQueue.enqueue(photoId: id, reimport: true) {
                    showToast("Test build: \(n)-photo limit reached. Relaunch to import more.")
                }
            } catch { problem = Self.friendly(error) }
        }
    }

    func retryFailed(_ id: Int64) { reimport(id) }

    private func showToast(_ text: String) {
        toast = text
        toastTask?.cancel()
        toastTask = Task {
            try? await Task.sleep(for: .seconds(2))
            if !Task.isCancelled { toast = nil }
        }
    }

    // MARK: Debug

    #if DEBUG
    func revertTestImports() async {
        let ledger = TestLedger(url: paths.testLedger)
        let ids = ledger.ids()
        guard !ids.isEmpty else { showToast("No test imports to revert."); return }
        do {
            try await PhotoKitImporter().deleteAssets(ids)
            ledger.clear()
            if let db {
                try await db.writer.write { db in
                    _ = try ImportRecord.filter(ids.contains(Column("localIdentifier"))).deleteAll(db)
                }
            }
            showToast("Removed \(ids.count) test import(s). Empty them from Recently Deleted in Photos.")
        } catch {
            problem = "Couldn't remove test imports: \(error.localizedDescription)"
        }
    }
    #endif

    static func friendly(_ error: Error) -> String {
        if let e = error as? LocalizedError, let d = e.errorDescription { return d }
        return "Can't reach the photo server right now. Check the Wi-Fi and try again (⌘R)."
    }
}

final class PinBox: @unchecked Sendable {
    var value: String?
}
