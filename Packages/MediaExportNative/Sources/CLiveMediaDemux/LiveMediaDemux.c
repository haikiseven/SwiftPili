#include "LiveMediaCodec.h"

#include <errno.h>
#include <libavutil/error.h>
#include <libavutil/mem.h>
#include <libavutil/time.h>
#include <math.h>
#include <stdlib.h>
#include <string.h>

enum {
    IO_BUFFER_BYTES = 32 * 1024,
    TS_HEADER_SCAN_BYTES = 64 * 1024,
    MAX_PROBE_BYTES = 16 * 1024 * 1024,
    MAX_READ_BYTES = 16 * 1024 * 1024,
    MAX_PROBE_PACKETS = 384,
    MAX_SKIPPED_PACKETS = 2048,
    PROBE_TIME_US = 12 * 1000 * 1000,
    READ_TIME_US = 12 * 1000 * 1000,
    FLV_HEADER_BYTES = 9,
    FLV_TAG_HEADER_BYTES = 11,
    FLV_PREVIOUS_TAG_SIZE_BYTES = 4,
};

typedef struct {
    int index;
    AVRational time_base;
    int wrap_bits;
    double last_dts;
    double last_clock;
    int has_timed_packet;
    int has_key;
    MLDCodec codec;
} MLDStream;

typedef struct {
    AVPacket *buffer;
    MLDPacket view;
} MLDQueuedPacket;

struct MLDContext {
    int format;
    void *opaque;
    int (*read)(void *, uint8_t *, int, int);
    int (*interrupted)(void *);
    AVFormatContext *input;
    AVIOContext *io;
    int io_failure;
    int io_eof;
    int io_bytes_remaining;
    int64_t io_deadline;
    uint8_t flv_header[FLV_HEADER_BYTES];
    int flv_header_remaining;
    uint8_t flv_tag_header[FLV_TAG_HEADER_BYTES];
    int flv_tag_header_bytes;
    int flv_skip_bytes;
    int has_ts_program;
    int ts_program_id;
    int opened;
    int ready;
    int terminal;
    MLDStream video;
    MLDStream audio;
    double origin;
    AVPacket *scratch;
    MLDQueuedPacket probe[MAX_PROBE_PACKETS];
    int probe_count;
    int probe_cursor;
    int probe_bytes;
};

static int operation_failure(MLDContext *context)
{
    if (context->interrupted(context->opaque))
        context->io_failure = MLD_INTERRUPTED;
    if (!context->io_failure && av_gettime_relative() >= context->io_deadline)
        context->io_failure = MLD_INVALID;
    return context->io_failure;
}

static int interrupt_avio(void *opaque)
{
    return operation_failure(opaque) != MLD_OK;
}

static void begin_operation(MLDContext *context, int bytes, int64_t time_us)
{
    context->io_bytes_remaining = bytes;
    context->io_deadline = av_gettime_relative() + time_us;
}

static int read_bridge(MLDContext *context, uint8_t *data, int size)
{
    int status = operation_failure(context);
    if (status)
        return status == MLD_INTERRUPTED ? AVERROR_EXIT : AVERROR(EIO);
    if (context->io_eof)
        return AVERROR_EOF;
    if (context->io_bytes_remaining == 0) {
        context->io_failure = MLD_INVALID;
        return AVERROR(EIO);
    }
    size = FFMIN(size, context->io_bytes_remaining);

    int64_t remaining_us = context->io_deadline - av_gettime_relative();
    if (remaining_us <= 0) {
        context->io_failure = MLD_INVALID;
        return AVERROR(EIO);
    }
    int count = context->read(context->opaque, data, size, (int)remaining_us);
    if (count == -2)
        context->io_failure = MLD_INTERRUPTED;
    if (operation_failure(context))
        return context->io_failure == MLD_INTERRUPTED ? AVERROR_EXIT : AVERROR(EIO);
    if (count > 0 && count <= size) {
        context->io_bytes_remaining -= count;
        return count;
    }
    if (count == 0) {
        context->io_eof = 1;
        return AVERROR_EOF;
    }
    context->io_failure = MLD_INVALID;
    return AVERROR(EIO);
}

static void observe_flv_framing(MLDContext *context, const uint8_t *data, int size)
{
    while (size > 0) {
        if (context->flv_skip_bytes > 0) {
            int consumed = FFMIN(size, context->flv_skip_bytes);
            data += consumed;
            size -= consumed;
            context->flv_skip_bytes -= consumed;
            continue;
        }
        int offset = context->flv_tag_header_bytes;
        int consumed = FFMIN(size, FLV_TAG_HEADER_BYTES - offset);
        memcpy(context->flv_tag_header + offset, data, consumed);
        context->flv_tag_header_bytes += consumed;
        data += consumed;
        size -= consumed;
        if (context->flv_tag_header_bytes == FLV_TAG_HEADER_BYTES) {
            const uint8_t *header = context->flv_tag_header;
            int payload_size = (header[1] << 16) | (header[2] << 8) | header[3];
            context->flv_skip_bytes = payload_size + FLV_PREVIOUS_TAG_SIZE_BYTES;
            context->flv_tag_header_bytes = 0;
        }
    }
}

