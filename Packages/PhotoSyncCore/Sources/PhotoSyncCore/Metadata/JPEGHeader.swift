import Foundation

/// Finds the EXIF (APP1) block in a JPEG's leading bytes.
enum JPEGHeader {
    static func metadata(head: Data) -> ImageMetadata {
        let d = [UInt8](head)
        guard d.count > 4, d[0] == 0xFF, d[1] == 0xD8 else { return ImageMetadata() }
        var i = 2
        while i + 4 <= d.count {
            guard d[i] == 0xFF else { break }
            let marker = d[i + 1]
            if marker == 0xD8 || (0xD0...0xD7).contains(marker) || marker == 0x01 { i += 2; continue }
            if marker == 0xDA || marker == 0xD9 { break } // start of scan: no more metadata
            let len = Int(d[i + 2]) << 8 | Int(d[i + 3])
            if marker == 0xE1, i + 10 <= d.count, d[(i + 4)..<(i + 10)].elementsEqual(Array("Exif".utf8) + [0, 0]) {
                let tiffStart = i + 10
                return TIFFReader.parse(head, base: tiffStart)?.metadata(base: UInt64(tiffStart)) ?? ImageMetadata()
            }
            i += 2 + len
        }
        return ImageMetadata()
    }
}
