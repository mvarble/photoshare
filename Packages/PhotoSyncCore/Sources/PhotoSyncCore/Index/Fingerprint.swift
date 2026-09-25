import Crypto
import Foundation

/// Content fingerprint (plan §3): SHA-256 over size ‖ first 64 KB ‖ last 16 KB.
/// Cheap (two ranged reads that the scanner needs anyway), stable across
/// renames/moves and `touch`, and different whenever the content changes.
public enum Fingerprint {
    public static let headBytes = 64 * 1024
    public static let tailBytes = 16 * 1024

    /// Byte range of the tail read, or nil when the head read covers the whole file.
    public static func tailRange(size: UInt64) -> Range<UInt64>? {
        size > UInt64(headBytes + tailBytes) ? (size - UInt64(tailBytes))..<size : nil
    }

    /// `head` must start at offset 0; `tail` is the `tailRange` read (or nil).
    public static func compute(size: UInt64, head: Data, tail: Data?) -> Data {
        var h = SHA256()
        var le = size.littleEndian
        withUnsafeBytes(of: &le) { h.update(bufferPointer: $0) }
        if let tail {
            h.update(data: head.prefix(headBytes))
            h.update(data: tail)
        } else {
            h.update(data: head) // small file: head already holds the whole thing
        }
        return Data(h.finalize())
    }
}
