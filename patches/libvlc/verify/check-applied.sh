#!/bin/bash
# check-applied.sh <path-to-vlc-checkout>
#
# Asserts that every patch in patches/libvlc/ is present in the VLC source tree
# AND landed in the right place. Run it after build-libvlc.sh, before trusting
# the xcframework.
#
# Why this exists, twice over:
#
#  1. build-libvlc.sh logs "Skipped (already applied or conflicts)" and KEEPS
#     BUILDING. One message, two very different meanings, and a successful build
#     either way.
#
#  2. `git apply` places a hunk by proximity when its context is ambiguous.
#     ControlSetTime and ControlSetPosition end in byte-identical blocks, so a
#     short-context hunk generated against a tree with different line numbers
#     lands in the WRONG function -- and the result still compiles. That shipped
#     once: ControlSetTime got the old behaviour (0003 a silent no-op) while
#     ControlSetPosition got `i_start + val` with val a double position in
#     [0,1], truncated to 0.
set -uo pipefail
V="${1:?usage: check-applied.sh /path/to/vlc}"
CLOCK="$V/src/clock/clock.c"
INPUTCLOCK="$V/src/clock/input_clock.c"
INPUT="$V/src/input/input.c"
HTTPFILE="$V/modules/access/http/file.c"
ESOUT="$V/src/input/es_out.c"
AOUTDEC="$V/src/audio_output/dec.c"
AOUTH="$V/include/vlc_aout.h"
AOUTFILT="$V/src/audio_output/filters.c"
fail=0
ok()   { printf '  ✅ %s\n' "$1"; }
bad()  { printf '  ❌ %s\n' "$1"; fail=1; }

[ -f "$CLOCK" ] && [ -f "$INPUTCLOCK" ] && [ -f "$INPUT" ] && [ -f "$HTTPFILE" ] && [ -f "$ESOUT" ] && [ -f "$AOUTDEC" ] && [ -f "$AOUTH" ] && [ -f "$AOUTFILT" ] || { echo "not a VLC tree: $V" >&2; exit 2; }

echo "0002 — clock: pause delay on every live context"
if [ "$(grep -c context_apply_pause_delay "$CLOCK")" = 3 ]; then
  ok "context_apply_pause_delay: definition + 2 call sites"
else
  bad "expected 3 occurrences of context_apply_pause_delay, found $(grep -c context_apply_pause_delay "$CLOCK")"
fi
grep -q 'vlc_list_foreach(ctx, &main_clock->prev_contexts, node)' "$CLOCK" \
  && ok "prev_contexts are iterated on resume" \
  || bad "prev_contexts loop missing — the delay still hits only the current context"

echo "0004 — clock: rate change on every live context"
grep -q 'context_change_rate' "$CLOCK" \
  && ok "context_change_rate present" \
  || bad "context_change_rate missing — video runs one rate change behind after a seek"
if awk '/^static void vlc_clock_master_update_coeff/,/^}/' "$CLOCK" | grep -q 'context_change_rate(prev_ctx, rate)'; then
  ok "prev_contexts get the new rate, inside vlc_clock_master_update_coeff"
else
  bad "the prev_contexts rate loop is not in vlc_clock_master_update_coeff — hunk misplaced"
fi

echo "0009 — clock: hold the mapping across the rate-change transient (F19)"
grep -q 'RATE_SETTLE_WINDOW' "$CLOCK" \
  && ok "RATE_SETTLE_WINDOW present" \
  || bad "RATE_SETTLE_WINDOW missing — 2× press/release still jerks the video (F19)"
# The hold must live inside the coeff estimator, next to the reset it replaces.
if awk '/^static void vlc_clock_master_update_coeff/,/^}/' "$CLOCK" | grep -q 'rate_change_system'; then
  ok "the settle-window hold is inside vlc_clock_master_update_coeff"
else
  bad "rate_change_system not in vlc_clock_master_update_coeff — 0009 hunk misplaced"
fi

echo "0010 — input_clock: re-anchor forward stream gaps without a discontinuity (F20)"
# The fix splits the gap branch on sign: forward gap -> re-anchor (no
# discontinuity, no audio flush); backward jump -> hard reset. Assert the
# `discontinuity = backward` form lives inside input_clock_Update, not the
# stock `discontinuity = true`.
if awk '/^vlc_tick_t input_clock_Update/,/^}/' "$INPUTCLOCK" | grep -q 'discontinuity = backward'; then
  ok "forward gaps re-anchor without a discontinuity, inside input_clock_Update"
