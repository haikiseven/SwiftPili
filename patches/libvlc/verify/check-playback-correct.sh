#!/usr/bin/env bash
# check-playback-correct.sh
#
# Offline O1 gate: refuse to claim a "playback-correct" tree unless the app
# depends on a *local* SwiftVLC checkout and the libVLC patch verify scripts
# are present (and optionally pass).
#
# Why this exists:
#   Published SwiftVLC releases ship a prebuilt xcframework and silently ignore
#   patches/libvlc/*.patch. A green Xcode build can therefore be missing every
#   F5/F14/F19/F20 patch. This script fails early when the dependency graph or
#   verify harness is wrong — full device soak remains separate.
#
# Usage:
#   ./patches/libvlc/verify/check-playback-correct.sh
#   ./patches/libvlc/verify/check-playback-correct.sh --swiftvlc ../SwiftVLC
#   ./patches/libvlc/verify/check-playback-correct.sh --vlc-tree ../SwiftVLC/scripts/.build-libvlc/vlc
#
# Exit:
#   0  local path dep + patch inventory/matrix OK (and check-applied if tree given)
#   1  not playback-correct (missing path dep, missing patches, matrix fail, …)
#   2  usage
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$HERE/../../.." && pwd)"
SWIFTVLC="$REPO_ROOT/../SwiftVLC"
VLC_TREE=""

while [ $# -gt 0 ]; do
  case "$1" in
    --swiftvlc)
      SWIFTVLC="${2:?}"; shift 2 ;;
    --vlc-tree)
      VLC_TREE="${2:?}"; shift 2 ;;
    -h|--help)
      sed -n '2,28p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    -*)
      echo "unknown option: $1" >&2
      exit 2
      ;;
    *)
      echo "usage: check-playback-correct.sh [--swiftvlc PATH] [--vlc-tree PATH]" >&2
      exit 2
      ;;
  esac
done

fail=0
ok()  { printf '  OK   %s\n' "$1"; }
bad() { printf '  FAIL %s\n' "$1"; fail=1; }

echo "=== O1 playback-correct prerequisites ==="

# 1) App must path-depend on local SwiftVLC (not a published version-only pin).
if [ -f "$REPO_ROOT/Package.swift" ] \
  && grep -qE '\.package\(path:\s*"\.\./SwiftVLC"\)' "$REPO_ROOT/Package.swift"; then
  ok "Package.swift path-depends on ../SwiftVLC"
else
  bad "Package.swift missing path: ../SwiftVLC — published xcframework would ignore patches"
fi

if [ -f "$REPO_ROOT/project.yml" ] \
  && grep -qE 'path:\s*\.\./SwiftVLC' "$REPO_ROOT/project.yml"; then
  ok "project.yml path-depends on ../SwiftVLC"
else
  bad "project.yml missing path: ../SwiftVLC"
fi

# 2) Sibling checkout must exist (otherwise Xcode resolves nothing useful).
if [ -d "$SWIFTVLC" ] && [ -f "$SWIFTVLC/Package.swift" -o -f "$SWIFTVLC/Package.resolved" -o -d "$SWIFTVLC/Sources" -o -f "$SWIFTVLC/scripts/build-libvlc.sh" ]; then
  ok "local SwiftVLC checkout present at $SWIFTVLC"
else
  bad "no local SwiftVLC at $SWIFTVLC — clone/build sibling before claiming playback-correct"
fi

# 3) Patch set + offline harness must exist.
PATCH_DIR="$REPO_ROOT/patches/libvlc"
if [ -d "$PATCH_DIR" ] && ls "$PATCH_DIR"/0012-*.patch >/dev/null 2>&1; then
  ok "patches/libvlc present (incl. 0012)"
else
  bad "patches/libvlc incomplete or missing"
fi

MATRIX="$HERE/check-apply-matrix.sh"
APPLIED="$HERE/check-applied.sh"
OWN="$HERE/check-filters-rate-ownership.sh"
for s in "$MATRIX" "$APPLIED" "$OWN"; do
  if [ -f "$s" ]; then
    ok "verify script present: $(basename "$s")"
  else
    bad "missing verify script: $s"
  fi
done

# 4) Always run offline matrix (static).
if [ -f "$MATRIX" ]; then
  echo
  echo "=== check-apply-matrix (static) ==="
  if bash "$MATRIX"; then
    ok "check-apply-matrix passed"
  else
    bad "check-apply-matrix failed — patch set not hygiene-clean"
  fi
fi

# 5) Optional: markers in a built VLC tree.
if [ -n "$VLC_TREE" ]; then
  echo
  echo "=== check-applied (built tree) ==="
  if [ ! -d "$VLC_TREE" ]; then
    bad "vlc tree not found: $VLC_TREE"
  elif bash "$APPLIED" "$VLC_TREE"; then
    ok "check-applied passed on $VLC_TREE"
  else
    bad "check-applied failed — binary/tree missing required patch markers"
  fi
else
  echo
  printf '  skip check-applied (pass --vlc-tree PATH after build-libvlc)\n'
fi

echo
if [ "$fail" = 0 ]; then
  echo "PASS playback-correct prerequisites (device soak still required for F20/P4.3)"
  exit 0
fi
echo "FAIL not playback-correct — fix path dep / patches / verify before claiming media fixes"
exit 1
