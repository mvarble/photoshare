import Foundation

/// A file ready to hand to Photos.
public struct StagedResource: Sendable, Equatable {
    public var url: URL
    public var filename: String
    public var uti: String

    public init(url: URL, filename: String, uti: String) {
        self.url = url
        self.filename = filename
        self.uti = uti
    }
}

/// What PhotoSync needs from the Photos library. PhotoKit in the app; a fake in tests.
public protocol PhotosImporting: Sendable {
    /// Asks for read/write access (needed to look assets up again later, plan §4).
    func authorize() async -> Bool

    /// Creates ONE asset: `primary` as the photo resource and optionally
    /// `alternate` (the RAW) as the paired alternate resource. Returns its local identifier.
    func createAsset(primary: StagedResource, alternate: StagedResource?) async throws -> String

    /// Whether an asset with this local identifier still exists (not deleted).
    func assetExists(_ localIdentifier: String) async -> Bool

    /// Finds an asset whose photo resource has `filename`, created near `date`
    /// (crash recovery and drift checks, plan §4.8 / §5).
    func findAsset(filename: String, near date: Date?) async -> String?

    /// Deletes assets (macOS asks the user to confirm).
    func deleteAssets(_ localIdentifiers: [String]) async throws
}
