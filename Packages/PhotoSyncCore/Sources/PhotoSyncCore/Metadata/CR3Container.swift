import Foundation

/// Canon CR3 (ISO-BMFF) box walker. Layout observed on EOS R7 (spike 0c):
///   ftyp, moov{ uuid 85c0b687…{ CMT1(TIFF IFD0), CMT2(EXIF), …, THMB }, … },
///   uuid be7acfcb…, uuid eaf42b5e…{ PRVW(JPEG ~1620 px) }, mdat
enum CR3Container {
    static let canonUUID = "85c0b687820f11e08111f4ce462b6a48"
    static let previewUUID = "eaf42b5e1c984b88b9fbb7dc406e4d16"

    struct Box { let type: String; let start: Int; let size: Int; let bodyStart: Int; let uuid: String? }

    static func boxes(_ d: [UInt8], from: Int, to: Int) -> [Box] {
        var out: [Box] = []
        var off = from
        while off + 8 <= min(to, d.count) {
            var size = Int(be32(d, off))
            let type = String(decoding: d[(off + 4)..<(off + 8)], as: UTF8.self)
            var body = off + 8
            if size == 1 {
                guard off + 16 <= d.count else { break }
                size = Int(be32(d, off + 8)) << 32 | Int(be32(d, off + 12))
                body = off + 16
            } else if size == 0 {
                size = to - off
            }
            guard size >= 8 else { break }
            var uuid: String?
            if type == "uuid" {
                guard body + 16 <= d.count else {
                    out.append(Box(type: type, start: off, size: size, bodyStart: body, uuid: nil)); break
                }
                uuid = d[body..<(body + 16)].map { String(format: "%02x", $0) }.joined()
                body += 16
            }
            out.append(Box(type: type, start: off, size: size, bodyStart: body, uuid: uuid))
            off += size
        }
        return out
    }

    static func metadata(head: Data) -> ImageMetadata {
        let d = [UInt8](head)
        var m = ImageMetadata()
        let top = boxes(d, from: 0, to: Int.max)
        guard top.first?.type == "ftyp" else { return m }

        if let moov = top.first(where: { $0.type == "moov" }),
           let canon = boxes(d, from: moov.bodyStart, to: moov.start + moov.size).first(where: { $0.uuid == canonUUID }) {
            for b in boxes(d, from: canon.bodyStart, to: canon.start + canon.size) {
                let end = min(b.start + b.size, d.count)
                guard b.bodyStart < end else { continue }
                let blob = Data(d[b.bodyStart..<end])
                switch b.type {
                case "CMT1":
                    if let r = TIFFReader.parse(blob, base: 0) {
                        m.orientation = r.orientation ?? m.orientation
                        m.model = r.model ?? m.model
                    }
                case "CMT2":
                    // CMT2 is the EXIF IFD wrapped in its own TIFF header.
                    if let r = TIFFReader.parse(blob, base: 0) {
                        let date = r.dateTimeOriginal ?? exifIFD0Date(blob)
                        m.captureDate = MetadataReader.parseExifDate(date, subsec: r.subSecOriginal)
                    }
                case "THMB":
                    if m.previewRange == nil, let j = jpegRange(d, in: b) { m.previewRange = j }
                default: break
                }
            }
        }
        if let prv = top.first(where: { $0.uuid == previewUUID }),
           let prvw = boxes(d, from: prv.bodyStart + 8, to: prv.start + prv.size).first(where: { $0.type == "PRVW" }),
           let j = jpegRange(d, in: prvw) {
            m.previewRange = j
        }
        return m
    }

    /// In CMT2 the date tags live directly in IFD0 (it *is* the EXIF IFD).
    static func exifIFD0Date(_ blob: Data) -> String? {
        guard let r = TIFFReader.parse(blob, base: 0) else { return nil }
        return r.dateTimeOriginal
    }

    /// The JPEG inside a THMB/PRVW box starts at the first FFD8FF within its
    /// header area and runs to the box end (trailing padding is harmless).
    static func jpegRange(_ d: [UInt8], in b: Box) -> Range<UInt64>? {
        let scanEnd = min(b.bodyStart + 64, d.count - 3)
        guard b.bodyStart < scanEnd else { return nil }
        for i in b.bodyStart..<scanEnd where d[i] == 0xFF && d[i + 1] == 0xD8 && d[i + 2] == 0xFF {
            return UInt64(i)..<UInt64(b.start + b.size)
        }
        return nil
    }

    static func be32(_ d: [UInt8], _ o: Int) -> UInt32 {
        UInt32(d[o]) << 24 | UInt32(d[o + 1]) << 16 | UInt32(d[o + 2]) << 8 | UInt32(d[o + 3])
    }
}
