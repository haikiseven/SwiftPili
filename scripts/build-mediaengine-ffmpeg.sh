#!/usr/bin/env bash
# Path A A1b — demux-oriented FFmpeg for MediaEngine (NOT linked into the app yet).
#
# Why this script exists:
#   SwiftVLC's libvlc.a already exports avformat_* / avio_* symbols. Linking a
#   second raw libavformat.a into SwiftPili will fail with duplicate symbols.
#   Build a demux-only FFmpeg and prefix every exported symbol with `me_` so it
#   can coexist with libvlc later.
#
# Hard rules:
#   - Never link macOS Libraries/local (LC_VERSION_MIN_MACOSX) into the iOS app.
#   - Do NOT enable MEDIA_ENGINE_FFMPEG / ship FFmpegMediaDemuxer body until:
#       1) ios-arm64 + sim archives exist
#       2) symbols are prefixed (nm | grep me_avformat)
#       3) otool/vtool shows iOS platform, not macOS
#       4) dual-link with SwiftVLC is verified on a throwaway branch
#
# Usage:
#   ./scripts/build-mediaengine-ffmpeg.sh /path/to/ffmpeg-src [out-dir]
#
# This script is documentation + scaffolding. It does not modify the Xcode
# project or enable MEDIA_ENGINE_FFMPEG.

set -euo pipefail

FFMPEG_SRC="${1:-}"
OUT_DIR="${2:-$(pwd)/build/mediaengine-ffmpeg}"
PREFIX_SYMBOL="me_"

if [[ -z "${FFMPEG_SRC}" || ! -d "${FFMPEG_SRC}" ]]; then
  cat <<'EOF'
Path A A1b — demux-only FFmpeg build (symbol-prefixed)

Usage:
  ./scripts/build-mediaengine-ffmpeg.sh /path/to/ffmpeg-src [out-dir]

Requirements:
  - Xcode + iOS SDK
  - llvm-objcopy or binutils objcopy that supports --prefix-symbols
  - FFmpeg source tree (n6.x / n7.x recommended)

What this will produce (when fully implemented on a build machine):
  out-dir/
    ios-arm64/lib/libavformat.a  (+ avutil / avcodec deps as needed)
    ios-arm64-simulator/lib/...
    (optional) MediaEngineFFmpeg.xcframework

Symbol prefix:
  After configure/make, run:
    llvm-objcopy --prefix-symbols=me_ libavformat.a
    llvm-objcopy --prefix-symbols=me_ libavutil.a
  so exports become me_avformat_open_input, etc. A thin C shim maps
  me_* back for FFmpegMediaDemuxer only.

Do NOT enable MEDIA_ENGINE_FFMPEG until verify:
  - otool -l libavformat.a | grep -E 'platform|MIN_MACOSX|IOS'  → iOS only
  - nm -gU libavformat.a | head  → me_av* symbols, no bare avformat_open_input
  - link smoke test with SwiftVLC present (no duplicate avformat_open_input)

Configure sketch (demux-oriented, no encoders as product default):

  ./configure \
    --enable-static --disable-shared \
    --disable-programs --disable-doc \
    --disable-avdevice --disable-swscale --disable-swresample \
    --disable-filters --disable-encoders --disable-muxers \
    --enable-demuxers --enable-parsers --enable-decoders \
    --enable-protocol=file,http,https,tls,tcp \
    --arch=aarch64 --target-os=darwin \
    --sysroot=$(xcrun --sdk iphoneos --show-sdk-path) \
    --extra-cflags="-arch arm64 -mios-version-min=15.0" \
    --extra-ldflags="-arch arm64 -mios-version-min=15.0" \
    --prefix=OUT/ios-arm64

  Repeat for iphonesimulator.

Never use:
  Libraries/local/lib/*.a from a macOS host FFmpeg install.

EOF
  exit 1
fi

echo "=== MediaEngine FFmpeg build scaffold ==="
echo "src:     ${FFMPEG_SRC}"
echo "out:     ${OUT_DIR}"
echo "prefix:  ${PREFIX_SYMBOL}"
echo
echo "This repo ships the script as a gate document. Full cross-compile is"
echo "machine-specific; implement the configure/make/objcopy steps above on a"
echo "Mac with the iOS SDK, then keep MEDIA_ENGINE_FFMPEG off until verify."
echo
echo "REFUSING to auto-link into SwiftPili. Exiting 0 after printing plan."
mkdir -p "${OUT_DIR}"
cat > "${OUT_DIR}/README-A1b.txt" <<EOF
MediaEngine FFmpeg out dir (A1b)
Generated: $(date -u +%Y-%m-%dT%H:%MZ)
Source: ${FFMPEG_SRC}
Symbol prefix: ${PREFIX_SYMBOL}

Do not enable MEDIA_ENGINE_FFMPEG until:
  1. ios-arm64 + sim static libs built
  2. objcopy --prefix-symbols=${PREFIX_SYMBOL} applied
  3. platform is iOS (not LC_VERSION_MIN_MACOSX)
  4. dual-link with libvlc verified
EOF
echo "Wrote ${OUT_DIR}/README-A1b.txt"
echo "Done (scaffold only)."
