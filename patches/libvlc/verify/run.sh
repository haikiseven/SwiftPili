#!/bin/bash
# Proves the clock patches on any host with a C compiler — no VLC build, no
# macOS, no autotools.
#
# VLC's own test/src/clock/clock.c needs libvlc_new() and thus the whole build.
# But src/clock/clock.c and src/clock/input_clock.c are self-contained enough to
# compile against a trivial config.h plus a handful of libvlccore stubs
# (stubs.c). The drivers then replay the scenarios the patches address.
#
#   ./run.sh /path/to/vlc
#
# The tree may be patched or unpatched — both variants are built either way, by
# applying (or reverse-applying) the patches to a scratch copy of ONLY the files
# they touch. The tree is never copied wholesale: a built VLC checkout is many
# GB, and `cp -a` on it appears to hang.
#
# Two independent targets:
#   clock.c        — patches 0002 (pause), 0004 (rate), 0009 (rate-settle)
#                    scenarios: contexts_pause, rate_change, rate_settle
#   input_clock.c  — patch   0010 (forward-gap re-anchor, F20)
#                    scenario: clock_gap
#
# Expected: every scenario FAILs stock and PASSes patched.
set -euo pipefail
V="${1:?usage: run.sh /path/to/vlc}"
HERE="$(cd "$(dirname "$0")" && pwd)"

CLOCK_PATCHES=("$HERE/../0002-clock-apply-pause-delay-to-all-live-contexts.patch"
               "$HERE/../0004-clock-apply-rate-change-to-all-live-contexts.patch"
               "$HERE/../0009-clock-hold-mapping-across-rate-change-transient.patch")
IC_PATCHES=("$HERE/../0010-input_clock-re-anchor-forward-gaps-without-discontinuity.patch")

[ -f "$V/src/clock/clock.c" ] || { echo "not a VLC source tree: $V" >&2; exit 2; }
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

cp "$HERE"/{config.h,stubs.c,driver.c,driver_rate.c,driver_f19.c,driver_f20.c} "$TMP/"
cp "$V/src/clock/clock.h" "$TMP/"
INC=(-I"$TMP" -I"$V/src/clock" -I"$V/include" -I"$V/src" -I"$V")

cc -c -DHAVE_CONFIG_H "${INC[@]}" "$V/src/clock/clock_internal.c" -o "$TMP/clock_internal.o"
cc -c -DHAVE_CONFIG_H "${INC[@]}" "$TMP/stubs.c"      -o "$TMP/stubs.o"
cc -c -DHAVE_CONFIG_H "${INC[@]}" "$TMP/driver.c"     -o "$TMP/driver.o"
cc -c -DHAVE_CONFIG_H "${INC[@]}" "$TMP/driver_rate.c" -o "$TMP/driver_rate.o"
cc -c -DHAVE_CONFIG_H "${INC[@]}" "$TMP/driver_f19.c" -o "$TMP/driver_f19.o"
cc -c -DHAVE_CONFIG_H "${INC[@]}" "$TMP/driver_f20.c" -o "$TMP/driver_f20.o"

# variant MODE REL PATCH...  -> prints the path to the resulting source file.
# Copies every file each patch touches (some patches also touch test/…) into a
# scratch dir, then applies (MODE=apply) or reverse-applies (MODE=reverse, in
# reverse order) the patches. Builds only use $dir/$REL.
variant() {
  local mode="$1" rel="$2"; shift 2
  local patches=("$@")
  local dir="$TMP/$mode-${rel//\//_}" rev="" f
  [ "$mode" = reverse ] && rev="-R"
  # gather the set of files touched by these patches
  local files; files="$(grep -h '^+++ b/' "${patches[@]}" | sed 's|^+++ b/||' | sort -u)"
  for f in $files; do
    mkdir -p "$dir/$(dirname "$f")"
    cp "$V/$f" "$dir/$f"
  done
  local list=("${patches[@]}") i
  if [ "$mode" = reverse ]; then
    list=(); for (( i=${#patches[@]}-1; i>=0; i-- )); do list+=("${patches[i]}"); done
  fi
  local pfile
  for pfile in "${list[@]}"; do
    ( cd "$dir" && { git apply $rev "$pfile" 2>/dev/null || patch -s -p1 $rev < "$pfile"; } ) \
      || { echo "could not $mode $(basename "$pfile") against $V" >&2; exit 2; }
  done
  echo "$dir/$rel"
}

# build_run SRC DRIVER  — compile SRC (clock.c or input_clock.c) and link the
# driver against the shared objects.
build_run() {
  rm -f "$TMP/unit.o" "$TMP/run"
  cc -c -DHAVE_CONFIG_H "${INC[@]}" "$1" -o "$TMP/unit.o"
  cc "$TMP/unit.o" "$TMP/clock_internal.o" "$TMP/stubs.o" "$2" -o "$TMP/run" -lpthread -lm
  "$TMP/run"
}

# Resolve stock/patched source for each target (handles an already-patched tree).
if grep -q "context_apply_pause_delay" "$V/src/clock/clock.c"; then
  echo "(clock.c already patched — reverse-applying to obtain the stock variant)"
  CLOCK_STOCK="$(variant reverse src/clock/clock.c "${CLOCK_PATCHES[@]}")"
  CLOCK_PATCHED="$V/src/clock/clock.c"
else
  CLOCK_STOCK="$V/src/clock/clock.c"
  CLOCK_PATCHED="$(variant apply src/clock/clock.c "${CLOCK_PATCHES[@]}")"
fi

if grep -q "stream_diff < 0 = corruption" "$V/src/clock/input_clock.c"; then
  echo "(input_clock.c already patched — reverse-applying to obtain the stock variant)"
  IC_STOCK="$(variant reverse src/clock/input_clock.c "${IC_PATCHES[@]}")"
  IC_PATCHED="$V/src/clock/input_clock.c"
else
  IC_STOCK="$V/src/clock/input_clock.c"
  IC_PATCHED="$(variant apply src/clock/input_clock.c "${IC_PATCHES[@]}")"
fi

# scenario  NAME  DRIVER.o  STOCK_SRC  PATCHED_SRC
fail=0
run_scenario() {
  local name="$1" obj="$2" stock_src="$3" patched_src="$4"
  echo "================= $name ================="
  echo "---------- STOCK ----------"
  set +e; build_run "$stock_src"   "$obj"; local stock=$?;   set -e
  echo "---------- PATCHED ----------"
  set +e; build_run "$patched_src" "$obj"; local patched=$?; set -e
  if [ "$stock" -eq 1 ] && [ "$patched" -eq 0 ]; then
    echo "  ✅ $name: reproduces without the patches, fixed by them"
  else
    echo "  ❌ $name: INCONCLUSIVE (stock=$stock patched=$patched, expected 1 and 0)"; fail=1
  fi
  echo
}

run_scenario contexts_pause "$TMP/driver.o"      "$CLOCK_STOCK" "$CLOCK_PATCHED"
run_scenario rate_change    "$TMP/driver_rate.o" "$CLOCK_STOCK" "$CLOCK_PATCHED"
run_scenario rate_settle    "$TMP/driver_f19.o"  "$CLOCK_STOCK" "$CLOCK_PATCHED"
run_scenario clock_gap      "$TMP/driver_f20.o"  "$IC_STOCK"    "$IC_PATCHED"

[ "$fail" = 0 ] && echo "✅ VERIFIED" || { echo "❌ NOT VERIFIED"; exit 1; }
