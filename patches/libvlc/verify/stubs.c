#include <config.h>
#include <vlc_common.h>
#include <vlc_threads.h>
#include <stdio.h>
#include <stdarg.h>
#include <time.h>
// Single-threaded harness: locks are no-ops, but vlc_mutex_held must answer
// true or clock.c's vlc_mutex_assert() aborts.
void vlc_mutex_init(vlc_mutex_t *m) { (void)m; }
void vlc_mutex_lock(vlc_mutex_t *m) { (void)m; }
void vlc_mutex_unlock(vlc_mutex_t *m) { (void)m; }
bool vlc_mutex_held(const vlc_mutex_t *m) { (void)m; return true; }
void vlc_cond_init(vlc_cond_t *c) { (void)c; }
void vlc_cond_broadcast(vlc_cond_t *c) { (void)c; }
int  vlc_cond_timedwait(vlc_cond_t *c, vlc_mutex_t *m, vlc_tick_t d) { (void)c;(void)m;(void)d; return 0; }
vlc_tick_t vlc_tick_now(void) { struct timespec ts; clock_gettime(CLOCK_MONOTONIC,&ts);
    return (vlc_tick_t)ts.tv_sec*CLOCK_FREQ + ts.tv_nsec/1000; }
const char vlc_module_name[] = "clockharness";
struct vlc_logger;
void vlc_Log(struct vlc_logger *const *lp, int type, const char *typename,
             const char *module, const char *file, unsigned line,
             const char *func, const char *format, ...) {
    (void)lp;(void)type;(void)typename;(void)module;(void)file;(void)line;(void)func;
    fprintf(stderr, "    [vlc] "); va_list ap; va_start(ap, format);
    vfprintf(stderr, format, ap); fprintf(stderr, "\n"); va_end(ap);
}
struct vlc_logger *vlc_LogHeaderCreate(struct vlc_logger *p, const char *h) { (void)p;(void)h; return NULL; }
void vlc_LogDestroy(struct vlc_logger *l) { (void)l; }
void vlc_tracer_TraceWithTs(struct vlc_tracer *t, vlc_tick_t ts, ...) { (void)t;(void)ts; }
