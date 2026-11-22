#include <config.h>
#include <vlc_common.h>
#include <vlc_tick.h>
#include <vlc_es.h>
#include "clock.h"
#include <stdio.h>
#include <assert.h>

// Reproduces the device symptom: after a rate change, an output clock parked on
// a PREVIOUS context keeps converting at the old rate. Video then plays at 1x
// while audio plays at 2x (fps 60 at rate=2.00), and at 2x while audio plays 1x
// on the way back (fps 120 at rate=1.00).
//
// Measure the slope: how much SYSTEM time one second of STREAM time maps to on
// the parked context. At rate 2.0 it must be ~0.5s. At rate 1.0, ~1.0s.
int main(void)
{
    vlc_clock_main_t *mainclk = vlc_clock_main_New(NULL, NULL);
    assert(mainclk);
    vlc_clock_main_Lock(mainclk);
    vlc_clock_t *master = vlc_clock_main_CreateMaster(mainclk, "audio", NULL, NULL);
    vlc_clock_t *slave  = vlc_clock_main_CreateSlave(mainclk, "video", VIDEO_ES, NULL, NULL);
    assert(master && slave);
    vlc_clock_main_SetInputDejitter(mainclk, 0);
    vlc_clock_main_SetDejitter(mainclk, 0);

    vlc_tick_t system = VLC_TICK_FROM_MS(100);
    vlc_tick_t stream0 = VLC_TICK_0 + VLC_TICK_FROM_SEC(1);

    // context 0, at rate 1.0. Both clocks attach to it.
    vlc_clock_main_SetFirstPcr(mainclk, system, stream0);
    vlc_clock_Start(master, system, stream0);
    vlc_clock_Start(slave,  system, stream0);
    vlc_clock_Update(master, system, stream0, 1.0f);

    // A discontinuity forks context 1. The slave stays parked on context 0
    // (outputs only migrate when they update; the vout converts).
    system += VLC_TICK_FROM_MS(100);
    vlc_tick_t stream1 = VLC_TICK_0 + VLC_TICK_FROM_SEC(60);
    vlc_clock_main_SetFirstPcr(mainclk, system, stream1);

    // The user presses 2x. The audio master updates -- on the CURRENT context.
    system += VLC_TICK_FROM_MS(20);
    vlc_clock_Update(master, system, stream1, 2.0f);

    // The video output converts two timestamps 1s apart, on ITS context.
    uint32_t id_a = 99, id_b = 99;
    vlc_tick_t ts   = stream0 + VLC_TICK_FROM_MS(10);
    vlc_tick_t a = vlc_clock_ConvertToSystem(slave, system, ts, 2.0f, &id_a);
    vlc_tick_t b = vlc_clock_ConvertToSystem(slave, system, ts + VLC_TICK_FROM_SEC(1), 2.0f, &id_b);
    vlc_clock_main_Unlock(mainclk);

    printf("  slave converting on clock context %u (expect 0: the parked one)\n", id_a);
    if (id_a != 0 || id_b != 0) { printf("\n  INCONCLUSIVE: slave migrated off context 0\n"); return 2; }

    double slope_ms = (b - a) / 1000.0;
    printf("  1s of stream maps to %.1f ms of system time\n", slope_ms);
    printf("  expected at rate 2.0: ~500.0 ms  (video keeps pace with audio)\n");
    printf("  stale rate 1.0 would give: ~1000.0 ms  (video runs at HALF speed)\n");

    if (slope_ms > 750.0) {
        printf("\n  ❌ FAIL: parked context still scales by the OLD rate — this is the desync\n");
        return 1;
    }
    printf("\n  ✅ PASS: the parked context adopted the new rate\n");
    return 0;
}
