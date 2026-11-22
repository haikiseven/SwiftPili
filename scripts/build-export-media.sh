#!/bin/bash
# Export-only dependency build. No player artifacts, test targets or runners.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
export PATH="/opt/homebrew/bin:$PATH"
export TMPDIR="${TMPDIR:-/private/tmp}"
exec python3 "$ROOT/Packages/MediaExportNative/Configuration/build.py" "$@"
