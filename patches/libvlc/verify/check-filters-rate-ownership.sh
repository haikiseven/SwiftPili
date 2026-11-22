#!/usr/bin/env bash
# check-filters-rate-ownership.sh [vlc-tree]
#
# Offline T2 gate: `filters_rate_ownership` for patch 0012 (L1).
#
# Why this exists:
#   When a module sets "aout-handles-rate", core must not double-apply rate:
#     1) skip scaletempo insertion
#     2) do NOT promote FindResampler to rate_filter
#     3) aout_FiltersPlay at rate≠1 with rate_filter NULL must pass raw PCM
#        (no `goto drop` / `drop:` silence path)
#   Missing (2)+(3) was the double-rate engine bug (TimePitch + resampler stretch).
#
# Full behavioural compile of filters.c needs VLC deps. This harness is static
# (always) + optional live-tree greps — same class as check-apply-matrix /
# check-applied placement asserts, not a PCM duration unit.
#
# Usage:
#   ./patches/libvlc/verify/check-filters-rate-ownership.sh
#   ./patches/libvlc/verify/check-filters-rate-ownership.sh ../SwiftVLC/scripts/.build-libvlc/vlc
#
# If no VLC tree arg is given, tries (relative to repo root):
#   ../SwiftVLC/scripts/.build-libvlc/vlc
# when that path exists; otherwise runs patch-only checks.
#
# Exit:
#   0  all selected checks passed
#   1  ownership missing / L1 regression
#   2  usage / not a VLC tree when arg given
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
PATCH_DIR="$(cd "$HERE/.." && pwd)"
REPO_ROOT="$(cd "$HERE/../../.." && pwd)"
P12="$PATCH_DIR/0012-aout-change_rate-hook.patch"
DEFAULT_TREE="$REPO_ROOT/../SwiftVLC/scripts/.build-libvlc/vlc"

VLC=""
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help)
      sed -n '2,34p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    -*)
      echo "unknown option: $1" >&2
      exit 2
      ;;
    *)
      if [ -n "$VLC" ]; then
        echo "usage: check-filters-rate-ownership.sh [vlc-tree]" >&2
        exit 2
      fi
      VLC="$1"
      shift
      ;;
  esac
done

if [ -z "$VLC" ] && [ -f "$DEFAULT_TREE/src/audio_output/filters.c" ]; then
  VLC="$DEFAULT_TREE"
fi

fail=0
ok()  { printf '  OK   %s\n' "$1"; }
bad() { printf '  FAIL %s\n' "$1"; fail=1; }

# --- 1) Always: static checks on 0012 patch ---------------------------------
echo "=== T2 filters_rate_ownership — patch 0012 (static) ==="

if [ ! -f "$P12" ]; then
  bad "missing $P12"
  echo
  echo "FAIL filters_rate_ownership (patch absent)"
  exit 1
fi

# 1a) scaletempo skip gated on aout-handles-rate / aout_handles_rate.
# Expect added lines that introduce the flag and gate audio-time-stretch /
# scaletempo (not only prose in the commit message).
if grep -qE '^\+.*aout-handles-rate' "$P12" \
  && grep -qE '^\+.*aout_handles_rate' "$P12" \
  && grep -qE '^\+.*!aout_handles_rate' "$P12" \
  && grep -qE '^\+.*audio-time-stretch|^\+.*scaletempo' "$P12"; then
  ok "patch: aout-handles-rate / aout_handles_rate guards scaletempo path"
else
  bad "patch: missing aout-handles-rate guard before scaletempo (L1 #1)"
fi

# 1b) rate_filter promotion gated: must NOT assign resampler when module owns rate.
# Stock: `if (filters->rate_filter == NULL)` then promote.
# L1:    `if (filters->rate_filter == NULL && !aout_handles_rate)`
# Require the compound condition on one added line. A soft "nearby" fallback was
# removed: co-presence of rate_filter + !aout_handles_rate + assignment can pass
# even when the gate is not on the promotion `if` (false positive / double-rate).
if grep -qE '^\+.*rate_filter == NULL && !aout_handles_rate' "$P12" \
  || grep -qE '^\+.*!aout_handles_rate && .*rate_filter == NULL' "$P12"; then
  ok "patch: rate_filter promotion gated with !aout_handles_rate (L1 #2)"
else
  bad "patch: no L1 rate_filter promotion gate (!aout_handles_rate) — double-rate risk"
fi

# 1c) FiltersPlay: remove drop path; keep if (rate_filter != NULL) branch.
# Only treat *code* as regression — comments may say "used to goto drop".
# Added executable goto: line starts with + then optional spaces then goto drop;
added_goto_drop() {
  grep -E '^\+[[:space:]]*goto[[:space:]]+drop[[:space:]]*;' "$1" >/dev/null 2>&1
}
added_drop_label() {
  # label line: +drop:  (not prose inside a comment block)
  grep -E '^\+[[:space:]]*drop:[[:space:]]*$' "$1" >/dev/null 2>&1
}
removed_goto_drop() {
  grep -E '^\-[[:space:]]*goto[[:space:]]+drop[[:space:]]*;' "$1" >/dev/null 2>&1
}
removed_drop_label() {
  grep -E '^\-[[:space:]]*drop:[[:space:]]*$' "$1" >/dev/null 2>&1 \
    || grep -E '^\-drop:' "$1" >/dev/null 2>&1
}

if added_goto_drop "$P12"; then
  bad "patch: re-introduces goto drop; in FiltersPlay (L1 #3 regression)"
else
  ok "patch: does not add executable goto drop"
fi
if added_drop_label "$P12"; then
  bad "patch: re-introduces drop: label (L1 #3 regression)"
