import Foundation

/// File types PhotoSync indexes. Anything else (videos, GoPro GPR which macOS
/// can't decode, sidecars) is ignored. See plan "Server facts".
public enum FileKind: String, Codable, Sendable, CaseIterable {
    case jpeg, heic, png, cr3, dng

    public init?(filename: String) {
        guard !filename.hasPrefix("."), let dot = filename.lastIndex(of: ".") else { return nil }
        switch filename[filename.index(after: dot)...].lowercased() {
        case "jpg", "jpeg": self = .jpeg
        case "heic": self = .heic
        case "png": self = .png
        case "cr3": self = .cr3
        case "dng": self = .dng
        default: return nil
        }
    }

    /// RAW files attach as the alternate resource when a primary image exists.
    public var isRaw: Bool { self == .cr3 || self == .dng }

    public var uti: String {
        switch self {
        case .jpeg: "public.jpeg"
        case .heic: "public.heic"
        case .png: "public.png"
        case .cr3: "com.canon.cr3-raw-image"
        case .dng: "com.adobe.raw-image"
        }
    }
}

/// Lowercased filename without extension: the pairing key within a directory.
public func stemKey(_ filename: String) -> String {
    guard let dot = filename.lastIndex(of: ".") else { return filename.lowercased() }
    return String(filename[..<dot]).lowercased()
}
