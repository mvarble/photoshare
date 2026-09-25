import Foundation

/// Where PhotoSync keeps its files. In the sandboxed app these resolve inside
/// the app container automatically.
public struct AppPaths: Sendable {
    public let support: URL
    public let caches: URL

    public init(support: URL, caches: URL) {
        self.support = support
        self.caches = caches
    }

    public static func standard(name: String = "PhotoSync") -> AppPaths {
        let fm = FileManager.default
        return AppPaths(
            support: fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent(name),
            caches: fm.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent(name)
        )
    }

    public var database: URL { support.appendingPathComponent("photosync.sqlite") }
    public var config: URL { support.appendingPathComponent("config.json") }
    public var privateKey: URL { support.appendingPathComponent("id_ed25519.raw") }
    public var staging: URL { support.appendingPathComponent("Staging") }
    public var testLedger: URL { support.appendingPathComponent("test-ledger.json") }
    public var thumbs: URL { caches.appendingPathComponent("thumbs") }
    public var previews: URL { caches.appendingPathComponent("previews") }

    public func createDirectories() throws {
        for d in [support, caches, staging, thumbs, previews] {
            try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        }
    }
}
