#ifndef SWIFTPILI_LIVE_MEDIA_DEMUX_H
#define SWIFTPILI_LIVE_MEDIA_DEMUX_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct MLDContext MLDContext;

enum {
    MLD_OK = 0, MLD_EOF = 1, MLD_INTERRUPTED = 2, MLD_UNSUPPORTED = 3, MLD_INVALID = 4,
    MLD_RELOAD = 5,
    MLD_TS = 1, MLD_FLV = 2,
    MLD_VIDEO = 1, MLD_AUDIO = 2,
    MLD_AVC = 1, MLD_AAC = 3,
};

int mld_format_available(int format);

typedef struct {
    int codec;
    const uint8_t *config;
    int config_size;
} MLDTrack;

typedef struct {
    int kind;
    const uint8_t *data;
    int size;
    double pts;
    double dts;
    double duration;
    int is_key;
} MLDPacket;

MLDContext *mld_create(int format, void *opaque, int (*read)(void *, uint8_t *, int, int),
                       int (*interrupted)(void *));

int mld_open(MLDContext *context);
int mld_next(MLDContext *context, MLDPacket *packet);
void mld_destroy(MLDContext *context);

int mld_track(MLDContext *context, int kind, MLDTrack *track);

#ifdef __cplusplus
}
#endif

#endif
