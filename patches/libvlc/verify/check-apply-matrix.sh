#!/usr/bin/env bash
# check-apply-matrix.sh [vlc-tree] [--build-log FILE]
#
# Offline apply hygiene for patches/libvlc/*.patch (P0.1 / P0.3).
#
# Why this exists:
#   build-libvlc.sh treats a failed git-apply as non-fatal "Skipped (already
#   applied or conflicts)" and keeps building. A green xcframework can therefore
#   be missing 0011, 0012, or both — or have only half of a dirty 0011∩0012
#   stack. check-applied.sh only sees the *built* tree; this script fails *before*
#   the build when the patch set itself cannot apply cleanly in order, or when
#   the build log already recorded a Skip.
#
# Modes (all composable):
#   1. Always: inventory expected patches 0002–0015; static P0.1 overlap detect;
#      T2 filters_rate_ownership (check-filters-rate-ownership.sh, patch-only;
#      passes VLC tree through when provided).
#   2. --build-log FILE: fail if any expected patch basename was Skipped.
#   3. Optional VLC tree arg: copy touched files into a TEMP scratch (never
#      mutates the caller's tree), reverse-apply expected patches in reverse
#      order (no-op if not applied), then forward-apply 0002→0015. FAIL if any
#      forward step fails (wrong base / conflict / incomplete reverse).
#
# Usage:
#   ./patches/libvlc/verify/check-apply-matrix.sh
#   ./patches/libvlc/verify/check-apply-matrix.sh ../SwiftVLC/scripts/.build-libvlc/vlc
#   ./patches/libvlc/verify/check-apply-matrix.sh --build-log /tmp/build-libvlc.log
#   ./patches/libvlc/verify/check-apply-matrix.sh /path/to/vlc --build-log log.txt
#   # T2 alone: ./patches/libvlc/verify/check-filters-rate-ownership.sh [vlc-tree]
#
# Exit:
#   0  all selected checks passed
#   1  hygiene failure (overlap, missing patch, Skip, ordered apply fail, T2)
#   2  usage / not a VLC tree / missing log
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
PATCH_DIR="$(cd "$HERE/.." && pwd)"

# libVLC commit that SwiftVLC's build-libvlc.sh pins (VLC_HASH). AC1 is stated
# against THIS commit, so the ordered-apply base is read from it with
# `git show <base>:<file>` — never from the caller's (possibly drifted) tree.
VLC_BASE="${VLC_BASE:-c833c4be0}"

VLC=""
BUILD_LOG=""
while [ $# -gt 0 ]; do
  case "$1" in
    --build-log)
      BUILD_LOG="${2:?usage: --build-log FILE}"
      shift 2
      ;;
    -h|--help)
      sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    -*)
      echo "unknown option: $1" >&2
      exit 2
      ;;
    *)
      if [ -n "$VLC" ]; then
        echo "usage: check-apply-matrix.sh [vlc-tree] [--build-log FILE]" >&2
        exit 2
      fi
      VLC="$1"
      shift
      ;;
  esac
done

fail=0
warn=0
ok()   { printf '  OK   %s\n' "$1"; }
bad()  { printf '  FAIL %s\n' "$1"; fail=1; }
warn() { printf '  WARN %s\n' "$1"; warn=1; }

# Expected ordered set (SwiftVLC's own 0001-chromecast lives in the fork; we
# start at 0002). Two files share the 0008- prefix — both are required.
# shellcheck disable=SC2034
EXPECTED=(
  0002-clock-apply-pause-delay-to-all-live-contexts.patch
  0003-input-seek-slaves-to-the-requested-time.patch
  0004-clock-apply-rate-change-to-all-live-contexts.patch
  0005-access-http-retry-without-precondition-on-412.patch
  0006-avcodec-log-hwdec-rejection-reason.patch
  0008-es_out-master-source-owns-program-pcr.patch
  0008-videotoolbox-native-av1.patch
  0009-clock-hold-mapping-across-rate-change-transient.patch
  0010-input_clock-re-anchor-forward-gaps-without-discontinuity.patch
  0011-aout-play-out-buffered-tail-on-eof.patch
  0012-aout-change_rate-hook.patch
  0013-avsamplebuffer-pitch-corrected-rate-backend.patch
  0014-input-drain-slaves-to-eof-after-master-eof.patch
  0015-input-audio-slave-demux-lead.patch
)

