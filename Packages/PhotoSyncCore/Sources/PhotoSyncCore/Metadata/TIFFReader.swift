import Foundation

/// Minimal TIFF/EXIF IFD parser: just the tags PhotoSync needs.
struct TIFFReader {
    let data: Data
    let littleEndian: Bool

    struct Result {
        var dateTimeOriginal: String?
        var subSecOriginal: String?
        var orientation: Int?
        var model: String?
        /// IFD1 JPEG thumbnail, offsets relative to the TIFF header.
        var thumbOffset: Int?
        var thumbLength: Int?

        func metadata(base: UInt64) -> ImageMetadata {
            var m = ImageMetadata(
                captureDate: MetadataReader.parseExifDate(dateTimeOriginal, subsec: subSecOriginal),
                orientation: orientation,
                model: model
            )
            if let o = thumbOffset, let l = thumbLength, l > 0 {
                m.previewRange = (base + UInt64(o))..<(base + UInt64(o + l))
            }
            return m
        }
    }

    /// Parses a TIFF structure starting at `base` within `data`.
    static func parse(_ data: Data, base: Int) -> Result? {
        guard data.count >= base + 8 else { return nil }
        let tiff = data.subdata(in: (data.startIndex + base)..<data.endIndex)
        let bo = tiff.prefix(2)
        let le: Bool
        if bo.elementsEqual([0x49, 0x49]) { le = true } else if bo.elementsEqual([0x4D, 0x4D]) { le = false } else { return nil }
        let r = TIFFReader(data: tiff, littleEndian: le)
        guard r.u16(2) == 42, let ifd0 = r.u32(4) else { return nil }
        var res = Result()
        var exifIFD: Int?
        r.walk(Int(ifd0)) { tag, type, count, valueOffset in
            switch tag {
            case 0x0112: res.orientation = r.value(type: type, at: valueOffset)
            case 0x0110: res.model = r.string(type: type, count: count, entryValue: valueOffset)
            case 0x8769: exifIFD = r.value(type: type, at: valueOffset)
            case 0x9003: res.dateTimeOriginal = r.string(type: type, count: count, entryValue: valueOffset)
            case 0x9291: res.subSecOriginal = r.string(type: type, count: count, entryValue: valueOffset)
            default: break
            }
        }
        if let exifIFD { r.walkExif(exifIFD, into: &res) }
        if let next = r.nextIFD(after: Int(ifd0)), next > 0 {
            r.walk(next) { tag, type, _, valueOffset in
                switch tag {
                case 0x0201: res.thumbOffset = r.value(type: type, at: valueOffset)
                case 0x0202: res.thumbLength = r.value(type: type, at: valueOffset)
                default: break
                }
            }
        }
        return res
    }

    func walkExif(_ offset: Int, into res: inout Result) {
        var local = res
        walk(offset) { tag, type, count, valueOffset in
            switch tag {
            case 0x9003: local.dateTimeOriginal = string(type: type, count: count, entryValue: valueOffset)
            case 0x9291: local.subSecOriginal = string(type: type, count: count, entryValue: valueOffset)
            default: break
            }
        }
        res = local
    }

    /// Calls `body(tag, type, count, offsetOfValueField)` for each entry.
    func walk(_ ifd: Int, _ body: (UInt16, UInt16, Int, Int) -> Void) {
        guard let n = u16(ifd), n < 1000 else { return }
        for i in 0..<Int(n) {
            let e = ifd + 2 + i * 12
            guard let tag = u16(e), let type = u16(e + 2), let count = u32(e + 4) else { return }
            body(tag, type, Int(count), e + 8)
        }
    }

    func nextIFD(after ifd: Int) -> Int? {
        guard let n = u16(ifd) else { return nil }
        return u32(ifd + 2 + Int(n) * 12).map(Int.init)
    }

    func value(type: UInt16, at off: Int) -> Int? {
        switch type {
        case 3: u16(off).map(Int.init)
        case 4, 13: u32(off).map(Int.init)
        default: nil
        }
    }

    func string(type: UInt16, count: Int, entryValue: Int) -> String? {
        guard type == 2, count > 0 else { return nil }
        let start = count <= 4 ? entryValue : (u32(entryValue).map(Int.init) ?? -1)
        guard start >= 0, start + count <= data.count else { return nil }
        let bytes = data[(data.startIndex + start)..<(data.startIndex + start + count)].prefix { $0 != 0 }
        return String(decoding: bytes, as: UTF8.self)
    }

    func u16(_ o: Int) -> UInt16? {
        guard o >= 0, o + 2 <= data.count else { return nil }
        let b0 = UInt16(data[data.startIndex + o]), b1 = UInt16(data[data.startIndex + o + 1])
        return littleEndian ? b0 | b1 << 8 : b0 << 8 | b1
    }

    func u32(_ o: Int) -> UInt32? {
        guard let a = u16(o), let b = u16(o + 2) else { return nil }
        return littleEndian ? UInt32(a) | UInt32(b) << 16 : UInt32(a) << 16 | UInt32(b)
    }
}