static int read_avio(void *opaque, uint8_t *data, int size)
{
    MLDContext *context = opaque;
    if (context->flv_header_remaining > 0 && !operation_failure(context)) {
        int remaining = context->flv_header_remaining;
        int count = size < remaining ? size : remaining;
        memcpy(data, context->flv_header + FLV_HEADER_BYTES - remaining, count);
        context->flv_header_remaining -= count;
        return count;
    }
    int count = read_bridge(context, data, size);
    if (context->format == MLD_FLV) {
        if (count > 0) {
            observe_flv_framing(context, data, count);
        } else if (count == AVERROR_EOF && (context->flv_tag_header_bytes || context->flv_skip_bytes)) {
            context->io_failure = MLD_INVALID;
            return AVERROR(EIO);
        }
    }
    return count;
}

static int classify_av_result(MLDContext *context, int result)
{
    int failure = operation_failure(context);
    if (failure)
        return failure;
    if (result >= 0)
        return MLD_OK;
    if (result == AVERROR_EOF && context->io_eof)
        return MLD_EOF;
    if (result == AVERROR_PATCHWELCOME || result == AVERROR_DEMUXER_NOT_FOUND)
        return MLD_UNSUPPORTED;
    return MLD_INVALID;
}

static int read_flv_header(MLDContext *context)
{
    uint8_t *header = context->flv_header;
    int offset = 0;
    while (offset < FLV_HEADER_BYTES) {
        int count = read_bridge(context, header + offset, FLV_HEADER_BYTES - offset);
        if (count < 0) {
            int result = classify_av_result(context, count);
            return result == MLD_EOF && offset > 0 ? MLD_INVALID : result;
        }
        offset += count;
    }
    uint32_t data_offset = ((uint32_t)header[5] << 24) | ((uint32_t)header[6] << 16) |
                           ((uint32_t)header[7] << 8) | header[8];
    if (memcmp(header, "FLV", 3) || header[3] != 1 || (header[4] & ~5) ||
        data_offset < FLV_HEADER_BYTES || data_offset > TS_HEADER_SCAN_BYTES)
        return MLD_INVALID;
    context->flv_header_remaining = FLV_HEADER_BYTES;
    context->flv_skip_bytes = data_offset - FLV_HEADER_BYTES + FLV_PREVIOUS_TAG_SIZE_BYTES;
    return MLD_OK;
}

static double packet_seconds(int64_t stamp, AVRational time_base)
{
    return stamp == AV_NOPTS_VALUE ? NAN : stamp * av_q2d(time_base);
}

static double align_wrap(double stamp, double reference, double period)
{
    if (!isfinite(stamp) || !isfinite(reference) || period <= 0)
        return stamp;
    double difference = stamp - reference;
    return fabs(difference) > period / 2 ? reference + remainder(difference, period) : stamp;
}

static int update_timing(MLDContext *context, MLDStream *stream, MLDPacket *view)
{
    double period = stream->wrap_bits > 0 && stream->wrap_bits <= 53
                        ? ldexp(av_q2d(stream->time_base), stream->wrap_bits) : 0;
    double reference = isfinite(stream->last_clock) ? stream->last_clock : context->origin;
    view->dts = align_wrap(view->dts, reference, period);
    view->pts = align_wrap(view->pts, isfinite(view->dts) ? view->dts : reference, period);

    if (isfinite(view->dts)) {
        if (isfinite(stream->last_dts)) {
            double delta = view->dts - stream->last_dts;
            if (delta < -2 || delta > 30)
                return MLD_RELOAD;
        }
        stream->last_dts = view->dts;
    }
    double clock = isfinite(view->dts) ? view->dts : view->pts;
    if (isfinite(clock)) {
        stream->last_clock = clock;
        stream->has_timed_packet = 1;
        if (!isfinite(context->origin))
            context->origin = clock;
    }
    if (isfinite(context->origin)) {
        view->dts -= context->origin;
        view->pts -= context->origin;
    }
    return MLD_OK;
}

static int program_contains(const AVProgram *program, int index)
{
    for (unsigned i = 0; i < program->nb_stream_indexes; ++i) {
        if (program->stream_index[i] == (unsigned)index)
            return 1;
    }
    return 0;
}

static int same_program(MLDContext *context, int first, int second)
{
    if (context->format != MLD_TS || first < 0 || first == second)
        return 1;
    AVProgram *program = NULL;
    int found_program = 0;
    while ((program = av_find_program_from_stream(context->input, program, first))) {
        found_program = 1;
        if (program_contains(program, second))
            return 1;
    }
    return !found_program;
}