else
  bad "no 'discontinuity = backward' in input_clock_Update — 0010 missing/misplaced; near-EOF audio still cuts (F20)"
fi

echo "0011 — aout: play out the buffered tail on EOF, don't drop it (F20/F21)"
grep -q 'stream_ReplayDiscontinuity' "$AOUTDEC" \
  && ok "stream_ReplayDiscontinuity helper present" \
  || bad "stream_ReplayDiscontinuity missing — 0011 not applied; silent tail + EOF freeze (F20/F21)"
# The old drop MUST be gone: if 'losing %' still logs, the tail is still dropped.
if grep -q 'losing %' "$AOUTDEC"; then
  bad "the 'losing N us of audio' drop is still in dec.c — 0011 missing/misplaced; tail still dropped"
else
  ok "the tail-dropping FIXME is gone"
fi
# Placement: the replay must be wired into the EOF drain path, not just defined.
if awk '/^void vlc_aout_stream_Drain/,/^}/' "$AOUTDEC" | grep -q 'stream_ReplayDiscontinuity'; then
  ok "vlc_aout_stream_Drain replays the tail at EOF"
else
  bad "vlc_aout_stream_Drain does not call stream_ReplayDiscontinuity — 0011 hunk misplaced; tail still lost at EOF"
fi

echo "0012 — aout: optional change_rate hook (audio-rate rework core)"
grep -q 'change_rate' "$AOUTH" \
  && ok "change_rate hook declared in vlc_aout.h" \
  || bad "change_rate missing from vlc_aout.h — 0012 not applied; rate-aware modules impossible"
if awk '/^void vlc_aout_stream_ChangeRate/,/^}/' "$AOUTDEC" | grep -q 'change_rate'; then
  ok "vlc_aout_stream_ChangeRate forwards to the module"
else
  bad "vlc_aout_stream_ChangeRate does not forward change_rate — 0012 hunk misplaced"
fi
# Module-owned rate: ChangeRate must sync timing.rate immediately (device
# 2026-07-18: stale timing.rate=1 + 2× content PTS → instant_coeff ≈ 0.5).
if awk '/^void vlc_aout_stream_ChangeRate/,/^}/' "$AOUTDEC" | grep -q 'timing.rate'; then
  ok "ChangeRate syncs timing.rate for module-owned rate TimingReports"
else
  bad "ChangeRate does not touch timing.rate — pitch-engine hold-2× clock will unstable"
fi
if awk '/parse user filter lists/,/scaletempo/' "$AOUTFILT" | grep -q 'aout-handles-rate'; then
  ok "aout_FiltersNew skips scaletempo when the module handles rate"
else
  bad "no 'aout-handles-rate' guard before scaletempo — 0012 hunk misplaced; core still stretches"
fi
# L1 ownership (T2 static twin): module-owned rate must not promote resampler
# to rate_filter, and FiltersPlay must not drop when rate_filter is NULL.
if grep -qE 'rate_filter == NULL && !aout_handles_rate' "$AOUTFILT"; then
  ok "L1: rate_filter promotion gated with !aout_handles_rate"
else
  bad "L1: no 'rate_filter == NULL && !aout_handles_rate' — resampler may double-stretch (T2)"
fi
PLAYREGION="$(awk '/^block_t \*aout_FiltersPlay/,/^}/' "$AOUTFILT")"
# Match executable `goto drop;` only — comments may mention stock "goto drop".
if printf '%s' "$PLAYREGION" | grep -qE '^[[:space:]]*goto[[:space:]]+drop[[:space:]]*;'; then
  bad "L1: aout_FiltersPlay still has goto drop — null rate_filter silences audio (T2)"
else
  ok "L1: aout_FiltersPlay has no executable goto drop"
fi
if printf '%s' "$PLAYREGION" | grep -qE 'if \(rate_filter != NULL\)'; then
  ok "L1: aout_FiltersPlay uses if (rate_filter != NULL) (raw PCM when module owns rate)"
else
  bad "L1: aout_FiltersPlay missing if (rate_filter != NULL) branch — T2 ownership incomplete"
fi

