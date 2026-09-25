// Throwaway spike (plan Phase 0b): Citadel connect/list/read benchmarks.
// Usage: CitadelSFTP <host> <user> <keyfile> "<pinned host pubkey line>"
import Citadel
import Crypto
import Foundation
import NIOCore
import NIOSSH

let a = CommandLine.arguments
let (host, user, keyPath, pinned) = (a[1], a[2], a[3], a[4])
let key = try Curve25519.Signing.PrivateKey(sshEd25519: String(contentsOfFile: keyPath, encoding: .utf8))
let auth = { SSHAuthenticationMethod.ed25519(username: user, privateKey: key) }

func time<T>(_ label: String, _ body: () async throws -> T) async rethrows -> T {
    let t0 = ContinuousClock.now
    let r = try await body()
    let ms = (ContinuousClock.now - t0) / .milliseconds(1)
    print(String(format: "%-48@ %9.1f ms", label as NSString, ms))
    return r
}

// 1. Host key pinning: wrong key must be rejected, right key accepted.
let wrongKey = NIOSSHPrivateKey(ed25519Key: Curve25519.Signing.PrivateKey()).publicKey
do {
    _ = try await SSHClient.connect(host: host, authenticationMethod: auth(),
                                    hostKeyValidator: .trustedKeys([wrongKey]), reconnect: .never)
    print("PIN FAIL: connected with wrong host key!")
} catch {
    print("pin: wrong host key rejected (\(type(of: error)))")
}
let pinnedKey = try NIOSSHPublicKey(openSSHPublicKey: pinned)
let client = try await time("connect (pinned host key)") {
    try await SSHClient.connect(host: host, authenticationMethod: auth(),
                                hostKeyValidator: .trustedKeys([pinnedKey]), reconnect: .never)
}
let sftp = try await time("open SFTP channel") { try await client.openSFTP() }

// 2. Listing.
var files: [(path: String, size: UInt64)] = []
for dir in ["canon-r7/later-fix", "canon-r7/earlier"] {
    let names = try await time("list \(dir)") { try await sftp.listDirectory(atPath: dir) }
    let comps = names.flatMap(\.components).filter { !$0.filename.hasPrefix(".") }
    print("  \(comps.count) entries; sample mtime=\(String(describing: comps.first?.attributes.accessModificationTime?.modificationTime))")
    files += comps.filter { $0.filename.uppercased().hasSuffix(".CR3") }
        .map { ("\(dir)/\($0.filename)", $0.attributes.size ?? 0) }
}
let sample = Array(files.prefix(64))

func head(_ c: SFTPClient, _ path: String, _ len: UInt32) async throws -> Int {
    let f = try await c.openFile(filePath: path, flags: .read)
    let buf = try await f.read(from: 0, length: len)
    try await f.close()
    return buf.readableBytes
}

// 3. Header reads.
_ = try await time("64 KB head x32, sequential") {
    for f in sample.prefix(32) { _ = try await head(sftp, f.path, 65536) }
}
_ = try await time("64 KB head x32, 8 concurrent") {
    try await withThrowingTaskGroup(of: Int.self) { g in
        var it = sample.suffix(32).makeIterator(), inflight = 0
        while let f = it.next() {
            if inflight == 8 { _ = try await g.next(); inflight -= 1 }
            g.addTask { try await head(sftp, f.path, 65536) }; inflight += 1
        }
        try await g.waitForAll()
    }
}
let got = try await time("PRVW-sized read (320 KB) x1") { try await head(sftp, sample[0].path, 320_000) }
print("  single read(length:320000) returned \(got) bytes")

// 4. Full-file download.
func download(_ c: SFTPClient, _ path: String, size: UInt64, chunk: UInt32, depth: Int) async throws -> Int {
    let f = try await c.openFile(filePath: path, flags: .read)
    defer { Task { try? await f.close() } }
    let offsets = stride(from: UInt64(0), to: size, by: Int(chunk)).map { $0 }
    var total = 0
    try await withThrowingTaskGroup(of: Int.self) { g in
        var it = offsets.makeIterator(), inflight = 0
        while let off = it.next() {
            if inflight == depth { total += try await g.next()!; inflight -= 1 }
            g.addTask {
                // Server may return short reads; loop until the chunk is filled.
                var got = 0
                while UInt64(got) < min(UInt64(chunk), size - off) {
                    let b = try await f.read(from: off + UInt64(got), length: chunk - UInt32(got))
                    if b.readableBytes == 0 { break }
                    got += b.readableBytes
                }
                return got
            }
            inflight += 1
        }
        for try await n in g { total += n }
    }
    return total
}
let big = files.max { $0.size < $1.size }!
print("full download target: \(big.path) \(big.size) bytes")
for (chunk, depth) in [(UInt32(32_768), 1), (262_144, 1), (262_144, 8), (262_144, 16), (1_048_576, 8)] {
    let t0 = ContinuousClock.now
    let n = try await download(sftp, big.path, size: big.size, chunk: chunk, depth: depth)
    let s = Double((ContinuousClock.now - t0) / .milliseconds(1)) / 1000
    print(String(format: "download chunk=%7d depth=%2d  %6.2f s  %6.1f MB/s  (%d bytes)", chunk, depth, s, Double(n) / s / 1e6, n))
}

// 5. Lanes: header latency on channel B while channel A downloads.
let sftpB = try await client.openSFTP()
let dl = Task { try await download(sftp, big.path, size: big.size, chunk: 262_144, depth: 16) }
try await Task.sleep(for: .milliseconds(100))
_ = try await time("64 KB head x16 on lane B during lane A download") {
    for f in sample.prefix(16) { _ = try await head(sftpB, f.path, 65536) }
}
_ = try await dl.value
_ = try await time("64 KB head x16 on lane B, idle") {
    for f in sample.prefix(16) { _ = try await head(sftpB, f.path, 65536) }
}
try await client.close()
print("done")
