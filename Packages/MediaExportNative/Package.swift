// swift-tools-version: 6.0
import PackageDescription

let nativeLinkerSettings: [LinkerSetting] = [
    // Load MoltenVK category-only archive members, including setBorderColorMVK:.
    .unsafeFlags(["-ObjC"]),
    .linkedFramework("VideoToolbox"), .linkedFramework("CoreMedia"),
    .linkedFramework("CoreVideo"), .linkedFramework("Metal"),
    .linkedFramework("Foundation"), .linkedFramework("IOSurface"),
    .linkedLibrary("c++"), .linkedLibrary("z"), .linkedLibrary("bz2"),
    .linkedLibrary("iconv"),
]

let package = Package(
    name: "MediaExportNative",
    platforms: [.iOS(.v18)],
    products: [
        .library(name: "MediaExportNative", targets: ["CMediaExport"]),
        .library(name: "LiveMediaDemux", targets: ["CLiveMediaDemux"]),
    ],
    targets: [
        .binaryTarget(name: "ExportMediaDependencies", path: "Vendor/ExportMediaDependencies.xcframework"),
        .target(name: "CMediaExport", dependencies: ["ExportMediaDependencies"],
                publicHeadersPath: "include", linkerSettings: nativeLinkerSettings),
        .target(name: "CLiveMediaDemux", dependencies: ["ExportMediaDependencies"],
                publicHeadersPath: "include", linkerSettings: nativeLinkerSettings),
    ]
)