echo "0013 — avsamplebuffer: in-place AVAudioEngine pitch-corrected backend (F19/F20/F21)"
# 0013 is an IN-PLACE edit of tracked avsamplebuffer.m.
#
# Structural contract 2026-07-19 K2:
#   hist-r1 vetoed drop+live; device also vetoed TimePitch rate applicator (grit).
#   DEEP raw content reserve (rate-agnostic) + JIT module scaletempo at CURRENT
#   rate into SHALLOW wall schedule. changeRate = setTempoRate only (NO drop,
#   NO history restretch, NO AVAudioUnitTimePitch as rate path).
AVSB="$V/modules/audio_output/apple/avsamplebuffer.m"
if grep -q 'VLCAudioEngine' "$AVSB" && grep -q 'aout-handles-rate' "$AVSB" \
   && grep -q 'openTempoFilterLocked' "$AVSB"; then
  ok "avsamplebuffer.m has VLCAudioEngine + JIT scaletempo + aout-handles-rate"
else
  bad "avsamplebuffer.m missing AVAudioEngine/JIT-scaletempo backend — 0013 not applied"
fi
if grep -q 'JIT-scaletempo K2\|feedWallFromRawLocked' "$AVSB" \
   && grep -q 'kAVAEMaxWallSec' "$AVSB" && grep -q 'kAVAEMaxRawSec' "$AVSB"; then
  ok "engine: JIT-scaletempo K2 (deep raw + shallow wall, no TimePitch rate path)"
elif grep -q 'applyTimePitchRateLocked\|AVAudioUnitTimePitch' "$AVSB" \
   && grep -q 'timePitch.rate\|_timePitch\.rate' "$AVSB"; then
  bad "engine still on abandoned TimePitch rate path — rebuild to JIT-scaletempo K2"
elif grep -q 'dropScheduledNode\|restretchHistory' "$AVSB"; then
  bad "engine still on abandoned drop+live path — rebuild to JIT-scaletempo K2"
else
  bad "engine missing JIT-scaletempo K2 markers — 0013 incomplete"
fi
if awk '/^Open\(vlc_object_t/,/^}/' "$AVSB" | grep -q 'avsb-pitch-engine'; then
  ok "Open() selects the engine backend via the avsb-pitch-engine var"
else
  bad "no 'avsb-pitch-engine' branch in Open — 0013 hunk misplaced; engine unreachable"
fi
if grep -q 'AVSampleBufferAudioRenderer' "$AVSB" && grep -q '@interface VLCAVSample' "$AVSB"; then
  ok "the stock VLCAVSample backend is preserved (toggle-off default)"
else
  bad "VLCAVSample backend missing — 0013 clobbered the default path"
fi
if grep -q 'aout_DrainedReport' "$AVSB" && grep -q '_draining' "$AVSB"; then
  ok "stock/engine drain path reports aout_DrainedReport (F20 L2)"
else
  bad "no aout_DrainedReport/_draining in avsamplebuffer — 0013 stock drain missing"
fi
if grep -q 'kAVAEMaxWallSec' "$AVSB" && grep -q 'kAVAEMaxRawSec' "$AVSB"; then
  ok "engine: shallow wall + deep raw depth constants present"
else
  bad "engine missing kAVAEMaxWallSec/kAVAEMaxRawSec — queue depths not configured"
fi
if grep -q '_epoch' "$AVSB"; then
  ok "engine: completion epoch present (cross-media / late completion safety)"
else
  bad "engine missing _epoch — late scheduleBuffer completions unsafe"
fi
if grep -q 'changeRate' "$AVSB" && grep -q 'setTempoRateLocked' "$AVSB"; then
  ok "engine: changeRate → setTempoRateLocked path present"
else
  bad "engine missing changeRate → setTempoRateLocked wiring"
fi
# K2.6 may call [_player stop] only inside residual WALL clear (epoch bump +
# wall schedule zero). That is allowed. Forbid abandoned drop+live / restretch
# and any raw drop on the rate edge. Still require setTempoRate path.
if awk '/changeRate:\(float\)rate/,/^}/' "$AVSB" | grep -q 'dropScheduledNode\|restretchHistory'; then
  bad "engine changeRate still has dropScheduledNode/restretchHistory — abandoned path"
elif awk '/changeRate:\(float\)rate/,/^}/' "$AVSB" | grep -q 'dropRawLocked\|\[self dropRaw'; then
  bad "engine changeRate drops raw reserve — violates JIT rate-agnostic bank"
