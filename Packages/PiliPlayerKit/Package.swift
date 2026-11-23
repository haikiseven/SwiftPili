// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "PiliPlayerKit",
    platforms: [
        .iOS(.v18),
        .macOS(.v13)
    ],
    products: [
        .library(
            name: "PiliPlayerEngine",
            targets: ["PiliPlayerEngine"]
        )
    ],
    targets: [
        .target(
            name: "PiliPlayerCore",
            path: "Sources/PiliPlayerCore"
        ),
        .target(
            name: "PiliPlayerMedia",
            dependencies: ["PiliPlayerCore"],
            path: "Sources/PiliPlayerMedia"
        ),
        .target(
            name: "PiliPlayerApple",
            dependencies: ["PiliPlayerCore", "PiliPlayerMedia"],
            path: "Sources/PiliPlayerApple"
        ),
        .target(
            name: "PiliPlayerEngine",
            dependencies: ["PiliPlayerCore", "PiliPlayerMedia", "PiliPlayerApple"],
            path: "Sources/PiliPlayerEngine"
        ),
        .testTarget(
            name: "PiliPlayerEngineTests",
            dependencies: ["PiliPlayerEngine"],
            path: "Tests/PiliPlayerEngineTests"
        ),
    ]
)
