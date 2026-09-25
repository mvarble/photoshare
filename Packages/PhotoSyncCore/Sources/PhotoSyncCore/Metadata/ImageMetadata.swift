import Foundation

/// What the index needs from a file's first bytes.
public struct ImageMetadata: Sendable, Equatable {
    /// EXIF DateTimeOriginal as naive wall-clock time, encoded as if it were UTC
    /// (cameras store local time without a zone; see plan flag 12).
    public var captureDate: Date?
    public var orientation: Int?
    public var model: String?
    /// Byte range (absolute file offsets) of the best embedded JPEG preview:
    /// CR3 PRVW (~1620 px) if found, else the EXIF/THMB thumbnail (~160 px).
    public var previewRange: Range<UInt64>?

    public init(captureDate: Date? = nil, orientation: Int? = nil, model: String? = nil, previewRange: Range<UInt64>? = nil) {
        self.captureDate = captureDate
        self.orientation = orientation
        self.model = model
        self.previewRange = previewRange
    }
}

public enum MetadataReader {
    /// Parses whatever is available in `head` (a prefix of the file).
    public static func read(head: Data, kind: FileKind) -> ImageMetadata {
        switch kind {
        case .cr3: return CR3Container.metadata(head: head)
        case .jpeg: return JPEGHeader.metadata(head: head)
        case .dng: return TIFFReader.parse(head, base: 0).map { $0.metadata(base: 0) } ?? ImageMetadata()
        case .png, .heic: return ImageMetadata()
        }
    }

    /// How many leading bytes to fetch so `read` finds date and preview location.
    /// R7 CR3: the PRVW box header sits at ~115.6 KB (spike 0c), so 128 KB.
    public static func headLength(for kind: FileKind) -> Int {
        switch kind {
        case .cr3: 128 * 1024
        case .jpeg, .dng, .heic, .png: 72 * 1024
        }
    }

    static let exifDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return f
    }()

    static func parseExifDate(_ s: String?, subsec: String?) -> Date? {
        guard let s, let d = exifDateFormatter.date(from: s.trimmingCharacters(in: .whitespaces.union(.controlCharacters))) else { return nil }
        guard let subsec, let frac = Double("0." + subsec.trimmingCharacters(in: .whitespaces.union(.controlCharacters))) else { return d }
        return d.addingTimeInterval(frac)
    }
}
