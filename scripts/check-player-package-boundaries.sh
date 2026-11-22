#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPOSITORY_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"

usage() {
    cat <<'EOF'
Usage: scripts/check-player-package-boundaries.sh

Checks the real package/App source boundary.
EOF
}

clean_source() {
    # Boundary checks are source checks, not documentation checks.  Remove
    # block comments and full-line/trailing single-line comments before
    # applying patterns.  Keep URL literals intact: a `//` is a comment only
    # when it starts a line or follows whitespace.
    perl -0pe 's:/\*.*?\*/::gs; s{(^[[:space:]]*|[[:space:]]+)//.*$}{$1}gm'
}

report_violation() {
    local label="$1"
    local file="$2"
    local detail="$3"
    printf 'player package boundary violation [%s]: %s (%s)\n' "$label" "$file" "$detail" >&2
}

check_manifest() {
    local root="$1"
    local manifest="$root/Packages/PiliPlayerKit/Package.swift"
    local failed=0
    local manifest_text
    local library_count

    if [[ ! -f "$manifest" ]]; then
        report_violation "manifest" "$manifest" "missing local package manifest"
        return 1
    fi

    manifest_text="$(clean_source < "$manifest" | tr '\n' ' ')"

    if ! grep -Eq '\.library\([^)]*name:[[:space:]]*"PiliPlayerEngine"' <<< "$manifest_text"; then
        report_violation "manifest" "$manifest" "missing Engine target/product"
        failed=1
    fi
    library_count="$(grep -Eo '\.library\(' <<< "$manifest_text" | wc -l | tr -d ' ')"
    if [[ "$library_count" != "1" ]]; then
        report_violation "manifest" "$manifest" "Engine must be the package library product"
        failed=1
    fi
    if grep -Eq '\.library\([^)]*name:[[:space:]]*"PiliPlayer(Core|Media|Apple)"' <<< "$manifest_text"; then
        report_violation "manifest" "$manifest" "Core/Media/Apple must not be products"
        failed=1
    fi
    if ! grep -Eq 'dependencies:[[:space:]]*\[[[:space:]]*"PiliPlayerCore",[[:space:]]*"PiliPlayerMedia",[[:space:]]*"PiliPlayerApple"[[:space:]]*\]' <<< "$manifest_text"; then
        report_violation "manifest" "$manifest" "Engine dependency order is not Core -> Media/Apple -> Engine"
        failed=1
    fi
    if ! grep -Eq 'name:[[:space:]]*"PiliPlayerMedia"' "$manifest" \
        || ! grep -Eq 'name:[[:space:]]*"PiliPlayerApple"' "$manifest" \
        || ! grep -Eq 'name:[[:space:]]*"PiliPlayerCore"' "$manifest"; then
        report_violation "manifest" "$manifest" "all four package targets must exist"
        failed=1
    fi

    return "$failed"
}

check_source_tree() {
    local root="$1"
    local package_sources="$root/Packages/PiliPlayerKit/Sources"
    local app_sources="$root/SwiftPili"
    local failed=0
    local file
    local cleaned
    local flattened
    local basename
    local app_match

    if [[ ! -d "$package_sources" ]]; then
        report_violation "sources" "$package_sources" "missing package source tree"
        failed=1
    fi
    if [[ ! -d "$app_sources" ]]; then
        report_violation "sources" "$app_sources" "missing App source tree"
        failed=1
    fi

    while IFS= read -r file; do
        cleaned="$(clean_source < "$file")"
        flattened="$(printf '%s\n' "$cleaned" | tr '\n' ' ')"

        if printf '%s\n' "$cleaned" | grep -Eq '(^|[[:space:]])import[[:space:]]+(SwiftUI|Observation|SwiftVLC|Kingfisher)([[:space:]]|$)'; then
            report_violation "package-import" "$file" "UI/App/VLC dependency"
            failed=1
        fi
        if printf '%s\n' "$cleaned" | grep -Eq '(^|[^[:alnum:]_])(SwiftPili|SwiftVLC|Kingfisher|Observation|PlayerViewModel|PlayerView|PlayerBackend|PlayerEngineKind|PlayerLog|PlaybackDebugRecorder|DemandPacedPlayerBackend|MediaEngineSession|VLCPlayerBackend|UserDefaults|SettingsStore|ProductSettings|AppSettings|AccountManager|APIClient|Navigation|SponsorBlock|Bili[A-Za-z]*|shared)([^[:alnum:]_]|$)'; then
            report_violation "package-symbol" "$file" "App/product/engine-internal symbol"
            failed=1
        fi

        case "$file" in
            */Sources/PiliPlayerCore/*|*/Sources/PiliPlayerMedia/*)
                if printf '%s\n' "$cleaned" | grep -Eq '(^|[[:space:]])import[[:space:]]+(UIKit|AVKit)([[:space:]]|$)'; then
                    report_violation "platform-import" "$file" "UIKit/AVKit is forbidden in Core and Media"
                    failed=1
                fi
                ;;
        esac

        if printf '%s\n' "$cleaned" | grep -Eq '(^|[[:space:]])public[[:space:]].*(MediaEngineSession|DemandPacedPlayerBackend|VLCPlayerBackend|PlaybackRuntime|PlaybackRuntimeCommand|PlaybackRuntimeDecision|PiliPlayer(Core|Media|Apple)Boundary)([^[:alnum:]_]|$)'; then
            report_violation "public-api" "$file" "public declaration exposes package-internal engine type"
            failed=1
        fi
        if printf '%s\n' "$flattened" | grep -Eq 'public[^{};]{0,240}(MediaEngineSession|DemandPacedPlayerBackend|VLCPlayerBackend|PlaybackRuntime|PlaybackRuntimeCommand|PlaybackRuntimeDecision|PiliPlayer(Core|Media|Apple)Boundary)([^[:alnum:]_]|$)'; then
            report_violation "public-api" "$file" "public declaration exposes package-internal engine type"
            failed=1
        fi
        if printf '%s\n' "$flattened" | grep -Eq 'public[^{};]{0,240}(AV1|AVC|HEVC|FPS|frameRate|nearFuture|futureTimestamp|timestamp)([^[:alnum:]_]|$)'; then
            report_violation "public-api" "$file" "public recovery declaration exposes codec/near-future authority"
            failed=1
        fi
    done < <(find "$package_sources" -type f -name '*.swift' -print)

    while IFS= read -r file; do
        cleaned="$(clean_source < "$file")"
        if printf '%s\n' "$cleaned" | grep -Eq '(^|[[:space:]])import[[:space:]]+PiliPlayer(Core|Media|Apple)([[:space:]]|$)'; then
            report_violation "app-import" "$file" "App may import only the Engine product"
            failed=1
        fi
    done < <(find "$app_sources" -type f -name '*.swift' -print)

    while IFS= read -r file; do
        basename="$(basename "$file")"
        app_match="$(find "$app_sources" -type f -name "$basename" -print -quit)"
        if [[ -n "$app_match" ]]; then
            report_violation "duplicate-source" "$file" "same Swift basename exists in App at $app_match"
            failed=1
        fi
    done < <(find "$package_sources" -type f -name '*.swift' -print)

    return "$failed"
}

check_tree() {
    local root="$1"
    local failed=0

    if ! check_manifest "$root"; then
        failed=1
    fi
    if ! check_source_tree "$root"; then
        failed=1
    fi

    return "$failed"
}

case "${1:-}" in
    "")
        check_tree "$REPOSITORY_ROOT"
        ;;
    --help|-h)
        usage
        ;;
    *)
        usage >&2
        exit 2
        ;;
esac
