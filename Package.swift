// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "SilentLightTrackpad",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(path: "Vendor/OpenMultitouchSupport")
    ],
    targets: [
        .executableTarget(
            name: "SilentLightTrackpad",
            dependencies: ["OpenMultitouchSupport"],
            path: "Sources"
        )
    ]
)
