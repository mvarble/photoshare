// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "CitadelSFTP",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(url: "https://github.com/orlandos-nl/Citadel.git", exact: "0.12.1"),
    ],
    targets: [
        .executableTarget(
            name: "CitadelSFTP",
            dependencies: [.product(name: "Citadel", package: "Citadel")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