else
  ok "patch: does not add drop: label"
fi

# Expect removal of stock drop path and addition of rate_filter != NULL branch.
if removed_goto_drop "$P12" || removed_drop_label "$P12"; then
  ok "patch: removes stock goto drop / drop: path"
else
  # May already be written only as positive if (rate_filter != NULL) on a rebased blob.
  if grep -qE '^\+.*if \(rate_filter != NULL\)' "$P12"; then
    ok "patch: FiltersPlay uses if (rate_filter != NULL) (drop path not re-added)"
  else
    bad "patch: FiltersPlay L1 raw-PCM path unclear (expect remove drop + if rate_filter != NULL)"
  fi
fi

if grep -qE '^\+.*if \(rate_filter != NULL\)' "$P12"; then
  ok "patch: FiltersPlay keeps if (rate_filter != NULL) branch (raw PCM when NULL)"
else
  bad "patch: missing if (rate_filter != NULL) in FiltersPlay — null rate_filter may still drop"
fi

# --- 2) Optional: live VLC tree filters.c -----------------------------------
if [ -n "$VLC" ]; then
  echo
  echo "=== T2 filters_rate_ownership — tree filters.c ==="
  FILT="$VLC/src/audio_output/filters.c"
  if [ ! -f "$FILT" ]; then
    echo "not a VLC source tree (no src/audio_output/filters.c): $VLC" >&2
    exit 2
  fi

  # 2a) aout_handles_rate / aout-handles-rate before scaletempo AppendFilter.
  # Do not stop at the word "scaletempo" in comments; require the AppendFilter call.
  SCALEREGION="$(
    awk '
      /bool aout_handles_rate/ {f=1}
      f {print}
      /AppendFilter\(.*scaletempo/ {if (f) exit}
    ' "$FILT"
  )"
  if printf '%s' "$SCALEREGION" | grep -q 'aout_handles_rate' \
    && printf '%s' "$SCALEREGION" | grep -q 'aout-handles-rate' \
    && printf '%s' "$SCALEREGION" | grep -qE 'AppendFilter\(.*scaletempo'; then
    ok "tree: aout_handles_rate / aout-handles-rate present before scaletempo"
  else
    # Fallback: same file must mention both the var and AppendFilter scaletempo.
    if grep -q 'aout-handles-rate' "$FILT" \
      && grep -q 'aout_handles_rate' "$FILT" \
      && grep -qE 'AppendFilter\(.*scaletempo' "$FILT" \
      && grep -qE '!aout_handles_rate' "$FILT"; then
      ok "tree: aout-handles-rate + !aout_handles_rate + scaletempo AppendFilter present"
    else
      bad "tree: no aout-handles-rate guard before scaletempo in filters.c"
    fi
  fi
  if printf '%s' "$SCALEREGION" | grep -qE '!aout_handles_rate' \
    || grep -qE 'if \(!aout_handles_rate' "$FILT"; then
    ok "tree: scaletempo path gated with !aout_handles_rate"
  else
    bad "tree: scaletempo not gated by !aout_handles_rate"
  fi

  # 2b) rate_filter promotion gate.
  if grep -qE 'rate_filter == NULL && !aout_handles_rate' "$FILT" \
    || grep -qE '!aout_handles_rate && .*rate_filter == NULL' "$FILT"; then
    ok "tree: rate_filter promotion gated (!aout_handles_rate)"
  else
    # Stock promotion without gate is the double-rate bug.
    if grep -n 'filters->rate_filter = filters->resampler' "$FILT" | grep -q .; then
      bad "tree: resampler promoted to rate_filter without !aout_handles_rate gate"
    else
      bad "tree: rate_filter promotion gate missing (and no resampler assign found)"
    fi
  fi

  # 2c) aout_FiltersPlay: no executable goto drop; has != NULL branch.
  PLAY="$(awk '/^block_t \*aout_FiltersPlay/,/^}/' "$FILT")"
  if [ -z "$PLAY" ]; then
    bad "tree: could not extract aout_FiltersPlay"
  else
    if printf '%s' "$PLAY" | grep -qE '^[[:space:]]*goto[[:space:]]+drop[[:space:]]*;'; then
      bad "tree: aout_FiltersPlay still has goto drop (null rate_filter silences audio)"
    else
      ok "tree: aout_FiltersPlay has no executable goto drop"
    fi
    if printf '%s' "$PLAY" | grep -qE '^[[:space:]]*drop:[[:space:]]*$'; then
      bad "tree: aout_FiltersPlay still has drop: label"
    else
      ok "tree: aout_FiltersPlay has no drop: label"
    fi
    if printf '%s' "$PLAY" | grep -qE 'if \(rate_filter != NULL\)'; then
      ok "tree: aout_FiltersPlay has if (rate_filter != NULL) branch"
    else
      bad "tree: aout_FiltersPlay missing if (rate_filter != NULL) — L1 raw path absent"
    fi
  fi
else
  echo
  echo "=== T2 filters_rate_ownership — tree (skipped, no VLC tree) ==="
  printf '  skip no tree (pass ../SwiftVLC/scripts/.build-libvlc/vlc to enable)\n'
fi

# --- summary ----------------------------------------------------------------
echo
if [ "$fail" = 0 ]; then
  echo "PASS filters_rate_ownership (static L1 markers; not a PCM duration unit)"
  exit 0
fi
echo "FAIL filters_rate_ownership — L1 aout-handles-rate ownership missing or regressed"
echo "  Fix: 0012 filters.c — skip scaletempo; gate rate_filter promote; no drop on NULL"
echo "  See patches/libvlc/README.md for rate-ownership requirements"
exit 1
