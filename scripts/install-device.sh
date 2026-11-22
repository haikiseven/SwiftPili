#!/bin/bash
# Build and install onto the paired iPhone, in that ORDER.
#
# The order is the whole point. Building first and installing when the device
# shows up looks equivalent and is not: a build that fails while the device is
# unavailable leaves the PREVIOUS .app on disk, and an installer that only waits
# for the device will ship it without complaint. That happened — a capture came
# back missing a probe because the installed binary predated it by five minutes,
# and nothing in the report could say so. Waiting first means the build either
# succeeds against the connected device or nothing is installed at all.
#
# Usage: scripts/install-device.sh <coredevice-id-or-udid>
set -euo pipefail

DEVICE="${1:?Usage: scripts/install-device.sh <coredevice-id-or-udid>}"
DERIVED="build/device"
APP="$DERIVED/Build/Products/Debug-iphoneos/SwiftPili.app"
POLL_SECONDS=8
MAX_POLLS=225   # 30 minutes

name_and_state() {
    xcrun devicectl list devices 2>/dev/null | grep "$DEVICE" || true
}

echo "waiting for device $DEVICE ..."
for ((i = 1; i <= MAX_POLLS; i++)); do
    if name_and_state | grep -q "available (paired)"; then
        echo "device available after $i poll(s)"
        break
    fi
    if ((i == MAX_POLLS)); then
        echo "TIMED OUT waiting for the device (unlock it and re-run)" >&2
        exit 1
    fi
    sleep "$POLL_SECONDS"
done

# Removed BEFORE the build so a failure cannot leave a stale bundle behind for
# some later run to install. Belt as well as braces: the ordering above already
# prevents it, this makes a stale artifact impossible rather than unlikely.
rm -rf "$APP"

echo "building ..."
xcodebuild build \
    -project SwiftPili.xcodeproj \
    -scheme SwiftPili \
    -destination "platform=iOS,id=$DEVICE" \
    -derivedDataPath "$DERIVED" \
    -quiet

[ -d "$APP" ] || { echo "build produced no app bundle at $APP" >&2; exit 1; }

echo "installing $(stat -f '%Sm' "$APP/SwiftPili") ..."
xcrun devicectl device install app --device "$DEVICE" "$APP"
echo "installed from $(git rev-parse --short HEAD)"
