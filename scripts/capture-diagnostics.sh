#!/usr/bin/env bash
#
# Capture SwiftPili player diagnostics from a device WITHOUT Xcode.
#
# Why this exists
# ---------------
# Scraping the Xcode console gives you the whole firehose and nothing to grep
# for. `PlayerLog.diagnostic(...)` writes to a dedicated os_log category
# ("Diagnostic") at `.error` level, which buys two things:
#
#   1. Filterable  — one predicate returns ONLY the post-mortem lines.
#   2. Persistent  — `.error` and `.fault` go to the on-disk log store, so they
#                    survive app termination and can be recovered AFTER the
#                    fact. You do not have to be streaming when it breaks.
#
# Property (2) is the important one: `collect` and `sysdiagnose` below both
# work on a failure that already happened.
#
# Usage
# -----
#   scripts/capture-diagnostics.sh stream  [--all] [--device UDID]
#   scripts/capture-diagnostics.sh collect [--all] [--device UDID] [--last 30m]
#   scripts/capture-diagnostics.sh archive <path.logarchive|sysdiagnose.tar.gz> [--all]
#
#   stream   Live tail. Device must be attached. Ctrl-C to stop.
#   collect  Pull the persisted store off an attached device and print matches.
#            Use this when the failure ALREADY happened.
#   archive  Read a .logarchive or a sysdiagnose you already have. No device,
#            no Mac-to-device link needed — this is the fully offline path.
#
#   --all    Include the high-volume "Player" category as well. Off by default;
#            that firehose is the thing this script exists to avoid.
#
# No device at hand? On the phone: hold both volume buttons + side button for
# ~1s to trigger a sysdiagnose, then Settings → Privacy & Security → Analytics
# & Improvements → Analytics Data → sysdiagnose_… → share it out. Feed the
# result to `archive`.

set -euo pipefail

SUBSYSTEM="com.swiftpili.app"
DIAG_CATEGORY="Diagnostic"
PLAYER_CATEGORY="Player"

MODE="${1:-}"
[ $# -gt 0 ] && shift || true

INCLUDE_ALL=0
DEVICE_ARGS=()
LAST="30m"
ARCHIVE_PATH=""

while [ $# -gt 0 ]; do
    case "$1" in
        --all)    INCLUDE_ALL=1; shift ;;
        --device) DEVICE_ARGS=(--device "$2"); shift 2 ;;
        --last)   LAST="$2"; shift 2 ;;
        -h|--help) MODE="help"; shift ;;
        *)
            if [ -z "$ARCHIVE_PATH" ] && [ -e "$1" ]; then
                ARCHIVE_PATH="$1"; shift
            else
                echo "unknown argument: $1" >&2; exit 2
            fi
            ;;
    esac
done

if [ "$INCLUDE_ALL" -eq 1 ]; then
    PREDICATE="subsystem == \"$SUBSYSTEM\" AND (category == \"$DIAG_CATEGORY\" OR category == \"$PLAYER_CATEGORY\")"
else
    PREDICATE="subsystem == \"$SUBSYSTEM\" AND category == \"$DIAG_CATEGORY\""
fi

if [ "$(uname)" != "Darwin" ] && [ "$MODE" != "help" ] && [ -n "$MODE" ]; then
    echo "This script drives macOS's \`log\` tool — run it on the Mac, not here." >&2
    exit 1
fi

case "$MODE" in
    stream)
        echo "── streaming $SUBSYSTEM / $([ "$INCLUDE_ALL" -eq 1 ] && echo 'Diagnostic+Player' || echo 'Diagnostic') ──" >&2
        echo "   Ctrl-C to stop. Nothing printed = nothing went wrong." >&2
        exec log stream "${DEVICE_ARGS[@]}" \
            --predicate "$PREDICATE" \
            --style compact \
            --level error
        ;;

    collect)
        OUT="swiftpili-$(date +%Y%m%d-%H%M%S).logarchive"
        echo "── collecting last $LAST into $OUT ──" >&2
        log collect "${DEVICE_ARGS[@]}" --last "$LAST" --output "$OUT"
        echo "── matches ──" >&2
        log show --archive "$OUT" --predicate "$PREDICATE" --style compact --info --debug
        echo >&2
        echo "Archive kept at $OUT — re-query it with:" >&2
        echo "  log show --archive $OUT --predicate '$PREDICATE' --style compact" >&2
        ;;

    archive)
        if [ -z "$ARCHIVE_PATH" ]; then
            echo "archive mode needs a path to a .logarchive or sysdiagnose" >&2
            exit 2
        fi
        TARGET="$ARCHIVE_PATH"
        # A sysdiagnose tarball carries system_logs.logarchive inside it.
        case "$ARCHIVE_PATH" in
            *.tar.gz)
                TMP="$(mktemp -d)"
                echo "── expanding sysdiagnose into $TMP ──" >&2
                tar -xzf "$ARCHIVE_PATH" -C "$TMP"
                TARGET="$(find "$TMP" -name 'system_logs.logarchive' -maxdepth 3 | head -1)"
                if [ -z "$TARGET" ]; then
                    echo "no system_logs.logarchive inside $ARCHIVE_PATH" >&2
                    exit 1
                fi
                ;;
        esac
        log show --archive "$TARGET" --predicate "$PREDICATE" --style compact --info --debug
        ;;

    help|"")
        sed -n '2,44p' "$0" | sed 's|^# \{0,1\}||'
        ;;

    *)
        echo "unknown mode: $MODE (want: stream | collect | archive | help)" >&2
        exit 2
        ;;
esac