else
  ok "engine: changeRate is no-drop-raw JIT (wall residual clear may stop player)"
fi
if grep -q '_muted' "$AVSB" && grep -q 'cubicGainForVolume' "$AVSB"; then
  ok "engine: sticky mute + cubic mixer gain"
else
  bad "engine missing _muted/cubicGain — mute/volume path incomplete"
fi
if grep -q '_startDate' "$AVSB" && grep -q 'startAtTimeLocked' "$AVSB"; then
  ok "K2: play(date) start alignment present"
else
  bad "K2: missing play(date)/_startDate start alignment"
fi
if grep -q '_contentConsumed' "$AVSB" && grep -q 'aout_TimingReport' "$AVSB"; then
  ok "K2: TimingReport uses content consumed (not wall samples alone)"
else
  bad "K2: TimingReport missing content-consumed accounting"
fi
if grep -q 'registerObservers' "$AVSB" && grep -q 'aout_RestartRequest' "$AVSB"; then
  ok "K2: session interruption/route/config lifecycle present"
else
  bad "K2: missing session/route/engine-config observers"
fi
if grep -q 'JIT-scaletempo K2' "$AVSB"; then
  ok "K2: log fingerprint for device soak (JIT-scaletempo K2)"
else
  bad "K2: missing K2 log fingerprint — binary/patch may be stale"
fi
if grep -q '1x-raw-bypass\|K2.1\|K2.2\|K2.3' "$AVSB"; then
  ok "K2.1+: 1x raw bypass markers present"
else
  bad "K2.1+: missing 1x-raw-bypass markers"
fi
# K2.2 (2026-07-19): source-confirmed scaletempo fixes
#   pitch-jit-stale-buffer — reopen tempo on unity cross (K2.6: 1→2 only)
#   pitch-jit-priming-offset — attribute non-unity wall as wallFrames * rate
if grep -q 'JIT-scaletempo K2.2\|JIT-scaletempo K2.3\|JIT-scaletempo K2.6\|unityCross\|unity-cross-reopen\|1to2-tempo-reopen' "$AVSB"; then
  ok "K2.2+: unity-cross / 1→2 reopen fingerprint (pitch-jit-stale-buffer)"
else
  bad "K2.2+: missing unity-cross reopen — 2nd+ hold may replay stale buf_queue"
fi
if awk '/changeRate:\(float\)rate/,/^}/' "$AVSB" | grep -q 'openTempoFilterLocked'; then
  ok "K2.2+: changeRate can reopen tempo (openTempoFilterLocked present)"
else
  bad "K2.2+: changeRate does not call openTempoFilterLocked — stale-buffer fix missing"
fi
# K2.6: reopen only when engaging non-unity (1→2), not on 2→1
if awk '/changeRate:\(float\)rate/,/^}/' "$AVSB" | grep -q 'unityCross && !nextUnity\|!nextUnity && self->_fmtValid\|!nextUnity && _fmtValid'; then
  ok "K2.6: tempo reopen gated to 1→2 only (!nextUnity)"
else
  bad "K2.6: tempo reopen not gated to 1→2 — 2→1 may still reopen (release latency)"
fi
if grep -q 'pitch-jit-priming-offset\|wall\*rate\|attrContent' "$AVSB" \
   && grep -q 'lroundf((float)wallFrames \* rate)' "$AVSB"; then
  ok "K2.2: wall*rate content attribution (pitch-jit-priming-offset)"
else
  bad "K2.2: missing wall*rate content attribution — priming A/V offset unfixed"
fi
# K2.3 FEED-FIX (2026-07-19): raw bank covers inter-arrival; no drop in normal band
# K2.4 raised MaxRaw 8→12 / HardRaw 12→18 (same policy class; larger 2× runway).
if grep -q 'kAVAEHardRawSec' "$AVSB" \
   && grep -qE 'kAVAEMaxRawSec = (8|12)' "$AVSB"; then
  ok "K2.3+: raw bank MaxRaw (8s|12s) + HardRaw ceiling present"
else
  bad "K2.3+: missing kAVAEHardRawSec / MaxRaw=8|12 — FEED-FIX not applied (cyclic underrun risk)"
fi
if grep -q 'reason=hard_ceiling\|hard_ceiling' "$AVSB" \
   && grep -q 'RAW_HIGH' "$AVSB" \
   && grep -q 'no-drop-band\|FEED-FIX' "$AVSB"; then
  ok "K2.3: no-drop-band + hard_ceiling DROP + RAW_HIGH fingerprints"
