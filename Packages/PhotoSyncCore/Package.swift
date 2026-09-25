// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "PhotoSyncCore",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "PhotoSyncCore", targets: ["PhotoSyncCore"]),
        .executable(name: "photosync-cli", targets: ["photosync-cli"]),
    ],
    dependencies: [
        // Pinned exactly: Citadel's API shifts between minor versions (plan flag 10).
        .package(url: "https://github.com/orlandos-nl/Citadel.git", exact: "0.12.1"),
        .package(url: "https://github.com/groue/GRDB.swift.git", exact: "7.11.1"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.5.0"),
    ],
    targets: [
        .target(
            name: "PhotoSyncCore",
            dependencies: [
                .product(name: "Citadel", package: "Citadel"),
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "Logging", package: "swift-log"),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "photosync-cli",
            dependencies: ["PhotoSyncCore", .product(name: "GRDB", package: "GRDB.swift")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "PhotoSyncCoreTests",
            dependencies: ["PhotoSyncCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
