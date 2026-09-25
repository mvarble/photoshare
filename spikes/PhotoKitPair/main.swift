// Throwaway spike (plan Phase 0a): import one RAW+JPEG pair as a single Photos
// asset, inspect its resources, and revert via a ledger.
// Usage (via `open -W -a PhotoKitPair.app --args <mode> <outfile> ...`):
//   import <outfile> <jpg> <raw>   verify <outfile>   revert <outfile>
import AppKit
import Photos
import UniformTypeIdentifiers

let args = CommandLine.arguments
let mode = args.count > 1 ? args[1] : "verify"
let outURL = URL(fileURLWithPath: args.count > 2 ? args[2] : "/dev/null")
let supportDir = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/PhotoSync")
let ledgerURL = supportDir.appendingPathComponent("test-ledger.json")

var log = ""
func say(_ s: String) { log += s + "\n" }

func readLedger() -> [String] {
    (try? JSONDecoder().decode([String].self, from: Data(contentsOf: ledgerURL))) ?? []
}
func writeLedger(_ ids: [String]) throws {
    try FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)
    try JSONEncoder().encode(ids).write(to: ledgerURL)
}

func describe(_ ids: [String]) {
    let assets = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)
    say("found \(assets.count) of \(ids.count) ledger assets")
    assets.enumerateObjects { asset, _, _ in
        say("asset \(asset.localIdentifier) \(asset.pixelWidth)x\(asset.pixelHeight) created=\(String(describing: asset.creationDate))")
        for r in PHAssetResource.assetResources(for: asset) {
            say("  resource type=\(r.type.rawValue) name=\(r.originalFilename) uti=\(r.uniformTypeIdentifier)")
        }
    }
}

func run() async throws {
    let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
    say("authorization=\(status.rawValue) (3 = authorized)")
    guard status == .authorized else { return }

    switch mode {
    case "import":
        let jpg = URL(fileURLWithPath: args[3]), raw = URL(fileURLWithPath: args[4])
        var newID: String?
        try await PHPhotoLibrary.shared().performChanges {
            let req = PHAssetCreationRequest.forAsset()
            let jo = PHAssetResourceCreationOptions()
            jo.originalFilename = jpg.lastPathComponent
            jo.uniformTypeIdentifier = UTType.jpeg.identifier
            req.addResource(with: .photo, fileURL: jpg, options: jo)
            let ro = PHAssetResourceCreationOptions()
            ro.originalFilename = raw.lastPathComponent
            ro.uniformTypeIdentifier = UTType(filenameExtension: raw.pathExtension)?.identifier
            req.addResource(with: .alternatePhoto, fileURL: raw, options: ro)
            newID = req.placeholderForCreatedAsset?.localIdentifier
        }
        guard let newID else { say("no placeholder id"); return }
        try writeLedger(readLedger() + [newID])
        say("imported \(newID)")
        describe([newID])
    case "verify":
        describe(readLedger())
    case "revert":
        let ids = readLedger()
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)
        if assets.count > 0 {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.deleteAssets(assets)
            }
        }
        try writeLedger([])
        say("deleted \(assets.count) asset(s); ledger cleared")
    default:
        say("unknown mode \(mode)")
    }
}

NSApplication.shared.setActivationPolicy(.regular)
Task {
    do { try await run() } catch { say("ERROR: \(error)") }
    try? log.write(to: outURL, atomically: true, encoding: .utf8)
    exit(0)
}
NSApplication.shared.run()
