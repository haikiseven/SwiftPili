#ifndef SWIFTPILI_LIVE_MEDIA_CODEC_H
#define SWIFTPILI_LIVE_MEDIA_CODEC_H

#include "LiveMediaDemux.h"
#include <ExportNamespace.h>
#include <libavcodec/bsf.h>
#include <libavformat/avformat.h>

enum { MLD_MAX_PACKET_BYTES = 8 * 1024 * 1024 };

typedef struct {
    uint8_t *data;
    int size;
} MLDParameterSet;

typedef struct {
    uint8_t *config;
    int config_size;
    int nal_length;
    MLDParameterSet sets[64];
    int set_count;
    int set_bytes;
    int has_sps;
    int has_pps;
    AVBSFContext *adts_to_asc;
    double audio_duration;
} MLDCodec;

int mld_video_packet(MLDCodec *codec, int format, const AVCodecParameters *par,
                     AVPacket *packet, int *has_access_unit, int *is_key);
int mld_audio_packet(MLDCodec *codec, int format, const AVCodecParameters *par,
                     AVPacket *packet);
void mld_codec_clear(MLDCodec *codec);

#endif
