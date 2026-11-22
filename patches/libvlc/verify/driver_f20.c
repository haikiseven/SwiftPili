#include <config.h>
#include <vlc_common.h>
#include <vlc_tick.h>
#include "input_clock.h"
#include <stdio.h>
#include <stdlib.h>
#include <assert.h>

/* F20: near EOF a DASH stream shows a large FORWARD PCR jump (a benign
 * segment-timeline hole shared by every ES). Stock input_clock flags it as a
 * `discontinuity`, which makes es_out re-arm the program clock
 * (vlc_clock_main_SetFirstPcr) — forking a new clock context and flushing the
 * audio filter chain, so the tail plays silent. The patch re-anchors the
 * reference WITHOUT the discontinuity flag for a forward gap, while a BACKWARD
 * jump still flags it. This driver observes the flag the listener receives. */

static bool g_last_disc;
static int  g_updates;

static vlc_tick_t on_update(void *opaque, vlc_tick_t ck_system,
                            vlc_tick_t ck_stream, double rate, bool discontinuity)
{
    (void)opaque; (void)ck_system; (void)ck_stream; (void)rate;
    g_last_disc = discontinuity;
    g_updates++;
    return 0;
}
static void on_reset(void *opaque) { (void)opaque; }

static const struct vlc_input_clock_cbs cbs = { .update = on_update, .reset = on_reset };

/* input_clock_Update(cl, pace, buffering, extra_buffering, i_ck_stream, i_ck_system) */
static bool feed(input_clock_t *cl, vlc_tick_t stream, vlc_tick_t system)
{
    input_clock_Update(cl, false, false, false, stream, system);
    return g_last_disc;
}

int main(void)
{
    input_clock_t *cl = input_clock_New(NULL, 1.0f);
    assert(cl);
    input_clock_AttachListener(cl, &cbs, NULL);

    vlc_tick_t sys = VLC_TICK_FROM_MS(100);
    vlc_tick_t stm = VLC_TICK_0 + VLC_TICK_FROM_SEC(1);
    feed(cl, stm, sys);                       /* first ref */
    for (int i = 0; i < 6; i++) {             /* steady 1x */
        sys += VLC_TICK_FROM_MS(100);
        stm += VLC_TICK_FROM_MS(100);
        feed(cl, stm, sys);
    }

    /* --- forward gap: stream +4s, real time +0.26s (the F20 log) --- */
    sys += VLC_TICK_FROM_MS(260);
    stm += VLC_TICK_FROM_SEC(4);
    bool fwd_disc = feed(cl, stm, sys);
    printf("  forward gap (+4s stream / +0.26s system): discontinuity=%s\n",
           fwd_disc ? "TRUE (context fork -> audio flush)" : "false (re-anchor, audio kept)");

    /* --- a few steady points after the gap re-establish `last` --- */
    for (int i = 0; i < 3; i++) {
        sys += VLC_TICK_FROM_MS(100);
        stm += VLC_TICK_FROM_MS(100);
        feed(cl, stm, sys);
    }

    /* --- backward jump: real corruption / splice must STILL flush --- */
    sys += VLC_TICK_FROM_MS(100);
    stm -= VLC_TICK_FROM_SEC(2);
    bool bwd_disc = feed(cl, stm, sys);
    printf("  backward jump (-2s stream): discontinuity=%s\n",
           bwd_disc ? "TRUE (hard reset, correct)" : "false (WRONG - lost real discontinuity)");

    input_clock_Delete(cl);

    if (!bwd_disc) {   /* patch must never swallow a real backward discontinuity */
        printf("\n  \xE2\x9D\x8C FAIL: backward discontinuity was not flagged\n");
        return 2;
    }
    if (fwd_disc) {
        printf("\n  \xE2\x9D\x8C FAIL: forward timeline gap forks the clock context (flushes audio)\n");
        return 1;
    }
    printf("\n  \xE2\x9C\x85 PASS: forward gap re-anchors without a flush; backward jump still resets\n");
    return 0;
}
