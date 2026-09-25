import Foundation

/// Debug builds log every asset they create so testing against her real
/// library can always be reversed (plan: "Testing against her library").
public struct TestLedger: Sendable {
    public let url: URL

    public init(url: URL) { self.url = url }

    public func ids() -> [String] {
        (try? JSONDecoder().decode([String].self, from: Data(contentsOf: url))) ?? []
    }

    public func append(_ id: String) {
        write(ids() + [id])
    }

    public func clear() { write([]) }

    private func write(_ ids: [String]) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(ids).write(to: url, options: .atomic)
    }
}
