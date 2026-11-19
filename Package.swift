// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "SilentLightTrackpad",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(url: "https://github.com/Kyome22/OpenMultitouchSupport.git", from: "4.0.0")
    ],
    targets: [
        // The click-decision engine, free of platform APIs so it can
        // be unit-tested frame by frame (Tests/LightClickCoreTests).
        .target(
            name: "LightClickCore",
            path: "Core"
        ),
        .executableTarget(
            name: "SilentLightTrackpad",
            dependencies: ["OpenMultitouchSupport", "LightClickCore"],
            path: "Sources"
        ),
        .testTarget(
            name: "LightClickCoreTests",
            dependencies: ["LightClickCore"],
            path: "Tests/LightClickCoreTests"
        )
    ]
)
