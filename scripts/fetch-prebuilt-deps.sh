#!/usr/bin/env bash
# Download and SHA-256-verify the pinned prebuilt native XCFrameworks from a
# SwiftPili GitHub Release (default: deps-v1).
#
# Used by both GitHub Actions (full-build.yml) and contributors who want a
# ready-to-build tree without compiling libVLC and FFmpeg from source.
#
# Usage:
#   ./scripts/fetch-prebuilt-deps.sh [--repo OWNER/REPO] [--tag TAG] [--swiftvlc PATH] [--force]
#
# Requires: unzip, shasum/sha256sum, and either `gh` or `curl`.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$HERE/.." && pwd)"

REPO="${GITHUB_REPOSITORY:-haikiseven/SwiftPili}"
TAG="deps-v1"
SWIFTVLC_DIR="${REPO_ROOT}/../SwiftVLC"
FORCE=0

LIBVLC_ASSET="libvlc.xcframework.zip"
LIBVLC_SHA256="8dbfb5be45354167601bead4fc4e7818ab8b8fa9fda0a5c268ab5b9dc056efac"

EXPORT_ASSET="ExportMediaDependencies.xcframework.zip"
EXPORT_SHA256="019e54cdf2fdd86c5b5c6b74be935da83c25ad27b2eecdcecc28e9a4c6ff002c"

while [ $# -gt 0 ]; do
  case "$1" in
    --repo)
      REPO="${2:?missing value for --repo}"; shift 2 ;;
    --tag)
      TAG="${2:?missing value for --tag}"; shift 2 ;;
    --swiftvlc)
      SWIFTVLC_DIR="${2:?missing value for --swiftvlc}"; shift 2 ;;
    --force)
      FORCE=1; shift ;;
    -h|--help)
      sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *)
      echo "ERROR: unknown argument: $1" >&2
      exit 2 ;;
  esac
done

command -v unzip >/dev/null 2>&1 || { echo "ERROR: unzip is required" >&2; exit 1; }

sha256_of() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    sha256sum "$1" | awk '{print $1}'
  fi
}

download_asset() {
  local asset="$1"
  local dest="$2"
  if command -v gh >/dev/null 2>&1 && { [ -n "${GH_TOKEN:-}" ] || gh auth status >/dev/null 2>&1; }; then
    gh release download "$TAG" \
      --repo "$REPO" \
      --pattern "$asset" \
      --dir "$(dirname "$dest")" \
      --clobber
  elif command -v curl >/dev/null 2>&1; then
    curl --fail --location --silent --show-error \
      --output "$dest" \
      "https://github.com/${REPO}/releases/download/${TAG}/${asset}"
  else
    echo "ERROR: either gh or curl is required to download release assets" >&2
    exit 1
  fi
}

if [ ! -d "$SWIFTVLC_DIR" ]; then
  echo "ERROR: SwiftVLC checkout not found at $SWIFTVLC_DIR" >&2
  echo "Clone https://github.com/haikiseven/SwiftVLC.git there and run ./patches/apply.sh first." >&2
  exit 1
fi

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/swiftpili-deps.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT

install_xcframework() {
  local asset="$1"
  local expected_sha="$2"
  local vendor_dir="$3"
  local framework_name="$4"
  local stamp_file="${vendor_dir}/.${framework_name}.sha256"
  local target_path="${vendor_dir}/${framework_name}"

  mkdir -p "$vendor_dir"

  if [ "$FORCE" -eq 0 ] \
    && [ -f "${target_path}/Info.plist" ] \
    && [ -f "$stamp_file" ] \
    && [ "$(cat "$stamp_file")" = "$expected_sha" ]; then
    echo "OK   ${framework_name} already matches pinned sha256 (${expected_sha:0:12})"
    return 0
  fi

  local zip_path="${TMP_DIR}/${asset}"
  echo "DL   ${asset} from ${REPO}@${TAG}"
  download_asset "$asset" "$zip_path"

  local actual_sha
  actual_sha="$(sha256_of "$zip_path")"
  if [ "$actual_sha" != "$expected_sha" ]; then
    echo "ERROR: SHA-256 mismatch for ${asset}" >&2
    echo "  expected: ${expected_sha}" >&2
    echo "  actual:   ${actual_sha}" >&2
    exit 1
  fi
  echo "OK   verified sha256 (${actual_sha:0:12}) for ${asset}"

  local stage_dir="${TMP_DIR}/extract-${framework_name}"
  mkdir -p "$stage_dir"
  unzip -q "$zip_path" -d "$stage_dir"

  if [ ! -f "${stage_dir}/${framework_name}/Info.plist" ]; then
    echo "ERROR: ${asset} did not extract ${framework_name}/Info.plist" >&2
    exit 1
  fi

  rm -rf "$target_path"
  mv "${stage_dir}/${framework_name}" "$target_path"
  printf '%s\n' "$expected_sha" > "$stamp_file"
  echo "OK   installed ${target_path}"
}

install_xcframework \
  "$LIBVLC_ASSET" \
  "$LIBVLC_SHA256" \
  "${SWIFTVLC_DIR}/Vendor" \
  "libvlc.xcframework"

install_xcframework \
  "$EXPORT_ASSET" \
  "$EXPORT_SHA256" \
  "${REPO_ROOT}/Packages/MediaExportNative/Vendor" \
  "ExportMediaDependencies.xcframework"
