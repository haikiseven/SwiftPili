#!/usr/bin/env bash
#
# One media-clock authority, checkable anywhere — including Linux and a hosted CI
# runner with no iOS SDK.
#
# Path A's media clock had two writers once, selected by a downcast
# (`(audioRender as? EngineAudioRenderer)?.engineStarted`) that decided which
# clock was master and whose SHIPPING branch had no test. It was deleted with the
# rule "one writer, one branch, one thing to test"
# (`MediaEngineSession.renderedContentDidAdvance`). Moving the PCM ring refill off
# MainActor puts a second candidate writer one careless line away, so that rule is
# enforced here by grep rather than by memory.
#
# This is a STRUCTURAL gate, not a behaviour test. It cannot tell you the clock is
# correct; it can tell you nobody added a second thing that could move it.
#
#   scripts/check-audio-clock-ownership.sh
#
# Exit 0 = the invariants hold. Exit 1 = one of them was broken; the message names
# which and where.

set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

ENGINE="SwiftPili/Player/Engine"
RENDER="$ENGINE/Render"
SESSION="$ENGINE/MediaEngineSession.swift"
RENDERER="$RENDER/EngineAudioRenderer.swift"
FEEDER="$RENDER/AudioRingFeeder.swift"
ADMISSION="$RENDER/AudioFeederAdmission.swift"

failures=0

fail() {
    printf '  FAIL  %s\n' "$1" >&2
    failures=$((failures + 1))
}

pass() {
    printf '  ok    %s\n' "$1"
}

# `grep -c` counts LINES, which is what we want: each of these calls is one line.
count_in() {
    # $1 = pattern (basic regex), $2.. = files
    local pattern="$1"
    shift
    grep -c -- "$pattern" "$@" 2>/dev/null | awk -F: '{ n += $NF } END { print n + 0 }'
}

# Match count in a file with comment lines stripped.
#
# ⚠️ Deliberately NOT `... | grep -q`. `grep -q` exits on its FIRST match, which
# closes the pipe and SIGPIPEs the upstream `grep`; under `set -o pipefail` that
# turns a MATCH into a non-zero pipeline status, so `if pipeline; then fail` takes
# the `else` branch and reports OK. It is racy, so it does not show up every run.
# Measured before this was fixed: the `slotPulledFrames` check passed 4 times in
# 10 with the mirror present in the file. `grep -c` reads all of its input, so it
# cannot SIGPIPE the producer.
code_match_count() {
    local pattern="$1" file="$2"
    local n
    n=$(grep -v '^[[:space:]]*//' "$file" | grep -cE -- "$pattern") || n=0
    printf '%s' "${n:-0}"
}

# Same, for a string already in a variable. No pipe at all.
text_match_count() {
    local pattern="$1" text="$2"
    local n
    n=$(grep -cE -- "$pattern" <<<"$text") || n=0
    printf '%s' "${n:-0}"
}

require_files() {
    local missing=0
    for f in "$@"; do
        if [ ! -f "$f" ]; then
            printf '  FAIL  missing file: %s\n' "$f" >&2
            missing=1
        fi
    done
    return $missing
}

echo "audio clock ownership — structural gate"

if ! require_files "$SESSION" "$RENDERER" "$FEEDER" "$ADMISSION"; then
    echo "cannot run: expected sources are not where this gate looks for them" >&2
    exit 1
fi

# ── 1. Exactly ONE caller of the delta producer, across the whole app.
n=$(count_in 'slotDrainProgress\[[^]]*\]\.advance(' "$RENDERER")
other=$(grep -rln 'AudioDrainProgress()' SwiftPili/ 2>/dev/null | grep -cv "^$RENDERER$")
if [ "$n" -eq 1 ]; then
    pass "AudioDrainProgress.advance has exactly 1 call site"
else
    fail "AudioDrainProgress.advance has $n call sites (expected 1) in $RENDERER"
fi
if [ "$other" -eq 0 ]; then
    pass "AudioDrainProgress is instantiated only by the renderer"
else
    fail "AudioDrainProgress instantiated outside $RENDERER — a second delta producer"
fi

# ── 2. Exactly ONE caller of the clock writer, across the whole app.
n=$(grep -rc 'clock\.advanceContent(' SwiftPili/ --include='*.swift' 2>/dev/null \
    | awk -F: '{ n += $NF } END { print n + 0 }')
if [ "$n" -eq 1 ]; then
    pass "clock.advanceContent has exactly 1 call site"
