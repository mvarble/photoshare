import Foundation
@testable import PhotoSyncCore

/// Builds small synthetic files so tests don't depend on real photos.
enum Fixtures {
    /// A JPEG-ish file: SOI, APP1/Exif with IFD0 {Orientation, ExifIFD→DateTimeOriginal}, then filler.
    static func jpeg(date: String = "2026:08:29 19:01:34", orientation: UInt16 = 1, filler: Int = 200_000, seed: UInt8 = 0) -> Data {
        var tiff = Data("MM".utf8) + be16(42) + be32(8)
        // IFD0: 2 entries at offset 8
        let ifd0Size = 2 + 2 * 12 + 4
        let exifOffset = 8 + ifd0Size
        tiff += be16(2)
        tiff += be16(0x0112) + be16(3) + be32(1) + be16(orientation) + be16(0)
        tiff += be16(0x8769) + be16(4) + be32(1) + be32(UInt32(exifOffset))
        tiff += be32(0)
        // Exif IFD: 1 entry, string stored after the IFD
        let exifIFDSize = 2 + 12 + 4
        let strOffset = exifOffset + exifIFDSize
        let dateBytes = Data(date.utf8) + Data([0])
        tiff += be16(1)
        tiff += be16(0x9003) + be16(2) + be32(UInt32(dateBytes.count)) + be32(UInt32(strOffset))
        tiff += be32(0)
        tiff += dateBytes
        let app1 = Data("Exif".utf8) + Data([0, 0]) + tiff
        var d = Data([0xFF, 0xD8, 0xFF, 0xE1]) + be16(UInt16(app1.count + 2)) + app1
        d += Data([0xFF, 0xDA]) + Data((0..<filler).map { UInt8(truncatingIfNeeded: $0 &+ Int(seed)) })
        return d
    }

    static func be16(_ v: UInt16) -> Data { Data([UInt8(v >> 8), UInt8(v & 0xFF)]) }
    static func be32(_ v: UInt32) -> Data { be16(UInt16(v >> 16)) + be16(UInt16(v & 0xFFFF)) }

    static func tempDir() throws -> URL {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("photosync-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    /// The real R7 sample pair, if it has been downloaded into <repo>/samples (gitignored).
    static var samplesDir: URL? {
        let u = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("samples")
        return FileManager.default.fileExists(atPath: u.appendingPathComponent("899A6627.CR3").path) ? u : nil
    }
}
