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
        .library(name: "SyncEngine", targets: ["SyncEngine"]),
        .library(name: "StickiesSyncKit", targets: ["StickiesSyncKit"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0"),
    ],
    targets: [
        .target(name: "StickiesFormat"),
        .target(name: "StickiesStore", dependencies: ["StickiesFormat"]),
        // Deliberately does NOT depend on StickiesStore: the engine replicates
        // notes and must not learn what a Mac or a network is.
        .target(name: "SyncEngine", dependencies: ["StickiesFormat"]),
        // The composition root, and the only place the store and the engine
        // meet. Everything below it stays ignorant of the other half.
        .target(name: "StickiesSyncKit", dependencies: ["StickiesFormat", "StickiesStore", "SyncEngine"]),
        .executableTarget(
            name: "stickiesctl",
            dependencies: [
                "StickiesFormat",
                "StickiesStore",
                "SyncEngine",
                "StickiesSyncKit",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .testTarget(
            name: "StickiesFormatTests",
            dependencies: ["StickiesFormat"],
            // Golden files captured from a real Stickies container, copied
            // verbatim so a byte-for-byte comparison means something.
            resources: [.copy("Fixtures")]
        ),
        .testTarget(name: "StickiesStoreTests", dependencies: ["StickiesStore"]),
        .testTarget(name: "SyncEngineTests", dependencies: ["SyncEngine", "StickiesFormat"]),
        .testTarget(
            name: "StickiesSyncKitTests",
            dependencies: ["StickiesSyncKit", "StickiesStore", "SyncEngine", "StickiesFormat"]
        ),
    ]
)