# --- 1) Inventory -----------------------------------------------------------
echo "=== patch inventory (patches/libvlc) ==="
missing=0
for name in "${EXPECTED[@]}"; do
  if [ -f "$PATCH_DIR/$name" ]; then
    ok "present $name"
  else
    bad "missing  $name"
    missing=1
  fi
done
# Unexpected extra numbered patches are informational only (do not fail).
while IFS= read -r extra; do
  base="$(basename "$extra")"
  known=0
  for name in "${EXPECTED[@]}"; do
    [ "$base" = "$name" ] && known=1 && break
  done
  if [ "$known" = 0 ]; then
    warn "extra unlisted patch: $base (not in expected 0002–0015 matrix)"
  fi
done < <(find "$PATCH_DIR" -maxdepth 1 -name '*.patch' | sort)

# --- 2) P0.1 static overlap: 0011 ∩ 0012 ------------------------------------
# Option B rebase: 0011 alone owns stream_ReplayDiscontinuity in dec.c.
# Dirty 0012 that still embeds the same body will Skip after 0011 on a clean
# ordered apply. Detect the symbol in *both* patch files (added lines).
echo
echo "=== P0.1 0011 ∩ 0012 discontinuity ownership ==="
P11="$PATCH_DIR/0011-aout-play-out-buffered-tail-on-eof.patch"
P12="$PATCH_DIR/0012-aout-change_rate-hook.patch"
has_replay() {
  # Count added lines that introduce the helper name (not only commit prose).
  grep -E '^\+.*stream_ReplayDiscontinuity' "$1" >/dev/null 2>&1
}
if [ ! -f "$P11" ] || [ ! -f "$P12" ]; then
  bad "cannot overlap-check: 0011 and/or 0012 file missing"
elif has_replay "$P11" && has_replay "$P12"; then
  bad "both 0011 and 0012 introduce stream_ReplayDiscontinuity — P0.1 not resolved; clean ordered apply will Skip 0012 (rebase 0012: strip dec.c discontinuity body; keep change_rate + filters)"
elif has_replay "$P11"; then
  ok "0011 owns stream_ReplayDiscontinuity; 0012 does not re-introduce it"
elif has_replay "$P12"; then
  # 0012 superseding 0011 is option A — product still wants 0011 standalone.
  bad "0012 introduces stream_ReplayDiscontinuity but 0011 does not — unexpected; 0011 must remain independently applyable (option B)"
else
  bad "neither 0011 nor 0012 introduces stream_ReplayDiscontinuity — F20 drain path missing from patch set"
fi

# Soft signal for other useful markers (never alone cause fail).
if [ -f "$P12" ]; then
  if grep -qE '^\+.*change_rate' "$P12" && grep -qE '^\+.*aout-handles-rate' "$P12"; then
    ok "0012 still carries change_rate + aout-handles-rate markers"
  else
    warn "0012 missing change_rate and/or aout-handles-rate added lines — rework core may be incomplete"
  fi
fi

# --- 2b) T2 filters_rate_ownership (static always; tree if VLC known) --------
# Always run the patch-only half here. If a VLC tree was passed, pass it through
# so the same script greps filters.c placement. Failures count as hygiene fails.
echo
echo "=== T2 filters_rate_ownership (via check-filters-rate-ownership.sh) ==="
OWN_SCRIPT="$HERE/check-filters-rate-ownership.sh"
if [ ! -x "$OWN_SCRIPT" ] && [ -f "$OWN_SCRIPT" ]; then
  chmod +x "$OWN_SCRIPT" 2>/dev/null || true