static int check_ts_program(MLDContext *context)
{
    if (context->format != MLD_TS || context->video.index < 0 || context->audio.index < 0)
        return MLD_OK;
    for (unsigned i = 0; i < context->input->nb_programs; ++i) {
        const AVProgram *program = context->input->programs[i];
        if (context->has_ts_program && program->id != context->ts_program_id)
            continue;
        if (program_contains(program, context->video.index) && program_contains(program, context->audio.index)) {
            context->has_ts_program = 1;
            context->ts_program_id = program->id;
            return MLD_OK;
        }
    }
    return context->has_ts_program ? MLD_RELOAD : MLD_OK;
}

static int read_one(MLDContext *context, MLDPacket *view)
{
    AVPacket *packet = context->scratch;
    for (int skipped = 0; skipped < MAX_SKIPPED_PACKETS; ++skipped) {
        av_packet_unref(packet);
        int result = classify_av_result(context, av_read_frame(context->input, packet));
        if (result != MLD_OK)
            return result;
        result = check_ts_program(context);
        if (result != MLD_OK)
            return result;
        if (packet->stream_index < 0 || (unsigned)packet->stream_index >= context->input->nb_streams)
            return MLD_INVALID;

        const AVStream *av_stream = context->input->streams[packet->stream_index];
        const AVCodecParameters *par = av_stream->codecpar;
        const int is_video = par->codec_type == AVMEDIA_TYPE_VIDEO;
        if (!is_video && par->codec_type != AVMEDIA_TYPE_AUDIO)
            continue;
        MLDStream *stream = is_video ? &context->video : &context->audio;
        MLDStream *other = is_video ? &context->audio : &context->video;
        if (stream->index < 0 && !same_program(context, other->index, packet->stream_index))
            continue;
        if (stream->index >= 0 && stream->index != packet->stream_index)
            continue;
        if (par->codec_id != (is_video ? AV_CODEC_ID_H264 : AV_CODEC_ID_AAC))
            return MLD_UNSUPPORTED;
        if (packet->size <= 0 || packet->size > MLD_MAX_PACKET_BYTES || !packet->data ||
            (packet->flags & AV_PKT_FLAG_CORRUPT) ||
            av_stream->time_base.num <= 0 || av_stream->time_base.den <= 0)
            return MLD_INVALID;
        if (stream->index < 0) {
            stream->index = packet->stream_index;
            stream->time_base = av_stream->time_base;
            stream->wrap_bits = av_stream->pts_wrap_bits;
        } else if (av_cmp_q(stream->time_base, av_stream->time_base) != 0 ||
                   stream->wrap_bits != av_stream->pts_wrap_bits) {
            return MLD_UNSUPPORTED;
        }

        *view = (MLDPacket){
            .kind = is_video ? MLD_VIDEO : MLD_AUDIO,
            .pts = packet_seconds(packet->pts, stream->time_base),
            .dts = packet_seconds(packet->dts, stream->time_base),
            .duration = packet->duration > 0 ? packet_seconds(packet->duration, stream->time_base) : NAN,
        };
        if (is_video) {
            int has_access_unit = 0;
            result = mld_video_packet(&stream->codec, context->format, par, packet,
                                      &has_access_unit, &view->is_key);
            if (result != MLD_OK)
                return result;
            if (!has_access_unit)
                continue;
            if (!stream->has_key) {
                if (!view->is_key || !isfinite(view->pts) || !stream->codec.config)
                    continue;
                stream->has_key = 1;
            } else if (!isfinite(view->pts)) {
                return MLD_INVALID;
            }
        } else {
            result = mld_audio_packet(&stream->codec, context->format, par, packet);
            if (result != MLD_OK)
                return result;
            if (!isfinite(view->pts) && !isfinite(view->dts)) {
                if (!stream->has_timed_packet)
                    continue;
                return MLD_INVALID;
            }
            view->is_key = 1;
            if (!isfinite(view->duration))
                view->duration = stream->codec.audio_duration;
        }
        result = update_timing(context, stream, view);
        if (result != MLD_OK)
            return result;
        view->data = packet->data;
        view->size = packet->size;
        return operation_failure(context);
    }
    return MLD_INVALID;
}

MLDContext *mld_create(int format, void *opaque, int (*read)(void *, uint8_t *, int, int),
                       int (*interrupted)(void *))
{
    if (!read || !interrupted)
        return NULL;
    MLDContext *context = calloc(1, sizeof(*context));
    if (context) {
        context->format = format;
        context->opaque = opaque;
        context->read = read;
        context->interrupted = interrupted;
        context->video.index = context->audio.index = -1;
        context->video.last_dts = context->audio.last_dts = NAN;
        context->video.last_clock = context->audio.last_clock = NAN;
        context->origin = NAN;
    }
    return context;
}