else
    fail "clock.advanceContent has $n call sites (expected 1)"
    grep -rn 'clock\.advanceContent(' SwiftPili/ --include='*.swift' >&2
fi

# ── 3. Exactly ONE place reports rendered content to the session, and it is the
# MainActor drain tick.
n=$(count_in 'renderedContentDidAdvance(' "$RENDERER")
if [ "$n" -eq 1 ]; then
    pass "the renderer reports rendered content from exactly 1 place"
else
    fail "renderedContentDidAdvance appears $n times in $RENDERER (expected 1)"
fi

# ── 4. The feeder cannot reach the clock. This is the load-bearing one: it is
# what makes a second writer unreachable rather than merely unused.
for sym in 'AudioPullSource' 'renderedContentDidAdvance' 'advanceContent' 'MediaEngineSession'; do
    # A doc-comment mention is fine; a reference in code is not.
    if [ "$(code_match_count "$sym" "$FEEDER")" -gt 0 ]; then
        fail "$FEEDER references '$sym' in CODE — the feeder must not be able to reach the clock"
    else
        pass "$(basename "$FEEDER") has no CODE reference to $sym"
    fi
done

# ── 5. No downcast anywhere on the audio ownership path. This is the exact shape
# that produced two clocks the first time.
for f in "$RENDERER" "$FEEDER" "$ADMISSION"; do
    n=$(code_match_count 'as\?' "$f")
    if [ "$n" -eq 0 ]; then
        pass "no 'as?' downcast in $(basename "$f")"
    else
        fail "$n 'as?' downcast(s) in $f"
    fi
done

# ── 6. The realtime render block must not be handed the feeder, the gate or the
# PCM supply. Its whole safety argument is that it touches only the lock-free ring
# and an atomic float box.
block=$(sed -n '/nonisolated private static func makeSourceNode(/,/^    }$/p' "$RENDERER")
if [ -z "$block" ]; then
    fail "could not find makeSourceNode in $RENDERER — this gate needs updating"
else
    for sym in 'AudioRingFeeder' 'AudioFeederGate' 'AudioSupplySource' 'OSAllocatedUnfairLock' 'withLock'; do
        if [ "$(text_match_count "$sym" "$block")" -gt 0 ]; then
            fail "makeSourceNode's render block references '$sym' — no locks on the RT path"
        fi
    done
    pass "the render block references no feeder, gate, supply or lock"
fi

# ── 7. No MainActor waiting on audio work. The player's main path carries no
# blocking primitives, and the ownership move is not permitted an exception: the
# feeder is cut over by admission + generation under the gate's mutex, which is a
# synchronous guarantee, so there is nothing for a barrier to add. A `.sync` here
# would be a main-thread block waiting on a PCM pull.
for f in "$RENDERER" "$FEEDER" "$ADMISSION"; do
    for pattern in '\.sync[[:space:]]*\{' 'DispatchSemaphore' 'Thread\.sleep' 'objc_sync' '\.wait\(' 'NSCondition'; do
        if [ "$(code_match_count "$pattern" "$f")" -gt 0 ]; then
            fail "$(basename "$f") contains a blocking primitive matching '$pattern' — MainActor must never wait on the feeder"
        fi
    done
done
pass "no queue barrier or other blocking primitive on the audio ownership path"

# ── 8. The drain report must read ONE snapshot, not two independent values.
if [ "$(code_match_count 'drainSnapshot\(channels:' "$RENDERER")" -gt 0 ]; then
    pass "the drain report reads a single cursor-pair snapshot"
else
    fail "the drain report no longer uses drainSnapshot — the torn-pair hazard is back"
fi
# Comments may name it (the doc comment on PCMRingDrainSnapshot explains why it
# was removed); only a reference in CODE is the regression.
if [ "$(code_match_count 'slotPulledFrames' "$RENDERER")" -gt 0 ]; then
    fail "'slotPulledFrames' is back in $RENDERER — that mirror of the ring write cursor is the torn pair"
else
    pass "no hand-maintained mirror of the ring write cursor"
fi

# ── 9. The PCM store is not reachable as MainActor-isolated state again.
if grep -q 'private var audioTimelineBuffer = AudioTimelineBuffer(' "$SESSION"; then
    fail "$SESSION holds the PCM store as MainActor state again — the feeder cannot pull from it"
else
    pass "the session's PCM store is behind AudioSupplySource"
fi

echo
if [ "$failures" -eq 0 ]; then
    echo "audio clock ownership: OK"
    exit 0
fi
echo "audio clock ownership: $failures invariant(s) broken" >&2
exit 1
