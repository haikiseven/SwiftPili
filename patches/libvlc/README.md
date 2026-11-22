# libVLC patches

Patches against the libVLC 4.0.0-dev tree that `SwiftVLC`'s `libvlc.xcframework`
is built from. They are **not** applied by the Xcode/SPM build. They only reach
the app because `project.yml` and `Package.swift` now depend on a **local**
SwiftVLC checkout that builds its own xcframework — a published SwiftVLC release
ships a *prebuilt* binary and would silently ignore everything here.

`SwiftVLC`'s `scripts/build-libvlc.sh` applies every `*.patch` in
`scripts/patches/` (glob order) to its VLC checkout before `configure`. Drop
these files in there:

```sh
cp SwiftPili/patches/libvlc/*.patch  ../SwiftVLC/scripts/patches/
```

Numbered from `0002` so they sort after SwiftVLC's own
`0001-chromecast-hardening.patch`. Do **not** use `--patches-dir=` to point at
this directory: that flag *replaces* the patch set, so it would drop the
chromecast patch entirely.

> ⚠️ **After every build, run the checker.** `build-libvlc.sh` treats a failed
> patch as non-fatal, and `git apply` can place an ambiguous hunk in the wrong
> function — which still compiles. A green build proves nothing:
>
> ```sh
> ./patches/libvlc/verify/check-applied.sh ../SwiftVLC/scripts/.build-libvlc/vlc
> ```
>
> ⚠️ **`git apply --check` is not a build.** It proves the context lines match, not
> that the result compiles. A hunk that references a local variable declared
> *above* its context will apply cleanly and then fail to build — this happened
> with `0003` against a checkout whose `ControlSetPosition` predated the
> `i_length` normalisation. Patches here must not depend on identifiers they do
> not introduce, and must be compiled against the tree that will build them:
>
> ```sh
> gcc -fsyntax-only -DHAVE_CONFIG_H -I<vlc>/src/input -I<vlc>/include -I<vlc>/src \
>     <vlc>/src/input/input.c
> ```
>
> ⚠️ `build-libvlc.sh` **silently skips** a patch that fails `git apply --check`
> ("Skipped (already applied or conflicts)") and keeps building. After bumping
> `VLC_HASH`, read the build log for `Applied:` lines — a dropped patch
> reintroduces the bug with no other symptom.