else
  bad "K2.3: missing FEED-FIX policy fingerprints — drop-newest may still punch holes"
fi
if awk '/enqueueRawLocked:/,/^}/' "$AVSB" | grep -q '_rate \* 4'; then
  bad "K2.3: enqueueRawLocked still has rate*4 hard drop — FEED-FIX incomplete"
else
  ok "K2.3: no legacy rate*4 drop in enqueueRawLocked"
fi
# K2.4 (2026-07-19): TimingReport hold across underrun + larger 2× bank
#   Post-hold A/V desync: frozen audio_ts during underrun + refill ratio spike.
if grep -q 'TIMING_HOLD' "$AVSB" && grep -q 'TIMING_RESUME' "$AVSB" \
   && grep -q '_timingResume' "$AVSB"; then
  ok "K2.4: TIMING_HOLD / TIMING_RESUME + _timingResume present"
else
  bad "K2.4: missing TimingReport hold — post-hold A/V desync class unfixed"
fi
if grep -q 'kAVAEMaxRawSec = 12' "$AVSB" && grep -q 'kAVAEHardRawSec = 18' "$AVSB"; then
  ok "K2.4: raw bank MaxRaw=12s HardRaw=18s"
else
  bad "K2.4: missing MaxRaw=12 / HardRaw=18 — 2× bank headroom not applied"
fi
if grep -q 'JIT-scaletempo K2.4\|JIT-scaletempo K2.5\|JIT-scaletempo K2.6\|timing-hold raw=12s' "$AVSB"; then
  ok "K2.4+: start/changeRate fingerprint present (K2.4+)"
else
  bad "K2.4+: missing K2.4+ log fingerprint — binary/patch may be stale"
fi
if grep -q 'RATE_LOW_BANK' "$AVSB"; then
  ok "K2.4: RATE_LOW_BANK warn on thin engage present"
else
  bad "K2.4: missing RATE_LOW_BANK — engage-into-empty diagnostics incomplete"
fi
# K2.5 (2026-07-19): core NotifyTiming must not rewrite module content PTS
# when change_rate owns rate (wall*rate invents progress across underrun).
if awk '/^void vlc_aout_stream_NotifyTiming/,/^}/' "$AOUTDEC" | grep -q 'change_rate == NULL'; then
  ok "K2.5: NotifyTiming skips wall*rate rewrite when change_rate set"
else
  bad "K2.5: NotifyTiming still always rewrites audio_ts — post-hold desync class"
fi
if grep -q 'content-pts-no-rewrite\|K2.5 FEED-FIX\|K2.6 FEED-FIX\|JIT-scaletempo K2.5\|JIT-scaletempo K2.6' "$AVSB"; then
  ok "K2.5+: module fingerprint content-pts-no-rewrite present"
else
  bad "K2.5+: missing content-pts-no-rewrite / K2.5+ fingerprint — binary/patch may be stale"
fi
# K2.6 (2026-07-19): residual wall clear on material rate change + 1→2-only reopen
if grep -q 'clearWallResidualLockedForPrevRate\|RESIDUAL_CLEAR' "$AVSB" \
   && grep -q 'residual-clear\|JIT-scaletempo K2.6' "$AVSB"; then
  ok "K2.6: residual-clear helper + RESIDUAL_CLEAR / K2.6 fingerprint"
else
  bad "K2.6: missing residual-clear / RESIDUAL_CLEAR / K2.6 fingerprint"
fi
if awk '/changeRate:\(float\)rate/,/^}/' "$AVSB" | grep -q 'clearWallResidualLockedForPrevRate\|RESIDUAL_CLEAR'; then
  ok "K2.6: changeRate calls residual wall clear"
else
  bad "K2.6: changeRate missing residual wall clear — old-scale tail on rate edge"
fi
if awk '/^static void SlaveDemuxToEnd/,/^}/' "$INPUT" | grep -q 'SLAVE_DRAIN_MAX_ITER'; then
  ok "SlaveDemuxToEnd is defined with a bounded drain loop"
else
  bad "SlaveDemuxToEnd definition missing or incomplete — 0014 not applied; slave drain unbounded/missing"
