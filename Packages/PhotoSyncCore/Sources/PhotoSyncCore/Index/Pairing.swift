import Foundation

/// Groups files that share (root, directory, lowercased stem) into photos.
public enum Pairing {
    public struct Group: Sendable, Equatable {
        public var rootPath: String
        public var dir: String
        public var stemKey: String
        public var primary: RemoteFile?
        public var raw: RemoteFile?

        public var sortDate: Date {
            if let d = primary?.captureDate ?? raw?.captureDate { return d }
            return Date(timeIntervalSince1970: TimeInterval((primary ?? raw)?.mtime ?? 0))
        }

        public var sortKey: String { (primary ?? raw).map { remoteJoin($0.rootPath, $0.relPath) } ?? stemKey }
    }

    /// Primary preference: JPEG, then HEIC, then PNG. RAW preference: CR3, then DNG.
    /// Extra same-stem files (e.g. both .JPG and .jpeg) are left unpaired.
    public static func group(_ files: [RemoteFile]) -> [Group] {
        let primaryRank: [FileKind: Int] = [.jpeg: 0, .heic: 1, .png: 2]
        let rawRank: [FileKind: Int] = [.cr3: 0, .dng: 1]
        var groups: [String: Group] = [:]
        for f in files {
            let key = "\(f.rootPath)\u{0}\(f.dir)\u{0}\(f.stemKey)"
            var g = groups[key] ?? Group(rootPath: f.rootPath, dir: f.dir, stemKey: f.stemKey)
            if let r = primaryRank[f.kind] {
                if g.primary.map({ primaryRank[$0.kind]! > r || (primaryRank[$0.kind]! == r && $0.name > f.name) }) ?? true { g.primary = f }
            } else if let r = rawRank[f.kind] {
                if g.raw.map({ rawRank[$0.kind]! > r || (rawRank[$0.kind]! == r && $0.name > f.name) }) ?? true { g.raw = f }
            }
            groups[key] = g
        }
        return Array(groups.values)
    }
}