| Patch | Applies to | Fixes | Design doc |
|---|---|---|---|
| `0002-clock-apply-pause-delay-to-all-live-contexts.patch` | `07dff93`, and `c833c4be0` (the commit `build-libvlc.sh` pins) — `src/clock/clock.c` and `test/src/clock/clock.c` are byte-identical at both | Video freezes for the pause duration on the first resume after any seek | F12 / P4.1 |
| `0003-input-seek-slaves-to-the-requested-time.patch` | `c833c4be0` (verified with `git apply --check`) | Every seek resumes at the fragment boundary and crawls to the target at 1×; DASH audio slaves also land a whole fragment early | F5 / P4.2 |
| `0004-clock-apply-rate-change-to-all-live-contexts.patch` | `c833c4be0` + `0002` (applies, correct placement, 0 compile errors) | Playback-speed changes reach only the current clock context, so video runs one rate change behind audio for seconds after any seek | F14 / P4.3 |
| `0005-access-http-retry-without-precondition-on-412.patch` | `c833c4be0` (applies, correct placement, 0 compile errors) | Seeks and resumes fail outright on a CDN whose edges disagree about the ETag it issued (`412` to libVLC's `If-Match`) | F15 |
| `0006-avcodec-log-hwdec-rejection-reason.patch` | `c833c4be0` (+ fork hwfmts edit) | **Diagnostic only.** Logs *why* a hardware pixel format (e.g. VideoToolbox AV1) is rejected, which libVLC otherwise does silently. Keep or drop once the cause is known | F16 |
| `0008-es_out-master-source-owns-program-pcr.patch` | `c833c4be0` (applies with `git apply --check`, correct placement) | Audio runs ahead of video after an in-place `set_time` seek on DASH separate-slave streams: the audio slave's fragment-boundary PCR perturbs the shared master program clock | F18 |
| `0009-clock-hold-mapping-across-rate-change-transient.patch` | `c833c4be0` + `0002` + `0004` (applies with `git apply --check`, compiles, `verify/run.sh` PASS) | Press-and-hold 2× (and the release back to 1×): while the aout re-tempos its scaletempo filter it feeds the clock a stale system/stream ratio for ~1–2s, so the master clock `resetting … coefficient too unstable` repeatedly, each reset re-anchoring the offset and jerking the video with `picture displayed late`. Bounded settle-window holds the mapping through the transient | F19 |
| `0010-input_clock-re-anchor-forward-gaps-without-discontinuity.patch` | `c833c4be0` (applies with `git apply --check`, compiles, `verify/run.sh` PASS; touches only `src/clock/input_clock.c`, independent of the `clock.c` patches) | **Partial** near-EOF fix: stops the forward DASH timeline gap from forking a new clock context (which flushes the audio filter chain). Necessary but **not** sufficient for silent tail. Forward gaps re-anchor without the flush; backward jumps still hard-reset | F20 (partial) |
| `0011-aout-play-out-buffered-tail-on-eof.patch` | `c833c4be0` (`git apply --check`; `cc -fsyntax-only`; touches `src/audio_output/dec.c`) | Replay buffered DISCONTINUITY tail on EOF Drain instead of `losing N us of audio` (F20 branch + F21 stuck `draining`). Sole owner of `stream_ReplayDiscontinuity` / Drain-tail fix in `dec.c`. ⚠️ Device: path sometimes inert; not sole F20 cure | F20 / F21 (partial) |
| `0012-aout-change_rate-hook.patch` | `c833c4be0` + `0002`–`0011`, **strictly after 0011** (rebased 2026-07-26, P0.1; ordered apply verified on a scratch tree); `vlc_aout.h` + `dec.c` NotifyTiming/ChangeRate + `filters.c` | Optional `change_rate` + `aout-handles-rate`: skip scaletempo; **L1** do not promote resampler to `rate_filter`; `aout_FiltersPlay` raw passthrough when rate_filter NULL. Safe `var_Type` walk. **Does not** contain the 0011 `stream_ReplayDiscontinuity` / Drain body (0011 owns it). Product engine still **force-off** until device ladder | F19–F21 rework core |
| `0013-avsamplebuffer-pitch-corrected-rate-backend.patch` | `c833c4be0` (Obj-C; in-place `avsamplebuffer.m`) | Second backend: AVAudioEngine + **JIT scaletempo K2.6 FEED-FIX** (`avsb-pitch-engine`) + stock drain (F20). Deep raw **12s** always-accept + hard **18s** ceiling; TimingReport **hold** across underrun; **K2.7 (2026-09-29) sample-accurate TimingReport** — rendered player sample (`lastRenderTime` → `playerTimeForNodeTime`) mapped to content through the owned wall buffers, paired with render host time + `outputLatency` (stock `ca_Render` / mpv `ao_audiounit` shape), replacing the per-buffer `dataPlayedBack` staircase that reset the master clock (`coefficient too unstable`) — 96 ms steps on FLAC made video frames late; **K2.8** the 250 ms shallow window is measured against the RENDER head (was scheduled − playedBack, which silently lost the device output latency — 163 ms on Bluetooth starved the node between FLAC blocks) and the 10 Hz tick refills; `[avae-diag]` adds `aheadMs=` / `starve=`; **residual wall clear** on material rate change (`RESIDUAL_CLEAR` / epoch bump / wall-only player stop); tempo reopen **1→2 only**; shallow wall 250ms; wall*rate content; DROP only `hard_ceiling`. **Product default OFF**. R2 re-soak open (mid-hold bank + BC class) | F19–F21 (experimental) |
| `0014-input-drain-slaves-to-eof-after-master-eof.patch` | `c833c4be0` + **`0003` context** (`git apply --check` fails on pristine without 0003) | After master EOF, demux remaining slaves to EOF before `es_out_Eos` (DASH audio longer than video → undemuxed silent tail). Bound per-slave demux iters. Must be tracked + `check-applied` | F20 (demux root) |
| `0015-input-audio-slave-demux-lead.patch` | `c833c4be0` + `0002`–`0014` (regenerated 2026-07-26; ordered apply verified against the **pinned commit**, not a working tree) | Hold-2× feed reservoir: `SlaveDemux` non-sub slaves on pace-controlled masters catch up to `master_time + slave-audio-lead-ms` (default **0** = stock). Lead cached once per input (`priv->slave_audio_lead_ms`; no hot-path `var_Inherit`). App soak `--slave-audio-lead-ms=6000` (was 8000 — RAW_HIGH park). Does **not** raise pts_delay. **Device-partial:** 1× bank stands, short holds clean — engage/starve CLOSED; residual = `sustained-2x-supply`. No P4.3 FIXED | P4.3 feed root |

> **Status snapshot (2026-07-20):** Pitch engine is **opt-in, default OFF**. K2.6 module stack offline; **`0015` device-partial** closed engage/starve; long-2× residual is `sustained-2x-supply` (menu-2× discriminator soak). FORCE ON + `--slave-audio-lead-ms=6000` soak only. F20/F21 remain **OPEN**. P4.3 **OPEN** until R2 ear.

> **0013 packaging:** in-place edit of tracked `avsamplebuffer.m` (no new file / Makefile.am). Iterate: `git checkout -- modules/audio_output/apple/avsamplebuffer.m && git apply` + incremental make. **Do not** document media `:avsb-pitch-engine=` as live product API — aout opens at `Player()`; use instance `--avsb-pitch-engine` / `--no-avsb-pitch-engine` when re-enabled.

> **How the `0012` P0.1 rebase was made (2026-07-26)** (per the "document how the
> modifications were made" rule): the previous `0012` blob had been regenerated
> from a *dirty* tree, so it embedded `0011`'s entire `dec.c`
> `stream_ReplayDiscontinuity` extraction + EOF Drain replay verbatim. A clean
> ordered apply therefore conflicted at `src/audio_output/dec.c:222`,
> `build-libvlc.sh` logged a **non-fatal Skip**, and the green xcframework lost
> **all** of `0012` (`check-apply-matrix.sh` FAILed on the static overlap and on
> the ordered apply). Rebased mechanically, not by hand-editing hunk offsets:
> copy every patched file out of the built tree into `/tmp`, reverse-apply
> `0015`→`0002` to recover stock, then build two variants —
> **A** = stock + `0011`, **B** = stock + *old* `0012` (which contains 0011's
> `dec.c` edits plus 0012's own) — and take `diff -u A B` as the new body. Only
> `dec.c` changed; the `vlc_aout.h` and `filters.c` hunks are byte-identical to
> the old blob, so the **T2** L1 markers are untouched. Proof beyond
> `git apply --check`: a clean ordered apply `0002`→`0015` from stock reproduces
> the currently built tree **byte-for-byte** (`diff -q` over all 13 patched
> files; `modules/codec/avcodec/video.c` is excluded — the fork's
> `build-libvlc.sh` edits `hwfmts[]` in place, it is not a tracked patch), i.e.
> the rebase drops nothing and the result is the source that already compiled.
> Not re-verified: an actual `build-libvlc.sh` run from a pristine checkout, and
> any device behaviour.
>
> ⚠️ **Correction (2026-07-26 review):** the "recover stock by reverse-applying
> `0015`→`0002`" step above is *not* stock — it is the working tree minus our
> patches, so any drift the tree already carried is baked into the base. Re-run
> from the pinned commit instead (`git show c833c4be0:<file>`). Doing so found
> that **`0015` never applied to `c833c4be0` at all**: its hunks were captured
> from a tree with a stray extra blank line in `src/input/input.c` and
> `src/libvlc-module.c`, so `build-libvlc.sh` (`git apply --check`) would log a
> non-fatal *Skipped* and ship a green xcframework with none of `0015`.
> Regenerated mechanically (see the patch header). `0002`–`0014` were unaffected
> and applied to pinned stock cleanly, `0012` included.

> **Apply hygiene:** `build-libvlc.sh` **Skips** conflicting patches and continues. After every build run `check-applied.sh` **and** offline `verify/check-apply-matrix.sh` (inventory + P0.1 `0011`∩`0012` overlap + optional `--build-log` Skip fail + ordered apply on a scratch tree + **ordered apply on the pinned `c833c4be0` base via `git show`**). Prefer failing the build if any listed patch is Skipped.
>
> The scratch-tree stage alone is **not** sufficient: it normalises from the
> caller's working tree, so a patch whose geometry came from that same drifted
> tree round-trips green while failing on a fresh clone (exactly how `0015` hid).
> The pinned-base stage is the one that answers AC1. Override the commit with
> `VLC_BASE=<sha> ./verify/check-apply-matrix.sh <tree>` when the pin moves.

> How `0009` was derived (per the "document how the modifications were made"
> rule): fetched the pinned `c833c4be0` `src/audio_output/dec.c` +
> `src/input/decoder.c` and traced the rate change es_out → decoder →
> `vlc_aout_stream_ChangeRate` → the audio master's `vlc_clock_Update`, then read
> `src/clock/clock.c` `vlc_clock_master_update_coeff`. The reset is
> `instant_coeff = system_diff/stream_diff*rate` tripping `COEFF_THRESHOLD`. The
> patch adds a per-context `rate_change_system` stamp + a `RATE_SETTLE_WINDOW`
> (1.5 s) during which an unstable (but not `decreasing_ts`) sample is HELD —
> skip the reset, skip the offset recompute — instead of reset. Bounded, so a
> persistently bad source is still reset after the window (no unbounded
> suppression, unlike the reverted 0007). Verified by `verify/driver_f19.c`
> (new `rate_settle` scenario): stock jerks a fixed ts's mapping 500 ms, patched
> holds it at 0; the pause + rate scenarios still pass.
> ⚠️ Verified for APPLY + COMPILE + clock-model behaviour on Linux; the on-DEVICE
> smoothness of 2× (actual vout pacing) still needs confirming on hardware.

> How `0010` was derived (per the "document how the modifications were made"
> rule): the F20 log is `clock gap, unexpected stream discontinuity: system_diff:
> 255728 stream_diff: 3975688` immediately followed by `new clock context(1)` and
> a silent tail, on a stream the **official BiliBili client plays with sound** —
> so it is NOT missing data. Fetched the pinned `c833c4be0`
> `src/clock/input_clock.c` and read `input_clock_Update()`: a
> `diff = stream_diff − system_diff > CR_MAX_GAP` (`CR_MEAN_PTS_GAP`, **300 ms**)
> sets `discontinuity = true`, which `UpdateListener()` forwards to es_out, which
> re-arms the program clock via `vlc_clock_main_SetFirstPcr()` (`src/clock/clock.c`
> — the `new clock context` line) and flushes the static audio filters. A harness
> probe first confirmed the gap *also* jumps the master ES clock ~3.74 s, but the
> **audio flush** specifically comes from the context fork (input_clock-driven),
> not the ES-clock re-anchor — so the fix belongs in `input_clock`. The patch
> splits the existing gap branch on sign: a **forward** gap (`stream_diff ≥ 0`, a
> benign DASH segment-timeline hole shared by every ES) still re-anchors the
> reference (`b_reset_reference` stays true) but leaves `discontinuity` false, so
> no context fork / audio flush; a **backward** jump (`stream_diff < 0` =
> corruption / real splice / wrapped PCR) keeps the full reset. Verified by
> `verify/driver_f20.c` (new `clock_gap` scenario): stock flags the forward gap
> (audio flush), patched re-anchors without it AND still flags the backward jump.
> ⚠️ Verified for APPLY + COMPILE + input_clock-model behaviour on Linux; that the
> tail's audio actually survives (the full es_out → aout chain) still needs
> confirming on hardware.

> How `0011` was derived (per the "document how the modifications were made"
> rule): `0010` removed the input_clock context fork on the forward gap, but the
> silent tail PERSISTED on device — so the audio flush had a second, independent
> source. Traced the audio path: the demuxer marks the near-EOF tail block
> `BLOCK_FLAG_DISCONTINUITY` (independent of the clock); `src/audio_output/dec.c`
> `vlc_aout_stream_Play` → `stream_StartDiscontinuity` drains the output and
> BUFFERS the tail to replay once drained (`stream_HandleDiscontinuity`), but the
> replay only fires on the NEXT block. At EOF none comes, so the input's
> end-of-media `vlc_aout_stream_Drain` hits the pre-existing branch that logs
> `"draining while handling a discontinuity not handled, losing %"PRId64" us of
> audio"` with a `FIXME` and DROPS the tail — that is the F20 cut. The same stuck
> `discontinuity.draining` keeps `vlc_aout_stream_IsDrained` false, so the input
> loops `waiting decoder fifos to empty` and never emits EOF — the F21 freeze
> (a 2× rate change on EOF keeps the master clock unstable, re-arming it). Fix:
> extract the flush+replay already in `stream_HandleDiscontinuity` into
> `stream_ReplayDiscontinuity` and call it from `vlc_aout_stream_Drain` at EOF, so
> the tail is PLAYED and `draining` cleared instead of dropped. The helper nulls
> the fifo before replaying, so the re-Play can't recurse into the same branch.
> ⚠️ Verified for APPLY + COMPILE (`cc -fsyntax-only`, stock + patched) only. The
> aout stream needs the full audio pipeline (module + filters) to run, so there is
> NO offline behavioural harness for this one — the tail-audio-plays and
> stream-ends-cleanly behaviour MUST be confirmed on device.

## Verifying

**Apply hygiene (offline, before/after build):** `verify/check-apply-matrix.sh`
fails when the patch set itself is dishonest — inventory of expected
`0002`–`0014`, **P0.1** static fail if both `0011` and `0012` introduce
`stream_ReplayDiscontinuity` (clean ordered apply would Skip `0012`), **T2**
`filters_rate_ownership` via `verify/check-filters-rate-ownership.sh` (static
L1 markers on `0012`; optional live `filters.c` greps), optional `--build-log`
scan that exits non-zero if any expected patch was Skipped, and optional ordered
apply into a **temp scratch** of a VLC tree (never mutates the caller’s
checkout):

```sh
./patches/libvlc/verify/check-apply-matrix.sh
./patches/libvlc/verify/check-apply-matrix.sh ../SwiftVLC/scripts/.build-libvlc/vlc
./patches/libvlc/verify/check-apply-matrix.sh --build-log /tmp/build-libvlc.log
# T2 only (also invoked from matrix):
./patches/libvlc/verify/check-filters-rate-ownership.sh
./patches/libvlc/verify/check-filters-rate-ownership.sh ../SwiftVLC/scripts/.build-libvlc/vlc
# O1: refuse “playback-correct” without local SwiftVLC path dep + matrix:
./patches/libvlc/verify/check-playback-correct.sh
./patches/libvlc/verify/check-playback-correct.sh --vlc-tree ../SwiftVLC/scripts/.build-libvlc/vlc
```

`check-applied.sh` still proves **placement** in a built tree (0012 section
includes L1 rate_filter gate + FiltersPlay no-drop). Prefer both: matrix
(Skip / overlap / T2 static) then `check-applied` (markers in the right
functions). `check-playback-correct.sh` is the offline O1 umbrella (path
dependency + verify scripts + matrix; optional `check-applied` when a tree
is passed).

`verify/run.sh` proves the clock patches on any host with a C compiler — no
macOS, no autotools, no VLC build. It takes ~0.3s and works whether the tree is
patched or not (it reverse-applies to recover the stock variant):

```sh
./patches/libvlc/verify/run.sh ../SwiftVLC/scripts/.build-libvlc/vlc
```

It builds two independent targets — `src/clock/clock.c` (patches 0002/0004/0009)
and `src/clock/input_clock.c` (patch 0010) — and runs four scenarios, each
expected to FAIL stock and PASS patched:

| Scenario | Driver | Unit | Patch |
|---|---|---|---|
| `contexts_pause` | `driver.c` | `clock.c` | 0002 |
| `rate_change` | `driver_rate.c` | `clock.c` | 0004 |
| `rate_settle` | `driver_f19.c` | `clock.c` | 0009 |
| `clock_gap` | `driver_f20.c` | `input_clock.c` | 0010 |

Patch `0011` / discontinuity Drain (`src/audio_output/dec.c`) has **no** full
aout behavioural harness (needs module + filters). Checked by apply +
`cc -fsyntax-only` + `check-applied.sh`; runtime on device only.

Patches **`0012`/`0013`/`0014`**: no `run.sh` PCM scenario. **T2** offline
static/tree ownership is `verify/check-filters-rate-ownership.sh` (wired into
`check-apply-matrix.sh`; L1 greps in `check-applied` 0012). Full
`aout_FiltersPlay` duration unit still optional (VLC deps). Optional Drain unit
for 0011 remains open.

**`0014` apply note:** depends on context from **`0003`** (SlaveSeek signature
area). Apply order must include 0003 before 0014.

VLC's own `test/src/clock/clock.c` calls `libvlc_new()` and includes
`lib/libvlc_internal.h`, so running it needs the full autotools build. But both
units compile standalone against a four-line `config.h` plus stubs for the ~10
libvlccore symbols they touch (`verify/stubs.c`), and `verify/driver.c` replays
the `contexts_pause` scenario against the real clock:

```
STOCK:    converted = 110000, expected = 130000   -> late by 20000 us
PATCHED:  converted = 130000, expected = 130000   -> late by 0
```

20000 µs is exactly the harness's pause duration — the unit-scale form of the
device log's `picture is too late to be displayed (missing 12733 ms)` after a
12.7 s pause.

Once you have a full VLC build, the upstream test the patch adds is:

```sh
./test/test_src_clock_clock contexts_pause
```

## Getting these into the app

Already wired up in this repo. `project.yml` (which generates the Xcode app
target) and `Package.swift` both point at `../SwiftVLC`. What remains is on the
Mac — one script does the whole apply (idempotent, safe to re-run):

```sh
git clone https://github.com/haikiseven/SwiftVLC.git ../SwiftVLC   # main, not a tag (first time only)
./patches/apply.sh                           # applies swiftvlc + AV1 + libvlc patches, cleans the VLC checkout
cd ../SwiftVLC && ./scripts/build-libvlc.sh --ios-only    # look for "Applied: 0002-clock-…"
cd ../SwiftPili && ./patches/libvlc/verify/check-applied.sh ../SwiftVLC/scripts/.build-libvlc/vlc
xcodegen
```

`apply.sh` (in `patches/`) is the supported path. It:
- `git apply`s `swiftvlc/0001–0003` (build-script + `Package.swift` plumbing), skipping any already applied;
- applies the AV1 F17 fix by **anchor-editing** the `va_videotoolbox.c` heredoc in `build-libvlc.sh` — robust to line drift, unlike `swiftvlc/0004` (kept only as human-readable reference; a context-diff there breaks when the script shifts a line);
- copies `libvlc/*.patch` into the fork's `scripts/patches/`;
- **removes `scripts/.build-libvlc/vlc`** so the edited heredoc actually regenerates the AV1 module and every build step re-applies from pristine. Do **not** hand-revert individual generated files (e.g. `Makefile.am`) — that strands the `vt_utils_native` OBJC rule and breaks the build with `libtool: specify a tag with '--tag'`.

Pass a path if your fork isn't at `../SwiftVLC`: `./patches/apply.sh /path/to/SwiftVLC`.

Use `main`, not a tag: the VideoToolbox AV1 module (`ea904e3`) lives on `main`
and is in no release. Upstream `v0.11.0` and `v0.12.0` are the same tree
(byte-identical `Package.swift`), and `v0.12.0`'s `binaryTarget` still points at
the **v0.11.0** `libvlc.xcframework.zip` — so bumping that pin never changed any
libVLC code.

`patches/swiftvlc/0001` repoints SwiftVLC's `binaryTarget` at its own
`Vendor/libvlc.xcframework`. Generated against `haikiseven/SwiftVLC` `main` as
published; a `path:` target has no checksum, so the manifest and the shipped
binary cannot drift apart.

`Vendor/` is gitignored in SwiftVLC ("Pre-built xcframework (1.2GB)"), so an
existing `Vendor/libvlc.xcframework` is a *previous local build* — stock, without
these patches. Re-running `build-libvlc.sh` is incremental: it reuses the VLC
checkout in `scripts/.build-libvlc/vlc` when HEAD is already at `VLC_HASH`, and
applies `scripts/patches/*` on top, so only `clock.c` recompiles. Afterwards,
clean the consuming app's build folder — a `path:` binaryTarget is copied into
DerivedData and Xcode does not reliably notice the source changed underneath.

## 0002 — clock: apply the pause delay to every live context

**Symptom.** Pause a DASH video, wait, resume. Audio resumes correctly; video
freezes for exactly the pause duration, spraying
`picture is too late to be displayed (missing <pause_duration> ms)`, and the app's
liveness evaluator eventually diagnoses a dead decoder and reloads the stream.

**Cause.** `vlc_clock_main_ChangePause()` applies the resume delay to
`main_clock->context` only. Previous contexts stay in `main_clock->prev_contexts`
for as long as a clock is attached to them, and an output clock only migrates to
a newer context when it *updates* — `vlc_clock_ConvertToSystem()` deliberately
passes `update=false` so that outputs holding frames do not switch under them.
The video output clock therefore stays parked on an older context and, after the
resume, converts against a reference point that is `delay` too early.

**Why we hit it every time.** BiliBili serves DASH with separate audio/video
files, which we attach with `libvlc_media_add_slave`. libVLC's `SlaveSeek()`
seeks the slave to the master's `DEMUX_GET_TIME` — the *fragment start* the
master landed on, not the requested time — so after any seek the audio demuxer
sits ~5 s behind the video demuxer. `input_clock` sees `stream_diff < 0`, calls
it a discontinuity, and `vlc_clock_main_SetFirstPcr()` forks a second context.
From then on, the first pause freezes the video.

Fixing the slave-seek behaviour would stop the second context from being created
in the common case, but the clock bug is real independently of it: any
discontinuity (a real one, an `ES_OUT_RESET_PCR` from the demuxer) reaches the
same state. This patch fixes the clock; the slave-seek behaviour is tracked
separately as design-doc **F5** / **P4.2**.

## 0008 — es_out: the master source owns the program PCR

**Symptom.** On 4K/high-bitrate BiliBili DASH, an in-place `set_time` seek (the
low-latency path that replaces the ~1 s demuxer reopen) leaves the **audio
running ahead of the video**, and it never self-corrects. The device log shows a
signature *triple* clock gap at every seek —
`stream_diff: +2.78s` (video master fragment) /
`stream_diff: -2.53s` (audio slave, an earlier fragment) /
`stream_diff: +2.52s` (back to master) — followed by chronic
`picture is too late to be displayed (missing 20-59 ms)` and eventually
`resetting master clock: coefficient too unstable: 0.708333`.

**Cause.** BiliBili serves DASH as separate audio/video files: the video file is
the input **master**, the audio is a **slave** (`libvlc_media_add_slave`). Both
demuxers feed `ES_OUT_SET_PCR` into the *one* program `input_clock`.
`es_out_source.c`'s `EsOutSourceControl()` forwards the slave's PCR to the main
es_out tagged with the slave source, but `EsOutVaControlLocked()` /
`case ES_OUT_SET_PCR` applies it to `p_sys->p_pgrm` — the **master** program's
clock — regardless of which source sent it. In steady state master/slave PCRs
are close (`diff < CR_MAX_GAP`, harmless). But at a `set_time` seek the two
demuxers snap to different fragment boundaries (video on the 5.000 s grid, audio
AAC-frame-aligned — see **0003**), so the slave PCR perturbs the shared clock,
destabilising the master coefficient. Video then sits 1–2 frames late → audio
ahead, permanently.

`reopenForSeek` (the historical VOD default) never hits this: `:start-time`
opens both demuxers fresh at the target, so there is no in-place `SlaveSeek` and
no fragment-boundary bounce.

**Fix.** The master (video) source owns the program PCR timeline. In
`case ES_OUT_SET_PCR`, drop the PCR when `source != input_priv(p_input)->master`
— return `VLC_SUCCESS` without touching `i_last_pcr` or `input_clock_Update()`.
Muxed single-file A+V is unaffected (one source emits PCR, guard never trips);
buffering is driven by the master clock the master demux still feeds; ES data
flow (`EsOutSourceSend`) is untouched. `ES_OUT_SET_GROUP_PCR` (explicit
multi-program muxes) is left alone by guarding on `i_query == ES_OUT_SET_PCR`.
Tracked as design-doc **F18**; this makes `set_time` the low-latency VOD seek
path, retiring the "reopen is the only reliable path" conclusion for this
failure mode.

## 0011 — aout: play out the buffered tail on EOF instead of dropping it

**Symptom.** Two bugs, both near the very end of a BiliBili DASH video:
- **F20** — the last few seconds play **silent** (video finishes normally).
- **F21** — press-and-hold **2×** right as the video ends **freezes** it: it
  hangs at ~95s of a 99s clip, spamming `waiting decoder fifos to empty` and
  `resetting master clock: coefficient too unstable: 2.0`, and the app then
  diagnoses a dead decoder and reloads.

Both on streams the **official client plays fine** — so no data is missing.

**Cause.** The demuxer marks the near-EOF tail block with
`BLOCK_FLAG_DISCONTINUITY` (its marker for the benign forward timeline gap —
see `0010`). In `src/audio_output/dec.c`, `vlc_aout_stream_Play` →
`stream_StartDiscontinuity` drains the current output and **buffers** every
block after the gap, to replay once the drain finishes
(`stream_HandleDiscontinuity`). But the replay is only re-checked when the
**next** block arrives. At EOF there is no next block, so it never replays. The
input's end-of-media path then calls `vlc_aout_stream_Drain`, which found
`discontinuity.draining` still set and executed a standing `FIXME`:

```c
msg_Err(aout, "draining while handling a discontinuity not handled"
        ", losing %"PRId64 " us of audio", length); /* FIXME */
stream_ResetDiscontinuity(stream);   /* <-- drops the buffered tail */
```

That drop is the **silent tail (F20)**. And because `discontinuity.draining`
stays set, `vlc_aout_stream_IsDrained` returns false, so `es_out_IsEmpty` is
never true and `src/input/input.c`'s main loop spins on `waiting decoder fifos
to empty` — the EOF event never fires. A 2× rate change landing on EOF keeps the
master clock unstable (repeated `coefficient too unstable` resets), which re-arms
the discontinuity and makes the stuck state permanent — the **freeze (F21)**.

**Fix.** Factor the flush + replay already living in `stream_HandleDiscontinuity`
into `stream_ReplayDiscontinuity`, and call it from `vlc_aout_stream_Drain` when
EOF is reached with a discontinuity still pending. The buffered tail is **played
out** instead of dropped, and `discontinuity.draining` is cleared so
`IsDrained` can return true and the stream ends cleanly (no more `waiting decoder
fifos to empty`, so the freeze can't form). The helper nulls the fifo before
replaying, so the re-`Play` can't recurse into the same branch. Muxed single-file
A+V never hits this (no separate-timeline gap to mark the tail `DISCONTINUITY`).
Tracked as design-doc **F20** (cut) and **F21** (freeze). `0010` (input_clock)
stays: it removes a *different* flush (the context fork) on the same gap.

## 0010 — input_clock: re-anchor forward stream gaps without a discontinuity

**Symptom.** The last few seconds of some BiliBili videos play **silent** — the
video finishes normally, the audio simply stops. The device log shows, near EOF:

```
clock gap, unexpected stream discontinuity: system_diff: 255728 stream_diff: 3975688
… new clock context(1) …
Using a new clock context, flushing static filters
```

The **official BiliBili client plays the same stream with sound**, so this is
not missing audio data — libVLC is discarding it.

**Cause.** For DASH/HLS delivery the demuxer can surface a large **forward** jump
in the program PCR near EOF — a benign segment-timeline hole. The same hole
exists in every ES of the program (audio and video share the manifest timeline),
so A/V stay in sync across it; the official player just re-anchors and keeps
decoding. libVLC's `input_clock_Update()` instead flags any

```
diff = stream_diff − system_diff > CR_MAX_GAP      (CR_MEAN_PTS_GAP, 300 ms)
```

as a `discontinuity`. `UpdateListener()` forwards that flag to es_out, which
drops the program clock and re-arms it via `vlc_clock_main_SetFirstPcr()`
(`src/clock/clock.c` — the `new clock context` line). Forking a context flushes
the **static audio filter chain** (scaletempo / resampler). The video output has
no such filter to flush, so it rides through; the audio, flushed with only a few
seconds of file left, cannot refill before EOF → silent tail.

A harness probe confirmed the 4 s gap *also* jumps the master ES clock ~3.74 s,
but that ES-clock re-anchor only re-times **video** (the F19 territory); the
**audio flush** is specifically the input_clock-driven context fork. So the fix
belongs in `input_clock`, not the ES clock.

**Fix.** Split the existing gap branch on the sign of `stream_diff`. A
**backward** jump (`stream_diff < 0` — corruption, a real splice, a wrapped PCR)
still needs the hard reset + `discontinuity`, so keep it (this is also the
`stream_diff < 0` case that patch **0002**'s notes describe). A **forward** gap
only needs the reference re-anchored so the clock follows the new timeline;
`b_reset_reference` stays true in both cases, but `discontinuity` is left false
for the forward gap, so no context fork / audio flush happens. Muxed single-file
A+V is unaffected (a continuous file has no segment-boundary hole to trip the
gap). Tracked as design-doc **F20**.
