# SwiftPili

A native iOS & iPadOS 18+ BiliBili client built with Swift 6, SwiftUI/UIKit, and a dual-engine media stack (custom Demand-paced AV/VideoToolbox engine + patched libVLC via SwiftVLC).

## Requirements

- macOS with Xcode 16+ (iOS 18.0+ deployment target, Swift 6 strict concurrency)
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`)
- [SwiftLint](https://github.com/realm/SwiftLint) (`brew install swiftlint`)

## Quick Start

### 1. Local `SwiftVLC` sibling checkout

`project.yml` and `Package.swift` depend on a local sibling checkout at `../SwiftVLC` so the app builds against the patched `libvlc.xcframework` (including VideoToolbox AV1 and clock/drain fixes under `patches/`).

```bash
git clone https://github.com/haikiseven/SwiftVLC.git ../SwiftVLC
./patches/apply.sh ../SwiftVLC
```

### 2. Native XCFramework dependencies (`libvlc` + `ExportMediaDependencies`)

**Fast path (recommended for contributors):** download the pinned, SHA-256-verified prebuilt XCFrameworks from the `deps-v1` release (uses `gh` or `curl`):

```bash
./scripts/fetch-prebuilt-deps.sh
```

**Build from source (optional):** build `Vendor/libvlc.xcframework` inside `../SwiftVLC` (see `patches/libvlc/README.md`), and build `Packages/MediaExportNative/Vendor/ExportMediaDependencies.xcframework` (see `Packages/MediaExportNative/README.md`):

```bash
./scripts/build-export-media.sh --sdk iphoneos --arch arm64
./scripts/build-export-media.sh --sdk iphonesimulator --arch arm64
./scripts/build-export-media.sh --package-only
```

### 3. Configure local code signing

`project.yml` uses automatic signing with an empty `DEVELOPMENT_TEAM` via `Configuration/Signing.xcconfig`, which optionally includes a gitignored `LocalSigning.xcconfig` at the repository root:

```bash
cp LocalSigning.xcconfig.example LocalSigning.xcconfig
# Edit LocalSigning.xcconfig and set your DEVELOPMENT_TEAM (and optional PRODUCT_BUNDLE_IDENTIFIER)
```

### 4. Generate the Xcode project and build

```bash
xcodegen generate
open SwiftPili.xcodeproj
```

Or build from the command line for an iOS Simulator:

```bash
DEVICE="$(./scripts/pick-simulator.sh)"
xcodebuild build \
  -project SwiftPili.xcodeproj \
  -scheme SwiftPili \
  -configuration Debug \
  -destination "platform=iOS Simulator,name=$DEVICE" \
  CODE_SIGNING_ALLOWED=NO
```

## Repository Structure

- `SwiftPili/App/` — App lifecycle, root shell, orientation & window management
- `SwiftPili/Navigation/` — Route coordinator and deep-link parsing
- `SwiftPili/Core/` — Networking, WBI signing, auth/Keychain, SwiftData storage, utilities
- `SwiftPili/SharedUI/` — Reusable UIKit/SwiftUI components, feed collections, pure UIKit image viewer, design tokens
- `SwiftPili/Player/` — Demand-paced playback engine, demux/decode/render pipeline, VLC backend, controls
- `SwiftPili/Features/` — Home, Video, Bangumi, Live, Dynamics, Messages, Search, Articles, Music, Mine
- `Packages/PiliPlayerKit/` — Extracted SwiftPM player core/media/Apple/engine modules
- `Packages/MediaExportNative/` — Native C/FFmpeg media export and live TS/FLV demux bridge
- `patches/` — Ordered `libvlc` and `SwiftVLC` patches + verification scripts
- `scripts/` — Build helpers and local CI gates
- `Design/` — App icon export tooling

## Local Quality Gates

Run before opening a pull request:

```bash
./scripts/check-swiftlint-ratchet.sh
./scripts/check-design-tokens-ratchet.sh
./scripts/check-player-package-boundaries.sh
./scripts/check-audio-clock-ownership.sh
./patches/libvlc/verify/check-apply-matrix.sh
```

## CI & Automatic IPA Releases

- **Hosted Linux gates** (`offline-gates.yml`, `player-package.yml`, `swiftlint-ratchet.yml`): run on every push and pull request.
- **Release IPA workflow** (`full-build.yml`, `macos-26`):
  - Pushing to `main` builds an unsigned Release `.ipa` and updates the rolling **`nightly`** pre-release (`SwiftPili.ipa` + `SwiftPili.ipa.sha256`).
  - Pushing a `v*` tag (e.g. `v1.0.0` or `v1.1.0-beta.1`) publishes a versioned GitHub Release (`SwiftPili-<tag>.ipa`).
  - Manual `workflow_dispatch` supports optional Debug Simulator builds (`run_debug_build`) and optional `nightly` publishing (`publish_release`).

## License

SwiftPili is licensed under the [GNU General Public License v3.0](LICENSE).
