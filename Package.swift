// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "SwiftPili",
    platforms: [
        .iOS(.v18)
    ],
    dependencies: [
        .package(url: "https://github.com/onevcat/Kingfisher.git", from: "8.1.0"),
        // Kept in sync with project.yml, which generates the actual app target.
        // A local checkout so the libVLC binary is one we build ourselves —
        // published releases ship a prebuilt xcframework without the AV1
        // VideoToolbox module or patches/libvlc/*.patch.
        .package(path: "../SwiftVLC"),
        .package(path: "Packages/PiliPlayerKit"),
        .package(path: "Packages/MediaExportNative"),
    ],
    targets: [
        .executableTarget(
            name: "SwiftPili",
            dependencies: [
                .product(name: "Kingfisher", package: "Kingfisher"),
                .product(name: "SwiftVLC", package: "SwiftVLC"),
                .product(name: "PiliPlayerEngine", package: "PiliPlayerKit"),
                .product(name: "MediaExportNative", package: "MediaExportNative"),
                .product(name: "LiveMediaDemux", package: "MediaExportNative"),
            ],
            path: "SwiftPili",
            exclude: [
                "Resources/Assets.xcassets",
                "Resources/Info.plist",
                "Resources/PrivacyInfo.xcprivacy",
                "Resources/SwiftPili.entitlements",
            ]
        ),
    ]
)