fi
if [ ! -f "$OWN_SCRIPT" ]; then
  bad "missing $OWN_SCRIPT — T2 gate not installed"
else
  # Capture output so matrix stays the single log; propagate non-zero as fail.
  own_rc=0
  OWN_OUT="$("$OWN_SCRIPT" ${VLC:+"$VLC"} 2>&1)" || own_rc=$?
  # Indent nested script lines for readability.
  printf '%s\n' "$OWN_OUT" | sed 's/^/  | /'
  if [ "$own_rc" = 0 ]; then
    ok "filters_rate_ownership harness passed (rc=0)"
  elif [ "$own_rc" = 2 ]; then
    bad "filters_rate_ownership usage/tree error (rc=2)"
  else
    bad "filters_rate_ownership failed (rc=$own_rc) — L1 rate ownership missing from 0012/tree"
  fi
fi

# --- 3) Optional build-log Skip scan ----------------------------------------
if [ -n "$BUILD_LOG" ]; then
  echo
  echo "=== build-log Skip scan ==="
  if [ ! -f "$BUILD_LOG" ]; then
    echo "not a readable build log: $BUILD_LOG" >&2
    exit 2
  fi
  # Match lines like: Skipped (already applied or conflicts): 0012-aout-...
  # or "Skipped ... 0012-..." — keep matching loose; require patch basename.
  skipped_any=0
  while IFS= read -r line; do
    # Only care about Skipped lines that name one of our patches.
    case "$line" in
      *[Ss]kipped*)
        for name in "${EXPECTED[@]}"; do
          # Match basename with or without .patch suffix fragments.
          stem="${name%.patch}"
          if printf '%s' "$line" | grep -F "$stem" >/dev/null 2>&1; then
            bad "build log Skipped expected patch: $name"
            printf '         %s\n' "$line"
            skipped_any=1
          fi
        done
        ;;
    esac
  done < "$BUILD_LOG"
  if [ "$skipped_any" = 0 ]; then
    ok "no expected patch marked Skipped in $(basename "$BUILD_LOG")"
  fi
fi

