#include <config.h>
#include <vlc_common.h>
#include <vlc_tick.h>
#include <vlc_es.h>
#include "clock.h"
#include <stdio.h>
#include <stdlib.h>
#include <assert.h>

/* F19: right after a rate change the audio output re-tempos its scaletempo
 * filter; for ~1-2s it feeds the clock a system/stream ratio that looks like
 * the OLD rate (instant_coeff ~2.0), so the master clock resets over and over,
 * each reset re-anchoring the offset and jerking the video mapping. This replays
 * that transient on a single (current) context and measures how much the
 * converted system time for a FIXED stream ts moves during it.
 *
 * Stock (0002+0004): the mapping jumps on every reset. Patched (+F19): the
 * mapping is held for the bounded settle window. */
int main(void)
{
    vlc_clock_main_t *mainclk = vlc_clock_main_New(NULL, NULL);
    assert(mainclk);
    vlc_clock_main_Lock(mainclk);
    vlc_clock_t *master = vlc_clock_main_CreateMaster(mainclk, "audio", NULL, NULL);
    assert(master);
    vlc_clock_main_SetInputDejitter(mainclk, 0);
    vlc_clock_main_SetDejitter(mainclk, 0);

    vlc_tick_t sys = VLC_TICK_FROM_MS(100);
    vlc_tick_t stm = VLC_TICK_0 + VLC_TICK_FROM_SEC(1);
    vlc_clock_main_SetFirstPcr(mainclk, sys, stm);
    vlc_clock_Start(master, sys, stm);

    /* Steady 1x so the coeff converges to ~1.0. */
    for (int i = 0; i < 5; i++) {
        sys += VLC_TICK_FROM_MS(100);
        stm += VLC_TICK_FROM_MS(100);
        vlc_clock_Update(master, sys, stm, 1.0f);
    }

    vlc_tick_t probe = stm; /* fixed stream ts whose mapping we watch */

    /* 2x hold: rate change up, then a couple of steady 2x samples. */
    sys += VLC_TICK_FROM_MS(100); stm += VLC_TICK_FROM_MS(200);
    vlc_clock_Update(master, sys, stm, 2.0f);
    for (int i = 0; i < 2; i++) {
        sys += VLC_TICK_FROM_MS(100); stm += VLC_TICK_FROM_MS(200);
        vlc_clock_Update(master, sys, stm, 2.0f);
    }

    /* Release: rate change back to 1x (opens the settle window). */
    sys += VLC_TICK_FROM_MS(100); stm += VLC_TICK_FROM_MS(100);
    vlc_clock_Update(master, sys, stm, 1.0f);

    uint32_t id = 0;
    vlc_tick_t base_map = vlc_clock_ConvertToSystem(master, sys, probe, 1.0f, &id);

    /* Transient: the aout plays slow while re-tempoing — system advances 2x the
     * stream (instant_coeff ~2.0), all inside the settle window (<1.5s). */
    vlc_tick_t max_jump = 0;
    for (int i = 0; i < 5; i++) {
        sys += VLC_TICK_FROM_MS(200); /* 200ms real */
        stm += VLC_TICK_FROM_MS(100); /* 100ms stream */
        vlc_clock_Update(master, sys, stm, 1.0f);
        vlc_tick_t m = vlc_clock_ConvertToSystem(master, sys, probe, 1.0f, &id);
        vlc_tick_t jump = llabs(m - base_map);
        if (jump > max_jump) max_jump = jump;
    }
    vlc_clock_main_Unlock(mainclk);

    printf("  max mapping jump for a fixed ts during the transient: %lld us\n",
           (long long) max_jump);
    printf("  held mapping (patched) stays ~0; repeated resets (stock) jump >100ms\n");

    if (max_jump > VLC_TICK_FROM_MS(50)) {
        printf("\n  \xE2\x9D\x8C FAIL: the post-rate-change transient jerks the clock mapping\n");
        return 1;
    }
    printf("\n  \xE2\x9C\x85 PASS: the mapping is held across the settle window\n");
    return 0;
}
