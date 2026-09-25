import CoreGraphics
import Foundation

/// Produces grid thumbnails and progressive previews, cheapest source first
/// (plan §6), with disk caching and in-flight de-duplication.
public actor ThumbnailService {
    public static let thumbPixels = 480
    public static let previewPixels = 2560
    /// Embedded previews smaller than this are the ~160 px EXIF/THMB kind.
    static let largeEmbeddedPreview: Int64 = 60_000
    /// Largest file fetched whole just to make a grid thumbnail.
    static let maxAutoDownload: Int64 = 60_000_000

    let fs: any RemoteFS
    let thumbs: DiskCache
    let previews: DiskCache
    /// Background prefetch gets its own small limiter so visible cells go first.
    let prefetchLimiter = AsyncLimiter(limit: 2)
    private var inflight: [String: Task<Data?, Never>] = [:]

    public init(fs: any RemoteFS, thumbs: DiskCache, previews: DiskCache) {
        self.fs = fs
        self.thumbs = thumbs
        self.previews = previews
    }

    // MARK: Thumbnails

    /// Cached grid thumbnail only; never touches the network.
    public func cachedThumbnail(for e: PhotoEntry) async -> Data? {
        guard let key = e.contentKey else { return nil }
        return await thumbs.data(for: key)
    }

    /// Grid thumbnail JPEG (~480 px), from cache or the cheapest remote source.
    /// Fetches are shared between callers and finish even if the caller is
    /// cancelled, so callers should debounce before asking (see ThumbnailCell).
    public func thumbnail(for e: PhotoEntry) async -> Data? {
        guard let key = e.contentKey else { return nil }
        if let d = await thumbs.data(for: key) { return d }
        if Task.isCancelled { return nil }
        return await shared("t:" + key) { [self] in
            guard let img = await thumbSource(e) else { return nil }
            guard let jpeg = ImageCoding.jpegData(img) else { return nil }
            await thumbs.store(jpeg, for: key)
            return jpeg
        }
    }

    /// Warms the thumbnail cache without competing with visible cells.
    public func prefetchThumbnail(for e: PhotoEntry) async {
        guard let key = e.contentKey, await !thumbs.contains(key) else { return }
        await prefetchLimiter.run { _ = await self.thumbnail(for: e) }
    }

    private func thumbSource(_ e: PhotoEntry) async -> CGImage? {
        // 1. Large embedded preview (CR3 PRVW ~1620 px): one ~200 KB ranged read.
        for f in [e.raw, e.primary].compactMap({ $0 }) {
            if let r = f.previewRange, f.previewLength ?? 0 >= Self.largeEmbeddedPreview,
               let d = try? await fs.read(f.remotePath, offset: r.lowerBound, length: Int(r.upperBound - r.lowerBound)),
               let img = ImageCoding.downsample(d, maxPixel: Self.thumbPixels, orientation: f.orientation) {
                return img
            }
        }
        // 2. Small embedded thumbnail (EXIF/THMB, ~160 px): upgraded later by `preview`.
        for f in [e.primary, e.raw].compactMap({ $0 }) {
            if let r = f.previewRange,
               let d = try? await fs.read(f.remotePath, offset: r.lowerBound, length: Int(r.upperBound - r.lowerBound)),
               let img = ImageCoding.downsample(d, maxPixel: Self.thumbPixels, orientation: f.orientation) {
                return img
            }
        }
        // 3. No embedded preview (PNG, some DNG): derive from the full preview,
        // unless the file is huge (a 130 MB HDR DNG exists); that one waits for selection.
        guard ((e.primary ?? e.raw)?.size ?? 0) <= Self.maxAutoDownload, let d = await fullPreview(for: e) else { return nil }
        return ImageCoding.downsample(d, maxPixel: Self.thumbPixels)
    }

    // MARK: Previews

    /// Best quick preview: cached full preview, else the embedded PRVW, else the thumbnail.
    public func quickPreview(for e: PhotoEntry) async -> Data? {
        if let key = e.contentKey, let d = await previews.data(for: key) { return d }
        if Task.isCancelled { return nil }
        if let raw = e.raw, let r = raw.previewRange, raw.previewLength ?? 0 >= Self.largeEmbeddedPreview,
           let d = try? await fs.read(raw.remotePath, offset: r.lowerBound, length: Int(r.upperBound - r.lowerBound)),
           let img = ImageCoding.downsample(d, maxPixel: Self.previewPixels, orientation: raw.orientation) {
            return ImageCoding.jpegData(img, quality: 0.85)
        }
        return await thumbnail(for: e)
    }

    /// Full-quality preview (~2560 px) from the primary JPEG (or the RAW when
    /// there's no JPEG). Also upgrades a low-res thumbnail.
    public func fullPreview(for e: PhotoEntry) async -> Data? {
        guard let key = e.contentKey else { return nil }
        if let d = await previews.data(for: key) { return d }
        if Task.isCancelled { return nil }
        return await shared("p:" + key) { [self] in
            guard let f = e.primary ?? e.raw,
                  let d = try? await fs.read(f.remotePath, offset: 0, length: Int(f.size)),
                  let img = ImageCoding.downsample(d, maxPixel: Self.previewPixels),
                  let jpeg = ImageCoding.jpegData(img, quality: 0.85) else { return nil }
            await previews.store(jpeg, for: key)
            // Replace a thumbnail that came from a ~160 px embedded thumb.
            let smallThumbOnly = [e.raw, e.primary].compactMap { $0 }.allSatisfy { ($0.previewLength ?? 0) < Self.largeEmbeddedPreview }
            if smallThumbOnly, let t = ImageCoding.downsample(jpeg, maxPixel: Self.thumbPixels), let tj = ImageCoding.jpegData(t) {
                await thumbs.store(tj, for: key)
            }
            return jpeg
        }
    }

    public func prefetchPreview(for e: PhotoEntry) async {
        guard let key = e.contentKey, await !previews.contains(key) else { return }
        await prefetchLimiter.run { _ = await self.fullPreview(for: e) }
    }

    private func shared(_ key: String, _ work: @escaping @Sendable () async -> Data?) async -> Data? {
        if let t = inflight[key] { return await t.value }
        let t = Task { await work() }
        inflight[key] = t
        let v = await t.value
        inflight[key] = nil
        return v
    }
}
