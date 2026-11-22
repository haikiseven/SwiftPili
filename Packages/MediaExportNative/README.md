# MediaExportNative

The package contains a C export boundary for SwiftPili's downloaded local tracks
and a separate C demux boundary for Demand live playback. It does not
reuse playback sessions, shared libVLC instances, render surfaces or audio graphs.

`me_export_job_create` copies its input options/paths. One serial worker calls
probe, exact recipe capability admission, execute and finalized-output validation.
Another thread may request atomic cancellation. Destroy only after that worker
actually returns; callback context lives until execute returns. Native success
means streams/encoder/GPU/filter have drained and the MP4 trailer/output closed.
App owns source locks, job publication, disk budgeting, Files save and journal.

Build pinned device/simulator libraries (never tests or media execution):

```sh
scripts/build-export-media.sh --sdk iphoneos --arch arm64
scripts/build-export-media.sh --sdk iphonesimulator --arch arm64
scripts/build-export-media.sh --package-only
```

Archives must already exist under `build/export-media/sources/`, with pins from
`Configuration/sources.json`. Build-only host tools: Xcode, CMake, Meson, Ninja,
pkg-config, LLVM objcopy/nm, and Jinja2 in `build/export-media/venv`. This script
neither downloads arbitrary revisions nor executes a test runner. Generated
upstream adapters are confined to that generated source directory and recorded
in build.py. Library namespace transformation maps only dependency-owned defined
symbols and their references; system imports remain unchanged. Matching public
C header macros are generated from the same map.

`CMediaExport` propagates `-ObjC` to retain MoltenVK's Objective-C category-only
archive members. Opening the export sheet performs capability admission and
creates Vulkan samplers, which call `setBorderColorMVK:` before export starts.
An archive symbol audit is insufficient: for each final App Debug/Release build,
inspect the linked executable's Objective-C metadata (or `SwiftPili.debug.dylib`
when Debug uses a separate dylib) and confirm the
`MTLSamplerDescriptor (MoltenVK)` category, including `setBorderColorMVK:` and
`setLodBiasMVK:`, is registered in `__objc_catlist`. Verify the final App binary
intended for installation; presence in the dependency archive alone does not
prove runtime availability.

`Vendor/ExportMediaDependencies.xcframework` is generated, large binary output.
It is not automatically a source-controlled distribution artifact. Each platform
build stores a receipt, namespace map and actual configuration under
`build/export-media/<sdk>-<arch>/`. Rebuild after configuration/native changes;
App build evidence must use that final artifact. Intel simulator requires a
separate x86_64 build and combined simulator slice, not device-library reuse.

License texts and hashes are captured in Configuration/Licenses and
license-receipt.json. FFmpeg's GPL/nonfree options are disabled in the selected
build. This does not itself satisfy LGPL source, notice, modification/relink or
other native dependency redistribution requirements: a distribution owner must
provide the exact pinned sources, patches/configuration and required relink
materials, and review the complete dependency license closure. No release or
legal clearance is asserted here.

Build/static checks establish API and link consistency only. Original Dolby/HDR
metadata preservation, source timing/audio sync, AV1/Profile5 color conversion,
4K/VT resources require separate real
artifact/device acceptance. The App must not publish before native validation,
and must disclose transcode metadata changes rather than claim original Dolby
preservation. No automatic media/device checks are part of the build script.

## App integration recipe

The repository ignores runner-local `project.yml`. Apply `git apply --unidiff-zero Packages/MediaExportNative/Configuration/project-export-integration.patch` to the matching local recipe before `xcodegen generate`; it adds the local MediaExportNative package with the `MediaExportNative` and `LiveMediaDemux` products. For a recipe already using the export product, add `LiveMediaDemux` as a second dependency on the same package under the App target. The tracked App Package.swift mirrors the dependency. Do not rely on editing generated entitlements only, because XcodeGen overwrites them. Build Vendor/ExportMediaDependencies.xcframework with the pinned recipe before resolving the App project.