fi
# Placement: on master EOF, drain slaves BEFORE es_out_Eos so the audio decoder
# fifo still accepts blocks. A misplaced call after Eos (or only a dead helper)
# leaves the longer DASH audio slave undemuxed.
# Match es_out_Eos( (the call), not bare es_out_Eos — the F20 comment also names it.
EOFREGION="$(awk '/msg_Dbg\( p_input, "EOF reached" \)/{f=1} f{print} /es_out_Eos\(/{exit}' "$INPUT")"
if grep -q 'SlaveDemuxToEnd' <<<"$EOFREGION"; then
  ok "master EOF path calls SlaveDemuxToEnd before es_out_Eos"
else
  bad "SlaveDemuxToEnd not called before es_out_Eos on master EOF — 0014 hunk misplaced; slave tail still undemuxed (F20)"
fi

echo "0015 — input: audio-slave demux lead (hold-2× feed reservoir)"
# Standing content-time lead for non-sub slaves so the aout bank can hold more
# than one audio fragment. Default 0 = stock; app soak uses 6000 (was 8000 —
# 8s + fragment overshoot parked on MaxRaw/RAW_HIGH). Lead is cached once per
# input (priv->slave_audio_lead_ms); SlaveDemux must not var_Inherit each pass.
LIBVLC_MODULE="$V/src/libvlc-module.c"
INPUT_INTERNAL="$V/src/input/input_internal.h"
if grep -q 'slave-audio-lead-ms' "$INPUT"; then
  ok "0015: slave-audio-lead-ms present in input.c"
else
  bad "0015: slave-audio-lead-ms missing from input.c — mid-hold 2× bank still demux-bound"
fi
if [ -f "$INPUT_INTERNAL" ] && grep -q 'slave_audio_lead_ms' "$INPUT_INTERNAL"; then
  ok "0015: priv caches slave_audio_lead_ms (input_internal.h)"
else
  bad "0015: slave_audio_lead_ms missing from input_internal.h — hot-path var not cached"
fi
if grep -q 'priv->slave_audio_lead_ms' "$INPUT"; then
  ok "0015: input create / SlaveDemux use priv->slave_audio_lead_ms"
else
  bad "0015: priv->slave_audio_lead_ms not written/read in input.c"
fi
# Hot path: SlaveDemux must consume the cached field, not re-walk the object tree.
if awk '/^static void SlaveDemux/,/^}/' "$INPUT" | grep -q 'slave_audio_lead_ms\|slave-audio-lead-ms'; then
  ok "0015: lead used inside SlaveDemux"
else
  bad "0015: lead not inside SlaveDemux — hunk misplaced"
fi
if awk '/^static void SlaveDemux/,/^}/' "$INPUT" | grep -q 'var_InheritInteger'; then
  bad "0015: SlaveDemux still calls var_InheritInteger — lead must be cached per input"
else
  ok "0015: SlaveDemux does not var_Inherit (cached per input)"
fi
if awk '/^static void SlaveDemux/,/^}/' "$INPUT" | grep -q 'b_slave_sub'; then
  ok "0015: non-sub gate (b_slave_sub) present in SlaveDemux lead path"
else
  bad "0015: no b_slave_sub gate — subtitle slaves may demux ahead"
fi
if awk '/^static void SlaveDemux/,/^}/' "$INPUT" | grep -q 'b_can_pace_control'; then
  ok "0015: pace-control gate present (live/non-pace masters stay stock)"
else
  bad "0015: no b_can_pace_control gate — lead may fire on live masters"
fi
if awk '/^static void SlaveDemux/,/^}/' "$INPUT" | grep -q 'i_target\|i_time + VLC_TICK_FROM_MS'; then
  ok "0015: catch-up target is master_time + lead (i_target)"
else
  bad "0015: SlaveDemux still caps at bare i_time only — lead not applied"
fi
if [ -f "$LIBVLC_MODULE" ] && grep -q 'slave-audio-lead-ms' "$LIBVLC_MODULE"; then
  ok "0015: libvlc-module registers slave-audio-lead-ms (default 0)"
else
  bad "0015: slave-audio-lead-ms not registered in libvlc-module.c — instance arg ignored"
fi

echo "0003 — input: seek slaves to the requested time"
grep -q 'SlaveSeek( input_thread_t \*p_input, const vlc_tick_t \*pi_requested_time )' "$INPUT" \
  && ok "SlaveSeek takes a requested time" \
  || bad "SlaveSeek signature not patched"

