import Foundation
import Photos

/// PhotoKit implementation, validated in spike 0a: JPEG as `.photo` + CR3 as
/// `.alternatePhoto` gives one asset with "Use RAW as Original".
public struct PhotoKitImporter: PhotosImporting {
    public init() {}

    public func authorize() async -> Bool {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        if status == .authorized { return true }
        if status == .notDetermined { return await PHPhotoLibrary.requestAuthorization(for: .readWrite) == .authorized }
        return false
    }

    public func createAsset(primary: StagedResource, alternate: StagedResource?) async throws -> String {
        var id: String?
        try await PHPhotoLibrary.shared().performChanges {
            let req = PHAssetCreationRequest.forAsset()
            req.addResource(with: .photo, fileURL: primary.url, options: Self.options(primary))
            if let alternate {
                req.addResource(with: .alternatePhoto, fileURL: alternate.url, options: Self.options(alternate))
            }
            id = req.placeholderForCreatedAsset?.localIdentifier
        }
        guard let id else { throw ImportError.photosReturnedNoIdentifier }
        return id
    }

    static func options(_ r: StagedResource) -> PHAssetResourceCreationOptions {
        let o = PHAssetResourceCreationOptions()
        o.originalFilename = r.filename
        o.uniformTypeIdentifier = r.uti
        o.shouldMoveFile = false // Photos copies; the stager deletes its copy afterwards
        return o
    }

    public func assetExists(_ localIdentifier: String) async -> Bool {
        PHAsset.fetchAssets(withLocalIdentifiers: [localIdentifier], options: nil).count > 0
    }

    public func findAsset(filename: String, near date: Date?) async -> String? {
        let opts = PHFetchOptions()
        if let date {
            // Wide window: Photos and EXIF can disagree on the zone by hours (spike 0a saw 1 h).
            opts.predicate = NSPredicate(format: "creationDate >= %@ AND creationDate <= %@",
                                         date.addingTimeInterval(-26 * 3600) as NSDate,
                                         date.addingTimeInterval(26 * 3600) as NSDate)
        }
        let assets = PHAsset.fetchAssets(with: .image, options: opts)
        var found: String?
        assets.enumerateObjects { a, _, stop in
            if PHAssetResource.assetResources(for: a).contains(where: {
                ($0.type == .photo || $0.type == .alternatePhoto) && $0.originalFilename.caseInsensitiveCompare(filename) == .orderedSame
            }) {
                found = a.localIdentifier
                stop.pointee = true
            }
        }
        return found
    }

    public func deleteAssets(_ localIdentifiers: [String]) async throws {
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: localIdentifiers, options: nil)
        guard assets.count > 0 else { return }
        try await PHPhotoLibrary.shared().performChanges { PHAssetChangeRequest.deleteAssets(assets) }
    }
}

public enum ImportError: Error, LocalizedError, Equatable {
    case photosAccessDenied
    case photosReturnedNoIdentifier
    case fileChangedDuringImport
    case nothingToImport
    case testLimitReached(Int)

    public var errorDescription: String? {
        switch self {
        case .photosAccessDenied: "PhotoSync isn't allowed to add to Photos. Turn it on in System Settings → Privacy & Security → Photos."
        case .photosReturnedNoIdentifier: "Photos didn't confirm the import."
        case .fileChangedDuringImport: "The photo changed on the server while importing. It will be retried."
        case .nothingToImport: "This photo has no importable file."
        case .testLimitReached(let n): "Test builds import at most \(n) photos per session."
        }
    }
}