static const AVInputFormat *live_input_format(int format)
{
    switch (format) {
    case MLD_TS: return av_find_input_format("mpegts");
    case MLD_FLV: return av_find_input_format("live_flv");
    default: return NULL;
    }
}

int mld_format_available(int format)
{
    return live_input_format(format) != NULL;
}

static int open_input(MLDContext *context)
{
    const AVInputFormat *demuxer = live_input_format(context->format);
    if (!demuxer)
        return MLD_UNSUPPORTED;

    if (context->format == MLD_FLV) {
        int result = read_flv_header(context);
        if (result != MLD_OK)
            return result;
    }
    context->input = avformat_alloc_context();
    context->scratch = av_packet_alloc();
    if (!context->input || !context->scratch)
        return MLD_INVALID;
    uint8_t *buffer = av_malloc(IO_BUFFER_BYTES);
    if (!buffer)
        return MLD_INVALID;
    context->io = avio_alloc_context(buffer, IO_BUFFER_BYTES, 0, context, read_avio, NULL, NULL);
    if (!context->io) {
        av_free(buffer);
        return MLD_INVALID;
    }
    context->input->pb = context->io;
    context->input->flags |= AVFMT_FLAG_CUSTOM_IO | AVFMT_FLAG_IGNIDX;
    if (context->format == MLD_FLV)
        context->input->flags |= AVFMT_FLAG_NOFILLIN;
    context->input->interrupt_callback = (AVIOInterruptCB){interrupt_avio, context};
    context->input->probesize = TS_HEADER_SCAN_BYTES;
    context->input->max_probe_packets = MAX_PROBE_PACKETS;
    context->input->max_streams = 24;
    int result = avformat_open_input(&context->input, NULL, demuxer, NULL);
    return classify_av_result(context, result);
}

static int probe_input(MLDContext *context)
{
    while (context->probe_count < MAX_PROBE_PACKETS) {
        MLDPacket view;
        int result = read_one(context, &view);
        if (result != MLD_OK)
            return result;
        if (view.size > MAX_PROBE_BYTES - context->probe_bytes)
            return MLD_INVALID;
        AVPacket *buffer = av_packet_alloc();
        if (!buffer)
            return MLD_INVALID;
        av_packet_move_ref(buffer, context->scratch);
        context->probe[context->probe_count++] = (MLDQueuedPacket){buffer, view};
        context->probe_bytes += view.size;
        if (context->video.codec.config && context->video.has_key &&
            context->audio.codec.config && context->audio.has_timed_packet)
            return MLD_OK;
    }
    return MLD_INVALID;
}

int mld_open(MLDContext *context)
{
    if (!context || context->opened)
        return MLD_INVALID;
    context->opened = 1;
    begin_operation(context, MAX_PROBE_BYTES, PROBE_TIME_US);
    int result = open_input(context);
    if (result == MLD_OK)
        result = probe_input(context);
    context->terminal = result;
    context->ready = result == MLD_OK;
    return result;
}

int mld_next(MLDContext *context, MLDPacket *packet)
{
    if (!context || !packet || !context->opened)
        return MLD_INVALID;
    if (context->scratch)
        av_packet_unref(context->scratch);
    if (context->interrupted(context->opaque))
        context->terminal = MLD_INTERRUPTED;
    if (context->terminal)
        return context->terminal;

    if (context->probe_cursor < context->probe_count) {
        MLDQueuedPacket *entry = &context->probe[context->probe_cursor++];
        av_packet_move_ref(context->scratch, entry->buffer);
        av_packet_free(&entry->buffer);
        *packet = entry->view;
        return MLD_OK;
    }

    begin_operation(context, MAX_READ_BYTES, READ_TIME_US);
    context->terminal = read_one(context, packet);
    return context->terminal;
}

int mld_track(MLDContext *context, int kind, MLDTrack *track)
{
    if (!context || !context->ready || !track || (kind != MLD_VIDEO && kind != MLD_AUDIO))
        return MLD_INVALID;
    const MLDCodec *codec = kind == MLD_VIDEO ? &context->video.codec : &context->audio.codec;
    *track = (MLDTrack){kind == MLD_VIDEO ? MLD_AVC : MLD_AAC, codec->config, codec->config_size};
    return MLD_OK;
}

void mld_destroy(MLDContext *context)
{
    if (!context)
        return;
    av_packet_free(&context->scratch);
    for (int i = 0; i < context->probe_count; ++i)
        av_packet_free(&context->probe[i].buffer);
    mld_codec_clear(&context->video.codec);
    mld_codec_clear(&context->audio.codec);
    avformat_close_input(&context->input);
    if (context->io) {
        av_freep(&context->io->buffer);
        avio_context_free(&context->io);
    }
    free(context);
}
