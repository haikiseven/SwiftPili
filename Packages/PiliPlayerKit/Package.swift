// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "PiliPlayerKit",
    platforms: [
        .iOS(.v18),
        // Duration is available from macOS 13 onward.
        .macOS(.v13)
    ],
    products: [
        // Core, Media, and Apple are implementation targets rather than App
        // products.  Keeping one product makes the App-facing import stable.
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
    ]
)
