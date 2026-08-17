// swift-tools-version: 6.1
import PackageDescription

// Deployment target is macOS 14, but only macOS 26.6.1 has been verified against
// the real Stickies format — see the compatibility note in ARCHITECTURE.md.
let package = Package(
    name: "StickiesSync",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "stickiesctl", targets: ["stickiesctl"]),
        .library(name: "StickiesFormat", targets: ["StickiesFormat"]),
        .library(name: "StickiesStore", targets: ["StickiesStore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0"),
    ],
    targets: [
        .target(name: "StickiesFormat"),
        .target(name: "StickiesStore", dependencies: ["StickiesFormat"]),
        .executableTarget(
            name: "stickiesctl",
            dependencies: [
                "StickiesFormat",
                "StickiesStore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .testTarget(name: "StickiesFormatTests", dependencies: ["StickiesFormat"]),
        .testTarget(name: "StickiesStoreTests", dependencies: ["StickiesStore"]),
    ]
)
