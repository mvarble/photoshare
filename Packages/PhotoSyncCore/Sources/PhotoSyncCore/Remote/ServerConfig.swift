import Foundation

/// Connection settings entered once during setup.
public struct ServerConfig: Codable, Sendable, Equatable {
    public var host: String
    public var port: Int
    public var username: String
    /// Remote directories to scan, e.g. ["canon-r7"]. "." means the login directory.
    public var roots: [String]
    /// OpenSSH-format host key, pinned on first successful connect (trust on first use).
    public var pinnedHostKey: String?

    public init(host: String, port: Int = 22, username: String, roots: [String], pinnedHostKey: String? = nil) {
        self.host = host
        self.port = port
        self.username = username
        self.roots = roots
        self.pinnedHostKey = pinnedHostKey
    }
}

public struct ConfigStore: Sendable {
    public let url: URL

    public init(url: URL) { self.url = url }

    public func load() -> ServerConfig? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(ServerConfig.self, from: data)
    }

    public func save(_ config: ServerConfig) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(config).write(to: url, options: .atomic)
    }
}
