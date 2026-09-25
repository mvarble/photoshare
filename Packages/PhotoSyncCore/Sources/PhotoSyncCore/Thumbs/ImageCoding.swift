import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum ImageCoding {
    /// Decodes and downsizes; applies the image's own EXIF orientation, or
    /// `orientation` (from the parent file) for embedded previews that lack one.
    public static func downsample(_ data: Data, maxPixel: Int, orientation: Int? = nil) -> CGImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let img = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        let own = props?[kCGImagePropertyOrientation] as? Int
        guard own == nil, let orientation, orientation != 1,
              let o = CGImagePropertyOrientation(rawValue: UInt32(orientation)) else { return img }
        let ci = CIImage(cgImage: img).oriented(o)
        return CIContext().createCGImage(ci, from: ci.extent)
    }

    public static func jpegData(_ image: CGImage, quality: Double = 0.8) -> Data? {
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        return CGImageDestinationFinalize(dest) ? out as Data : nil
    }

    public static func decode(_ data: Data) -> CGImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }
}
