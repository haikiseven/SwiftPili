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
    int codec; /* 1 AVC, 2 HEVC (reserved), 3 AAC */
    const uint8_t *config; /* avcC / hvcC / ASC payload, valid until destroy */
    int config_size;
} MLDTrack;

typedef struct {
    int kind; /* 1 video, 2 audio */
    const uint8_t *data; /* valid until the next mld_next call or destroy */
    int size;
    double pts; /* seconds in a shared muxed-input timeline, NAN if absent */
    double dts;
    double duration;
    int is_key;
} MLDPacket;

/*
 * All calls for a context are serialized. Preserve opaque and the callbacks
 * until destroy. The caller must arrange for a blocked read to wake on stop.
 * Format: 1 MPEG-TS, 2 live FLV. Read: positive bytes, 0 EOF, -1 failure,
 * -2 interrupted. The final read argument is the remaining deadline in
 * microseconds. Interrupted returns 1 when stopped.
 */
MLDContext *mld_create(int format, void *opaque, int (*read)(void *, uint8_t *, int, int),
                       int (*interrupted)(void *));

/* Open is single-use. Every result except MLD_OK is terminal for the context.
 * MLD_EOF is proven source exhaustion. MLD_RELOAD requires a fresh source epoch.
 */
int mld_open(MLDContext *context);
int mld_next(MLDContext *context, MLDPacket *packet);
void mld_destroy(MLDContext *context);

/* Call after successful open. Kind: 1 video, 2 audio. Returns 0 if present. */
int mld_track(MLDContext *context, int kind, MLDTrack *track);

#ifdef __cplusplus
}
#endif

#endif
