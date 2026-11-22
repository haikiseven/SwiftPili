#!/usr/bin/env bash
# pick-simulator.sh — print the name of an available iPhone simulator.
#
# Used by .github/workflows/full-build.yml for the Debug build so the
# device name is never hard-coded (it changes every Xcode release: the repo was
# on iPhone 15 → 16 → 17 within a year).
#
# Exit: 0 + name on stdout, or 1 with a message on stderr.

set -uo pipefail

name="$(xcrun simctl list devices available -j 2>/dev/null | python3 -c '
import json, sys
try:
    devices = json.load(sys.stdin)["devices"]
except Exception:
    sys.exit(0)
best = None
for runtime in sorted(devices):
    if "iOS" not in runtime:
        continue
    for d in devices[runtime]:
        if d.get("isAvailable", True) and d.get("name", "").startswith("iPhone"):
            best = d["name"]
if best:
    print(best)
')"

if [ -z "$name" ]; then
  echo "no available iPhone simulator (check: xcrun simctl list devices available)" >&2
  exit 1
fi

printf '%s\n' "$name"