# --- 4) Optional ordered apply against a VLC tree (temp only) ---------------
if [ -n "$VLC" ]; then
  echo
  echo "=== ordered apply-check on VLC tree (scratch; no mutate) ==="
  if [ ! -f "$VLC/src/input/input.c" ] || [ ! -f "$VLC/src/audio_output/dec.c" ]; then
    echo "not a VLC source tree: $VLC" >&2
    exit 2
  fi

  TMP="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap 'rm -rf "$TMP"' EXIT

  # Collect every path touched by any expected patch (+++ b/...).
  files="$(
    for name in "${EXPECTED[@]}"; do
      [ -f "$PATCH_DIR/$name" ] || continue
      grep -h '^+++ b/' "$PATCH_DIR/$name" || true
    done | sed 's|^+++ b/||' | sed 's|[[:space:]].*||' | sort -u
  )"

  SCRATCH="$TMP/tree"
  mkdir -p "$SCRATCH"
  copy_ok=1
  for f in $files; do
    if [ ! -f "$VLC/$f" ]; then
      # Some patches touch test/ or files absent on partial checkouts — warn,
      # still try if the core file set exists.
      warn "tree missing $f (patch may still check if not needed yet)"
      continue
    fi
    mkdir -p "$SCRATCH/$(dirname "$f")"
    if ! cp "$VLC/$f" "$SCRATCH/$f"; then
      bad "could not copy $f into scratch"
      copy_ok=0
    fi
  done
  if [ "$copy_ok" != 1 ]; then
    echo "scratch setup failed" >&2
    exit 1
  fi

  # Ordered apply into scratch. Prefer git apply; fall back to patch(1).
  #
  # The caller's VLC tree is often *already* patched (post build-libvlc). Later
  # patches rewrite the same files (e.g. 0014 after 0003 on input.c; 0009 after
  # 0004 on clock.c), so reverse --check of an early patch alone fails even when
  # it is present. Strategy (same idea as verify/run.sh):
  #   1) reverse-apply every expected patch in reverse order (skip if not applied)
  #   2) forward-apply 0002→0015; each must succeed
  # Never mutate $VLC.
  apply_cmd() {
    # apply_cmd [-R] patchfile
    local rev="" pfile
    if [ "${1:-}" = "-R" ]; then rev="-R"; shift; fi
    pfile="$1"
    if command -v git >/dev/null 2>&1; then
      if [ -n "$rev" ]; then
        git apply --reverse --check "$pfile" >/dev/null 2>&1 \
          && git apply --reverse "$pfile" >/dev/null 2>&1
      else
        git apply --check "$pfile" >/dev/null 2>&1 \
          && git apply "$pfile" >/dev/null 2>&1
      fi
    else
      if [ -n "$rev" ]; then
        patch -s -p1 -R --dry-run < "$pfile" >/dev/null 2>&1 \
          && patch -s -p1 -R < "$pfile" >/dev/null 2>&1
      else
        patch -s -p1 --dry-run < "$pfile" >/dev/null 2>&1 \
          && patch -s -p1 < "$pfile" >/dev/null 2>&1
      fi
    fi
  }

  echo "  (normalising scratch toward stock: reverse-apply in reverse order)"
  i=${#EXPECTED[@]}
  while [ "$i" -gt 0 ]; do
    i=$((i - 1))
    name="${EXPECTED[i]}"
    pfile="$PATCH_DIR/$name"
    [ -f "$pfile" ] || continue
    if ( cd "$SCRATCH" && apply_cmd -R "$pfile" ); then
      printf '  OK   reverse %s\n' "$name"
    else
      printf '  skip reverse %s (not applied on source tree)\n' "$name"
    fi
  done

  echo "  (forward ordered apply 0002–0015)"
  apply_failed=0
  for name in "${EXPECTED[@]}"; do
    pfile="$PATCH_DIR/$name"
    [ -f "$pfile" ] || continue
    err="$TMP/err-$name.txt"
    : >"$err"
    if (
      cd "$SCRATCH" && {
        if command -v git >/dev/null 2>&1; then
          git apply --check "$pfile" >/dev/null 2>"$err" \
            && git apply "$pfile" >/dev/null 2>"$err"
        else
          patch -s -p1 --dry-run < "$pfile" >/dev/null 2>"$err" \
            && patch -s -p1 < "$pfile" >/dev/null 2>"$err"
        fi
      }
    ); then
      ok "apply $name"
    else
      bad "apply failed: $name (wrong base, conflict, or prior reverse incomplete)"
      if [ -s "$err" ]; then
        sed -n '1,6p' "$err" | sed 's/^/         /'
      fi
      apply_failed=1
      # Continue so the log shows how far the cascade goes.
    fi
  done

  if [ "$apply_failed" = 0 ]; then
    ok "full ordered matrix 0002–0015 on scratch from $VLC"
  else
    bad "ordered apply matrix incomplete — fix first failing patch / P0.1 overlap before rebuild"
  fi
fi

# --- 5) Ordered apply against the PINNED BASE COMMIT ------------------------
#
# Why this exists (2026-07-26): stage 4 builds its scratch from the caller's
# *working tree* and reverse-applies our patches to "recover stock". That is
# only stock if the tree carries nothing but our patches. It does not: a tree
# can hold hand edits, half-reverted experiments, or stray whitespace. A patch
# whose hunk geometry was captured from such a tree then round-trips through
# stage 4 (reverse → forward) and reports OK while FAILING on a fresh clone.
#
# That is not hypothetical. 0015 shipped for weeks with two blank context lines
# in src/input/input.c and src/libvlc-module.c that stock c833c4be0 does not
# have. Stage 4 was green; `git apply --check` on a fresh checkout failed;
# build-libvlc.sh logs a non-fatal "Skipped" and builds a green xcframework
# with NONE of 0015. AC1 says "clean ordered apply … on c833c4be0", so the
# base must come from the commit, never from the tree.
#
# `git show <base>:<file>` is read-only on the caller's repository.
if [ -n "$VLC" ]; then
  echo
  echo "=== ordered apply-check on PINNED BASE $VLC_BASE (git show; no mutate) ==="
  if ! command -v git >/dev/null 2>&1; then
    warn "git unavailable — cannot check against the pinned base"
  elif ! git -C "$VLC" rev-parse --git-dir >/dev/null 2>&1; then
    warn "$VLC is not a git repository — cannot check against the pinned base"
  elif ! git -C "$VLC" cat-file -e "$VLC_BASE^{commit}" 2>/dev/null; then
    warn "pinned base $VLC_BASE not present in $VLC (shallow clone?) — skipped"
  else
    BASE_TMP="$(mktemp -d)"
    BASE_SCRATCH="$BASE_TMP/tree"
    mkdir -p "$BASE_SCRATCH"
    base_ok=1
    for f in $files; do
      mkdir -p "$BASE_SCRATCH/$(dirname "$f")"
      if ! git -C "$VLC" show "$VLC_BASE:$f" >"$BASE_SCRATCH/$f" 2>/dev/null; then
        warn "pinned base has no $f — skipping it from the base matrix"
        rm -f "$BASE_SCRATCH/$f"
      fi
    done
    base_failed=0
    for name in "${EXPECTED[@]}"; do
      pfile="$PATCH_DIR/$name"
      [ -f "$pfile" ] || continue
      err="$BASE_TMP/err-$name.txt"
      : >"$err"
      if ( cd "$BASE_SCRATCH" && git apply --check "$pfile" 2>"$err" \
                              && git apply "$pfile" 2>"$err" ); then
        ok "base apply $name"
      else
        bad "base apply FAILED: $name — will be Skipped on a fresh c833c4be0 clone (green build, patch absent)"
        [ -s "$err" ] && sed -n '1,6p' "$err" | sed 's/^/         /'
        base_failed=1
      fi
    done
    if [ "$base_failed" = 0 ]; then
      ok "full ordered matrix 0002–0015 applies to pinned $VLC_BASE (AC1)"
      # Informational: does the pinned-base result equal the built tree? A
      # difference means the tree carries something no patch reproduces.
      # `modules/codec/avcodec/video.c` is expected to differ — SwiftVLC's own
      # build-libvlc.sh edits hwfmts[] in place (not a tracked patch).
      for f in $files; do
        [ -f "$BASE_SCRATCH/$f" ] || continue
        [ -f "$VLC/$f" ] || continue
        case "$f" in modules/codec/avcodec/video.c) continue ;; esac
        if ! diff -q "$BASE_SCRATCH/$f" "$VLC/$f" >/dev/null 2>&1; then
          warn "tree drift: $f differs from (pinned base + patch stack)"
        fi
      done
    fi
    rm -rf "$BASE_TMP"
  fi
fi

# --- summary ----------------------------------------------------------------
echo
if [ "$fail" = 0 ]; then
  echo "PASS apply hygiene"
  [ "$warn" != 0 ] && echo "(completed with warnings)"
  exit 0
fi
echo "FAIL apply hygiene — do not treat a green build as proof patches landed"
echo "  P0.1: rebase 0012 off 0011 (no shared stream_ReplayDiscontinuity body)"
echo "  P0.3: re-run after build with --build-log; never ship Skipped patches"
echo "  post-build placement: ./patches/libvlc/verify/check-applied.sh <vlc>"
exit 1
