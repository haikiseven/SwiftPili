#include <config.h>
#include <vlc_common.h>
#include <vlc_tick.h>
#include <vlc_es.h>
#include "clock.h"
#include <stdio.h>
#include <assert.h>

// Reproduces the `contexts_pause` scenario added by
// 0001-clock-apply-pause-delay-to-all-live-contexts.patch, using the real
// clock.c. A pause taken while an output clock is parked on a PREVIOUS context
// must delay that context's conversions too.
int main(void)
{
    const vlc_tick_t pause_duration = VLC_TICK_FROM_MS(20);
    const vlc_tick_t system_start   = VLC_TICK_FROM_MS(100);

    vlc_clock_main_t *mainclk = vlc_clock_main_New(NULL, NULL);
    assert(mainclk);
    vlc_clock_main_Lock(mainclk);
    vlc_clock_t *slave = vlc_clock_main_CreateSlave(mainclk, "video", VIDEO_ES, NULL, NULL);
    assert(slave);
    vlc_clock_main_SetInputDejitter(mainclk, 0);
    vlc_clock_main_SetDejitter(mainclk, 0);

    vlc_tick_t system = system_start;
    vlc_tick_t stream_context0 = 1;
    uint32_t clock_id;

    // context 0; updating attaches the slave clock to it
    vlc_clock_main_SetFirstPcr(mainclk, system, stream_context0);
    vlc_clock_Update(slave, system, stream_context0, 1.0f);
    const vlc_tick_t system_context0 = system;

    // discontinuity -> forks context 1; slave stays parked on context 0
    vlc_tick_t stream_context1 = VLC_TICK_FROM_SEC(30);
    system += VLC_TICK_FROM_MS(100);
    vlc_clock_main_SetFirstPcr(mainclk, system, stream_context1);

    // pause + resume while the slave is still on context 0
    system += VLC_TICK_FROM_MS(10);
    vlc_clock_main_ChangePause(mainclk, system, true);
    system += pause_duration;
    vlc_clock_main_ChangePause(mainclk, system, false);
    system += 1;

    vlc_tick_t converted = vlc_clock_ConvertToSystem(
        slave, system, VLC_TICK_FROM_MS(10) + stream_context0, 1.0f, &clock_id);

    vlc_tick_t expected = system_context0 + VLC_TICK_FROM_MS(10) + pause_duration;
    printf("  clock_id      = %u (expect 0: still on the old context)\n", clock_id);
    printf("  converted     = %" PRId64 "\n", converted);
    printf("  expected      = %" PRId64 "  (= unpaused %" PRId64 " + pause %" PRId64 ")\n",
           expected, system_context0 + VLC_TICK_FROM_MS(10), pause_duration);
    printf("  lateness      = %" PRId64 " us\n", expected - converted);

    vlc_clock_main_Unlock(mainclk);

    if (clock_id != 0) { printf("\n  INCONCLUSIVE: slave migrated off context 0\n"); return 2; }
    if (converted != expected) {
        printf("\n  ❌ FAIL: picture dated %" PRId64 "us in the past — this is the freeze\n",
               expected - converted);
        return 1;
    }
    printf("\n  ✅ PASS: the old context received the pause delay\n");
    return 0;
}