# Placement is the whole point: the two call sites are interchangeable to `git
# apply`, and swapping them compiles cleanly while doing nothing.
if awk '/^static int ControlSetTime/,/^}/' "$INPUT" | grep -q 'SlaveSeek( p_input, &i_requested )'; then
  ok "ControlSetTime passes the REQUESTED time"
else
  bad "ControlSetTime does not pass the requested time — hunk misplaced, 0003 is a no-op"
fi
if awk '/^static int ControlSetPosition/,/^}/' "$INPUT" | grep -q 'SlaveSeek( p_input, NULL )'; then
  ok "ControlSetPosition passes NULL"
else
  bad "ControlSetPosition does not pass NULL — hunk misplaced"
fi
if awk '/^static int ControlSetPosition/,/^}/' "$INPUT" | grep -q 'i_requested'; then
  bad "ControlSetPosition computes i_requested from a POSITION (0..1) — hunks are swapped"
fi

echo "0005 — access/http: retry without the precondition on 412"
if awk '/^int vlc_http_file_seek/,/^}/' "$HTTPFILE" | grep -q "status == 412"; then
  ok "the 412 retry is inside vlc_http_file_seek"
else
  bad "no 412 retry — a CDN with unstable ETags kills every seek"
fi
awk '/^static int vlc_http_file_req/,/^}/' "$HTTPFILE" | grep -q '!file->no_precondition' \
  && ok "vlc_http_file_req honours no_precondition" \
  || bad "the no_precondition guard is not in vlc_http_file_req — hunk misplaced"

echo "0008 — es_out: the master source owns the program PCR"
# Placement is the whole point: EsOutVaControlLocked is one giant switch, and a
# short-context hunk could land the guard in a byte-similar neighbouring case.
# Assert the master guard sits between `case ES_OUT_SET_PCR:` and the
# `i_last_pcr = i_pcr;` it must precede, AND that it is gated on ES_OUT_SET_PCR
# (so ES_OUT_SET_GROUP_PCR multi-program muxes are untouched).
PCRREGION="$(awk '/case ES_OUT_SET_PCR:/{f=1} f{print} /i_last_pcr = i_pcr;/{exit}' "$ESOUT")"
if grep -q 'source != input_priv(p_sys->p_input)->master' <<<"$PCRREGION"; then
  ok "the master-source PCR guard is inside the ES_OUT_SET_PCR case"
else
  bad "no master-source guard before i_last_pcr = i_pcr — 0008 missing or misplaced; slave PCR still perturbs the master clock"
fi
if grep -q 'i_query == ES_OUT_SET_PCR &&' <<<"$PCRREGION"; then
  ok "the guard is gated on ES_OUT_SET_PCR (GROUP_PCR untouched)"
else
  bad "the guard is not gated on i_query == ES_OUT_SET_PCR — it would wrongly drop GROUP_PCR too"
fi

# 0007 (avsamplebuffer cap) was reverted 2026-07 — its standing backpressure
# destabilised the master clock. If a stale copy lingers in the fork's
# scripts/patches, flag it: the reverted cap must NOT be in the tree.
AVSB="$V/modules/audio_output/apple/avsamplebuffer.m"
if [ -f "$AVSB" ] && grep -q 'downstreamAheadLocked' "$AVSB"; then
  bad "0007 is STILL applied — it was reverted; delete scripts/patches/0007-* and rebuild"
fi

# 0008 lands in the native VideoToolbox decoder, not one of the files above;
# build-libvlc.sh keeps building when a patch fails to apply, so verify it — a
# dropped 0008 sends AV1 back to the black FFmpeg-VA path (F17).
echo "0008 — videotoolbox: native AV1 hardware decode (F17)"
AV1DEC="$V/modules/codec/videotoolbox/decoder.c"
if [ -f "$AV1DEC" ] && grep -q 'CopyDecoderExtradataAV1' "$AV1DEC"; then
  ok "native AV1 decode present"
else
  bad "0008 not applied — AV1 still routes to the black FFmpeg-VA path (F17)"
fi

echo
if [ "$fail" = 0 ]; then
  echo "✅ all patches present and correctly placed"
else
  echo "❌ the tree is NOT what you think it is — do not ship this build"
  echo "   reset with: git -C $V checkout -- src/clock/clock.c src/input/input.c modules/access/http/file.c"
  echo "   then re-run build-libvlc.sh"
fi
exit $fail
