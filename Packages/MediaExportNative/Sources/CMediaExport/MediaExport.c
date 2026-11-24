#include "MediaExport.h"
#include <ExportNamespace.h>
#include <TargetConditionals.h>
#include <inttypes.h>
#include <math.h>
#include <stdarg.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <libavcodec/avcodec.h>
#include <libavfilter/avfilter.h>
#include <libavfilter/buffersink.h>
#include <libavfilter/buffersrc.h>
#include <libavformat/avformat.h>
#include <libavutil/avutil.h>
#include <libavutil/channel_layout.h>
#include <libavutil/display.h>
#include <libavutil/dovi_meta.h>
#include <libavutil/hwcontext.h>
#include <libavutil/hwcontext_vulkan.h>
#include <libavutil/opt.h>
#include <libavutil/pixdesc.h>
#include <vulkan/vulkan.h>

struct me_export_job {
    me_export_options options;
    char *video;
    char *audio;
    char *output;
    atomic_int cancelled;
    char error[512];
    char validation_detail[384];
    int executed;
    uint64_t video_units_written;
    uint64_t audio_units_written;
    enum AVCodecID source_video_codec_id;
    enum AVCodecID source_audio_codec_id;
    int source_has_audio;
    int expected_width;
    int expected_height;
    int64_t source_duration_us;
};

typedef struct {
    AVFormatContext *input;
    AVStream *source;
    AVStream *destination;
    AVCodecContext *decoder;
    AVCodecContext *encoder;
    AVFilterGraph *graph;
    AVFilterContext *filter_source;
    AVFilterContext *filter_sink;
    AVBufferRef *gpu;
    int index;
    const char *input_stage;
    me_export_job *job;
    int64_t default_frame_dur;
    int64_t default_enc_dur;
    int has_last_frame_pts;
    int64_t last_frame_pts;
    int has_last_enc_pts;
    int64_t last_enc_pts;
    int64_t next_audio_enc_pts;
    int has_last_mux_dts;
    int64_t last_mux_dts;
} track;

static int interrupted(void *p) {
    return atomic_load(&((me_export_job *)p)->cancelled);
}

static int fail(me_export_job *j, int code, const char *where) {
    char detail[AV_ERROR_MAX_STRING_SIZE];
    av_strerror(code, detail, sizeof(detail));
    snprintf(j->error, sizeof(j->error), "%s: %s", where, detail);
    return code;
}

static void validation_note(me_export_job *j, const char *stage, const char *format, ...) av_printf_format(3, 4);
static void validation_note(me_export_job *j, const char *stage, const char *format, ...) {
    if (j->validation_detail[0]) return;
    int length = snprintf(j->validation_detail, sizeof(j->validation_detail), "%s.%s ",
                          j->options.mode == ME_EXPORT_REMUX ? "remux" : "transcode", stage);
    if (length < 0 || (size_t)length >= sizeof(j->validation_detail)) return;
    va_list args;
    va_start(args, format);
    vsnprintf(j->validation_detail + length, sizeof(j->validation_detail) - (size_t)length, format, args);
    va_end(args);
}

uint32_t me_export_abi_version(void) {
    return ME_EXPORT_ABI_VERSION;
}

const char *me_export_codec_name(int codec_id) {
    if (codec_id == AV_CODEC_ID_NONE) return NULL;
    return avcodec_get_name((enum AVCodecID)codec_id);
}

me_export_job *me_export_job_create(const me_export_options *o) {
    if (!o || !o->video_path || !o->output_path) return NULL;
    me_export_job *j = calloc(1, sizeof(*j));
    if (!j) return NULL;
    j->video = strdup(o->video_path);
    j->audio = o->audio_path ? strdup(o->audio_path) : NULL;
    j->output = strdup(o->output_path);
    j->options = *o;
    if (!j->video || !j->output || (o->audio_path && !j->audio)) {
        me_export_job_destroy(j);
        return NULL;
    }
    j->options.video_path = j->video;
    j->options.audio_path = j->audio;
    j->options.output_path = j->output;
    atomic_init(&j->cancelled, 0);
    return j;
}

void me_export_job_cancel(me_export_job *j) {
    if (j) atomic_store(&j->cancelled, 1);
}

const char *me_export_job_error(const me_export_job *j) {
    return j ? j->error : "Invalid job";
}

void me_export_job_destroy(me_export_job *j) {
    if (!j) return;
    free(j->video);
    free(j->audio);
    free(j->output);
    free(j);
}

static int open_input(me_export_job *j, const char *path, AVFormatContext **ctx, const char **stage) {
    *stage = "alloc";
    *ctx = avformat_alloc_context();
    if (!*ctx) return AVERROR(ENOMEM);
    (*ctx)->interrupt_callback = (AVIOInterruptCB){ interrupted, j };
    *stage = "open";
    int r = avformat_open_input(ctx, path, NULL, NULL);
    if (r >= 0) {
        *stage = "stream-info";
        r = avformat_find_stream_info(*ctx, NULL);
    }
    return r;
}

static const AVPacketSideData *side(AVStream *s, enum AVPacketSideDataType type) {
    return av_packet_side_data_get(s->codecpar->coded_side_data, s->codecpar->nb_coded_side_data, type);
}

static void close_track(track *t) {
    avfilter_graph_free(&t->graph);
    av_buffer_unref(&t->gpu);
    avcodec_free_context(&t->encoder);
    avcodec_free_context(&t->decoder);
    avformat_close_input(&t->input);
}

static int find_track(me_export_job *j, track *t, const char *path, enum AVMediaType type) {
    t->job = j;
    t->index = -1;
    int r = open_input(j, path, &t->input, &t->input_stage);
    if (r < 0) return r;
    t->input_stage = "select";
    t->index = av_find_best_stream(t->input, type, -1, -1, NULL, 0);
    if (t->index < 0) return t->index;
    t->source = t->input->streams[t->index];
    return 0;
}

static int64_t track_duration_us(const AVFormatContext *fmt, const AVStream *stream) {
    if (fmt && fmt->duration > 0) return fmt->duration;
    if (stream && stream->duration > 0 && stream->time_base.num > 0 && stream->time_base.den > 0) {
        return av_rescale_q(stream->duration, stream->time_base, AV_TIME_BASE_Q);
    }
    return 0;
}

static AVRational safe_time_base(AVRational tb) {
    if (tb.num > 0 && tb.den > 0) return tb;
    return (AVRational){ 1, 90000 };
}

static AVRational safe_sar(const AVStream *s, const AVCodecContext *dec) {
    if (s && s->sample_aspect_ratio.num > 0 && s->sample_aspect_ratio.den > 0) {
        return s->sample_aspect_ratio;
    }
    if (s && s->codecpar && s->codecpar->sample_aspect_ratio.num > 0 && s->codecpar->sample_aspect_ratio.den > 0) {
        return s->codecpar->sample_aspect_ratio;
    }
    if (dec && dec->sample_aspect_ratio.num > 0 && dec->sample_aspect_ratio.den > 0) {
        return dec->sample_aspect_ratio;
    }
    return (AVRational){ 1, 1 };
}

static AVRational resolve_frame_rate(AVFormatContext *fmt, AVStream *stream) {
    AVRational fr = av_guess_frame_rate(fmt, stream, NULL);
    if (fr.num > 0 && fr.den > 0) return fr;
    if (stream->avg_frame_rate.num > 0 && stream->avg_frame_rate.den > 0) return stream->avg_frame_rate;
    if (stream->r_frame_rate.num > 0 && stream->r_frame_rate.den > 0) return stream->r_frame_rate;
    return (AVRational){ 30, 1 };
}

static me_export_color resolve_color(AVStream *s, me_export_color requested) {
    if (requested != ME_EXPORT_COLOR_SOURCE) return requested;
    const AVPacketSideData *dv = side(s, AV_PKT_DATA_DOVI_CONF);
    if (s->codecpar->color_trc == AVCOL_TRC_ARIB_STD_B67) return ME_EXPORT_COLOR_HLG;
    if (dv || s->codecpar->color_trc == AVCOL_TRC_SMPTE2084) return ME_EXPORT_COLOR_PQ;
    return ME_EXPORT_COLOR_SDR;
}

static int has_isobmff_extradata(const AVCodecParameters *par) {
    if (!par || !par->extradata || par->extradata_size <= 0) return 0;
    if (par->extradata_size >= 3 &&
        par->extradata[0] == 0 && par->extradata[1] == 0 && par->extradata[2] == 1) {
        return 0;
    }
    if (par->extradata_size >= 4 &&
        par->extradata[0] == 0 && par->extradata[1] == 0 &&
        par->extradata[2] == 0 && par->extradata[3] == 1) {
        return 0;
    }
    return 1;
}

static void apply_mp4_codec_tag(AVCodecParameters *par, int is_transcode) {
    if (!par) return;
    par->codec_tag = 0;
    if (par->codec_id == AV_CODEC_ID_HEVC) {
        if (is_transcode || has_isobmff_extradata(par)) {
            par->codec_tag = MKTAG('h', 'v', 'c', '1');
        }
    } else if (par->codec_id == AV_CODEC_ID_H264) {
        if (is_transcode || has_isobmff_extradata(par)) {
            par->codec_tag = MKTAG('a', 'v', 'c', '1');
        }
    }
}

me_export_result me_export_job_probe(me_export_job *j, me_export_inventory *i) {
    if (!j || !i) return ME_EXPORT_FAILED;
    memset(i, 0, sizeof(*i));
    track v = {0}, a = {0};
    int r = find_track(j, &v, j->video, AVMEDIA_TYPE_VIDEO);
    if (r < 0) {
        fail(j, r, "Open video");
        goto done;
    }
    AVCodecParameters *p = v.source->codecpar;
    i->width = p->width;
    i->height = p->height;
    i->video_codec_id = p->codec_id;
    i->video_bitrate = p->bit_rate;
    i->bit_depth = p->bits_per_raw_sample;
    const AVPixFmtDescriptor *d = av_pix_fmt_desc_get(p->format);
    if (!i->bit_depth && d) i->bit_depth = d->comp[0].depth;
    i->color_primaries = p->color_primaries;
    i->color_transfer = p->color_trc;
    i->color_matrix = p->color_space;
    i->color_range = p->color_range;
    i->duration_microseconds = track_duration_us(v.input, v.source);
    AVRational fr = resolve_frame_rate(v.input, v.source);
    i->average_frame_rate = av_q2d(fr);

    const AVPacketSideData *dv = side(v.source, AV_PKT_DATA_DOVI_CONF);
    if (dv && dv->size >= sizeof(AVDOVIDecoderConfigurationRecord)) {
        const AVDOVIDecoderConfigurationRecord *c = (const void *)dv->data;
        i->dolby_vision_profile = c->dv_profile;
        i->dolby_vision_level = c->dv_level;
        i->dolby_has_base_layer = c->bl_present_flag;
        i->dolby_has_enhancement_layer = c->el_present_flag;
        i->dolby_has_rpu = c->rpu_present_flag;
    }
    i->has_mastering_metadata = side(v.source, AV_PKT_DATA_MASTERING_DISPLAY_METADATA) != NULL;
    i->has_content_light_metadata = side(v.source, AV_PKT_DATA_CONTENT_LIGHT_LEVEL) != NULL;

    r = find_track(j, &a, j->audio ? j->audio : j->video, AVMEDIA_TYPE_AUDIO);
    if (r >= 0) {
        i->has_audio = 1;
        i->audio_codec_id = a.source->codecpar->codec_id;
        i->audio_channels = a.source->codecpar->ch_layout.nb_channels;
        i->audio_sample_rate = a.source->codecpar->sample_rate;
        if (i->duration_microseconds <= 0) {
            i->duration_microseconds = track_duration_us(a.input, a.source);
        }
    } else if (!j->audio && r == AVERROR_STREAM_NOT_FOUND) {
        r = 0;
    } else {
        fail(j, r, "Open audio");
    }

done:
    close_track(&v);
    close_track(&a);
    return interrupted(j) ? ME_EXPORT_CANCELLED : r < 0 ? ME_EXPORT_FAILED : ME_EXPORT_OK;
}

static int copy_track(track *t, AVFormatContext *out) {
    if (avformat_query_codec(out->oformat, t->source->codecpar->codec_id, FF_COMPLIANCE_NORMAL) <= 0) {
        return AVERROR(EINVAL);
    }
    t->destination = avformat_new_stream(out, NULL);
    if (!t->destination) return AVERROR(ENOMEM);
    int r = avcodec_parameters_copy(t->destination->codecpar, t->source->codecpar);
    if (r < 0) return r;
    apply_mp4_codec_tag(t->destination->codecpar, 0);
    t->destination->time_base = safe_time_base(t->source->time_base);
    t->destination->sample_aspect_ratio = t->source->sample_aspect_ratio;
    return av_dict_copy(&t->destination->metadata, t->source->metadata, 0);
}

static int output_packet(track *t, AVFormatContext *out, AVPacket *p, AVRational timebase) {
    av_packet_rescale_ts(p, safe_time_base(timebase), t->destination->time_base);
    p->stream_index = t->destination->index;
    p->pos = -1;

    if (p->dts == AV_NOPTS_VALUE) {
        if (p->pts != AV_NOPTS_VALUE) {
            p->dts = p->pts;
        } else if (t->has_last_mux_dts) {
            p->dts = t->last_mux_dts + (p->duration > 0 ? p->duration : 1);
        } else {
            p->dts = 0;
        }
    }
    if (p->pts == AV_NOPTS_VALUE) {
        p->pts = p->dts;
    }
    if (t->has_last_mux_dts && p->dts <= t->last_mux_dts) {
        p->dts = t->last_mux_dts + 1;
    }
    if (p->pts < p->dts) {
        p->pts = p->dts;
    }
    if (p->duration < 0) {
        p->duration = 0;
    }

    t->last_mux_dts = p->dts;
    t->has_last_mux_dts = 1;

    int r = av_interleaved_write_frame(out, p);
    if (r >= 0) {
        if (t->destination->codecpar->codec_type == AVMEDIA_TYPE_VIDEO) {
            t->job->video_units_written++;
        } else if (t->destination->codecpar->codec_type == AVMEDIA_TYPE_AUDIO) {
            t->job->audio_units_written++;
        }
    }
    return r;
}

static int encoder_drain(track *t, AVFormatContext *out) {
    AVPacket *p = av_packet_alloc();
    if (!p) return AVERROR(ENOMEM);
    int r = 0;
    while (!interrupted(t->job) && (r = avcodec_receive_packet(t->encoder, p)) >= 0) {
        r = output_packet(t, out, p, t->encoder->time_base);
        av_packet_unref(p);
        if (r < 0) break;
    }
    av_packet_free(&p);
    return interrupted(t->job) ? AVERROR_EXIT : (r == AVERROR(EAGAIN) || r == AVERROR_EOF) ? 0 : r;
}

static int encode_frame(track *t, AVFormatContext *out, AVFrame *f) {
    if (f) {
        AVRational filter_time = av_buffersink_get_time_base(t->filter_sink);
        if (f->pts != AV_NOPTS_VALUE) {
            f->pts = av_rescale_q(f->pts, filter_time, t->encoder->time_base);
        }
        if (f->duration > 0) {
            f->duration = av_rescale_q(f->duration, filter_time, t->encoder->time_base);
        }
        if (f->duration < 0) {
            f->duration = 0;
        }

        if (t->decoder->codec_type == AVMEDIA_TYPE_VIDEO) {
            if (f->pts == AV_NOPTS_VALUE) {
                int64_t step = t->default_enc_dur > 0 ? t->default_enc_dur : 1;
                f->pts = t->has_last_enc_pts ? (t->last_enc_pts + step) : 0;
            }
            if (t->has_last_enc_pts && f->pts <= t->last_enc_pts) {
                f->pts = t->last_enc_pts + 1;
            }
            t->last_enc_pts = f->pts;
            t->has_last_enc_pts = 1;
        } else {
            if (f->pts == AV_NOPTS_VALUE) {
                f->pts = t->has_last_enc_pts ? t->next_audio_enc_pts : 0;
            }
            if (t->has_last_enc_pts && f->pts < t->next_audio_enc_pts) {
                f->pts = t->next_audio_enc_pts;
            }
            t->next_audio_enc_pts = f->pts + (f->nb_samples > 0 ? f->nb_samples : 1);
            t->has_last_enc_pts = 1;
            if (f->duration <= 0 && f->nb_samples > 0) {
                f->duration = f->nb_samples;
            }
        }
    }
    int r = avcodec_send_frame(t->encoder, f);
    if (r == AVERROR_EOF && !f) return 0;
    return r < 0 ? r : encoder_drain(t, out);
}

static int filter_drain(track *t, AVFormatContext *out) {
    AVFrame *f = av_frame_alloc();
    if (!f) return AVERROR(ENOMEM);
    int r = 0;
    while (!interrupted(t->job) && (r = av_buffersink_get_frame(t->filter_sink, f)) >= 0) {
        r = encode_frame(t, out, f);
        av_frame_unref(f);
        if (r < 0) break;
    }
    av_frame_free(&f);
    return interrupted(t->job) ? AVERROR_EXIT : (r == AVERROR(EAGAIN) || r == AVERROR_EOF) ? 0 : r;
}

static int decode_packet(track *t, AVFormatContext *out, AVPacket *p) {
    int r = avcodec_send_packet(t->decoder, p);
    if (r == AVERROR_EOF && !p) return 0;
    if (r < 0) return r;
    AVFrame *f = av_frame_alloc();
    if (!f) return AVERROR(ENOMEM);
    AVRational src_tb = safe_time_base(t->source->time_base);

    while (!interrupted(t->job) && (r = avcodec_receive_frame(t->decoder, f)) >= 0) {
        if (t->decoder->codec_type == AVMEDIA_TYPE_VIDEO) {
            if (f->pts == AV_NOPTS_VALUE) {
                f->pts = f->best_effort_timestamp;
            }
            if (f->pts == AV_NOPTS_VALUE) {
                int64_t step = t->default_frame_dur > 0 ? t->default_frame_dur : 1;
                f->pts = t->has_last_frame_pts ? (t->last_frame_pts + step) : 0;
            }
            if (t->has_last_frame_pts && f->pts <= t->last_frame_pts) {
                f->pts = t->last_frame_pts + 1;
            }
            if (f->duration < 0) {
                f->duration = 0;
            }
            t->last_frame_pts = f->pts;
            t->has_last_frame_pts = 1;
        } else if (t->decoder->codec_type == AVMEDIA_TYPE_AUDIO) {
            if (f->sample_rate <= 0) {
                f->sample_rate = t->decoder->sample_rate;
            }
            if (f->sample_rate <= 0) {
                r = AVERROR_INVALIDDATA;
                break;
            }
            if (f->pts == AV_NOPTS_VALUE) {
                f->pts = f->best_effort_timestamp;
            }
            if (f->pts == AV_NOPTS_VALUE) {
                f->pts = t->has_last_frame_pts ? t->last_frame_pts : 0;
            }
            int64_t dur = av_rescale_q(f->nb_samples > 0 ? f->nb_samples : 1,
                                       (AVRational){ 1, f->sample_rate }, src_tb);
            t->last_frame_pts = f->pts + (dur > 0 ? dur : 1);
            t->has_last_frame_pts = 1;
        }

        r = av_buffersrc_add_frame_flags(t->filter_source, f, AV_BUFFERSRC_FLAG_KEEP_REF);
        av_frame_unref(f);
        if (r >= 0) r = filter_drain(t, out);
        if (r < 0) break;
    }
    av_frame_free(&f);
    return interrupted(t->job) ? AVERROR_EXIT : (r == AVERROR(EAGAIN) || r == AVERROR_EOF) ? 0 : r;
}

static void fitted_size(const AVCodecParameters *p, const me_export_options *o, int *width, int *height) {
    double sar = (p->sample_aspect_ratio.num > 0 && p->sample_aspect_ratio.den > 0)
        ? av_q2d(p->sample_aspect_ratio) : 1.0;
    double display_w = p->width * sar;
    double display_h = p->height;
    double scale = 1.0;
    if (o->maximum_long_edge > 0) {
        scale = fmin(scale, o->maximum_long_edge / fmax(display_w, display_h));
    }
    if (o->maximum_short_edge > 0) {
        scale = fmin(scale, o->maximum_short_edge / fmin(display_w, display_h));
    }
    *width = ((int)(display_w * scale) / 2) * 2;
    *height = ((int)(display_h * scale) / 2) * 2;
}

typedef struct {
    int flags;
    int width;
    int height;
    AVRational time_base;
    AVRational framerate;
    AVRational sample_aspect_ratio;
    enum AVPixelFormat pix_fmt;
    int profile;
    enum AVColorPrimaries color_primaries;
    enum AVColorTransferCharacteristic color_trc;
    enum AVColorSpace colorspace;
    enum AVColorRange color_range;
    int64_t bit_rate;
    int64_t rc_max_rate;
    int rc_buffer_size;
} video_encoder_config;

static void apply_video_encoder_config(AVCodecContext *ctx, const video_encoder_config *cfg, int with_rate_limits) {
    ctx->flags = cfg->flags;
    ctx->width = cfg->width;
    ctx->height = cfg->height;
    ctx->time_base = cfg->time_base;
    ctx->framerate = cfg->framerate;
    ctx->sample_aspect_ratio = cfg->sample_aspect_ratio;
    ctx->pix_fmt = cfg->pix_fmt;
    ctx->profile = cfg->profile;
    ctx->color_primaries = cfg->color_primaries;
    ctx->color_trc = cfg->color_trc;
    ctx->colorspace = cfg->colorspace;
    ctx->color_range = cfg->color_range;
    ctx->bit_rate = cfg->bit_rate;
    ctx->rc_max_rate = with_rate_limits ? cfg->rc_max_rate : 0;
    ctx->rc_buffer_size = with_rate_limits ? cfg->rc_buffer_size : 0;
}

static int open_video_encoder(track *t, const AVCodec *enc, const video_encoder_config *cfg) {
    AVDictionary *opts = NULL;
    av_dict_set(&opts, "realtime", "0", 0);
    av_dict_set(&opts, "allow_sw", "1", 0);
    int r = avcodec_open2(t->encoder, enc, &opts);
    av_dict_free(&opts);
    if (r >= 0 || cfg->rc_max_rate <= 0) {
        return r;
    }

    // Apple's hevc_videotoolbox rejects kVTCompressionPropertyKey_DataRateLimits (-12900)
    // on some hardware/simulator sessions. Retry cleanly with AverageBitRate only.
    AVCodecContext *retry = avcodec_alloc_context3(enc);
    if (!retry) return r;
    apply_video_encoder_config(retry, cfg, 0);
    AVDictionary *retry_opts = NULL;
    av_dict_set(&retry_opts, "realtime", "0", 0);
    av_dict_set(&retry_opts, "allow_sw", "1", 0);
    int retry_r = avcodec_open2(retry, enc, &retry_opts);
    av_dict_free(&retry_opts);
    if (retry_r >= 0) {
        avcodec_free_context(&t->encoder);
        t->encoder = retry;
        return 0;
    }
    avcodec_free_context(&retry);
    return r;
}

static int setup_transcode(me_export_job *j, track *t, AVFormatContext *out, int video) {
    const AVCodec *dec = t->source->codecpar->codec_id == AV_CODEC_ID_AV1
        ? avcodec_find_decoder_by_name("libdav1d")
        : avcodec_find_decoder(t->source->codecpar->codec_id);
    if (!dec) return AVERROR_DECODER_NOT_FOUND;

    t->decoder = avcodec_alloc_context3(dec);
    if (!t->decoder) return AVERROR(ENOMEM);
    int r = avcodec_parameters_to_context(t->decoder, t->source->codecpar);
    if (r < 0) return r;
    AVRational src_tb = safe_time_base(t->source->time_base);
    t->decoder->pkt_timebase = src_tb;
    if ((r = avcodec_open2(t->decoder, dec, NULL)) < 0) return r;

    const char *name = video
        ? (j->options.mode == ME_EXPORT_H264 ? "h264_videotoolbox" : "hevc_videotoolbox")
        : "aac";
    const AVCodec *enc = avcodec_find_encoder_by_name(name);
    if (!enc) return AVERROR_ENCODER_NOT_FOUND;
    t->encoder = avcodec_alloc_context3(enc);
    if (!t->encoder) return AVERROR(ENOMEM);
    t->encoder->flags |= AV_CODEC_FLAG_GLOBAL_HEADER;

    char source_args[512];
    char filter_args[1024];
    t->graph = avfilter_graph_alloc();
    if (!t->graph) return AVERROR(ENOMEM);

    me_export_color target_color = ME_EXPORT_COLOR_SDR;
    int hdr = 0;

    if (video) {
        if (t->decoder->pix_fmt == AV_PIX_FMT_NONE || t->decoder->width < 1 || t->decoder->height < 1) {
            return AVERROR_INVALIDDATA;
        }
        int w = 0, h = 0;
        fitted_size(t->source->codecpar, &j->options, &w, &h);
        if (w < 2 || h < 2) return AVERROR(EINVAL);

        target_color = resolve_color(t->source, j->options.color);
        hdr = (target_color == ME_EXPORT_COLOR_PQ || target_color == ME_EXPORT_COLOR_HLG);
        if (hdr && j->options.mode != ME_EXPORT_HEVC) return AVERROR(EINVAL);

        AVRational fr = resolve_frame_rate(t->input, t->source);
        t->encoder->width = w;
        t->encoder->height = h;
        t->encoder->time_base = src_tb;
        t->encoder->framerate = fr;
        t->encoder->sample_aspect_ratio = (AVRational){ 1, 1 };
        t->encoder->pix_fmt = hdr ? AV_PIX_FMT_P010LE : AV_PIX_FMT_NV12;
        t->encoder->profile = hdr
            ? AV_PROFILE_HEVC_MAIN_10
            : (j->options.mode == ME_EXPORT_HEVC ? AV_PROFILE_HEVC_MAIN : AV_PROFILE_H264_HIGH);
        t->encoder->color_primaries = hdr ? AVCOL_PRI_BT2020 : AVCOL_PRI_BT709;
        t->encoder->color_trc = hdr
            ? (target_color == ME_EXPORT_COLOR_HLG ? AVCOL_TRC_ARIB_STD_B67 : AVCOL_TRC_SMPTE2084)
            : AVCOL_TRC_BT709;
        t->encoder->colorspace = hdr ? AVCOL_SPC_BT2020_NCL : AVCOL_SPC_BT709;
        t->encoder->color_range = AVCOL_RANGE_MPEG;

        t->default_frame_dur = av_rescale_q(1, av_inv_q(fr), src_tb);
        if (t->default_frame_dur < 1) t->default_frame_dur = 1;
        t->default_enc_dur = av_rescale_q(1, av_inv_q(fr), t->encoder->time_base);
        if (t->default_enc_dur < 1) t->default_enc_dur = 1;

        int hevc = j->options.mode == ME_EXPORT_HEVC;
        double base = j->options.resolution_tier == 720
            ? (hevc ? 3e6 : 5e6)
            : j->options.resolution_tier == 1080
                ? (hevc ? 5e6 : 8e6)
                : j->options.resolution_tier == 2160
                    ? (hevc ? 16e6 : 24e6)
                    : fmax(hevc ? 1.5e6 : 2.5e6, (hevc ? 5e6 : 8e6) * w * h / (1920.0 * 1080.0));
        base *= fmin(2.0, fmax(1.0, av_q2d(fr) / 30.0));

        const AVPixFmtDescriptor *dec_desc = av_pix_fmt_desc_get(t->decoder->pix_fmt);
        const AVPixFmtDescriptor *enc_desc = av_pix_fmt_desc_get(t->encoder->pix_fmt);
        if (dec_desc && enc_desc &&
            t->source->codecpar->codec_id == enc->id &&
            t->source->codecpar->color_trc == t->encoder->color_trc &&
            t->source->codecpar->color_primaries == t->encoder->color_primaries &&
            t->source->codecpar->color_space == t->encoder->colorspace &&
            dec_desc->comp[0].depth == enc_desc->comp[0].depth &&
            t->source->codecpar->bit_rate > 0) {
            base = fmax(base * 0.5, fmin(base, t->source->codecpar->bit_rate * 1.25));
        }
        t->encoder->bit_rate = (int64_t)base;
        t->encoder->rc_max_rate = (int64_t)(base * 1.5);
        t->encoder->rc_buffer_size = (int)(base * 2.0);

        AVRational sar = safe_sar(t->source, t->decoder);
        snprintf(source_args, sizeof(source_args),
                 "video_size=%dx%d:pix_fmt=%d:time_base=%d/%d:pixel_aspect=%d/%d",
                 t->decoder->width, t->decoder->height, t->decoder->pix_fmt,
                 src_tb.num, src_tb.den, sar.num, sar.den);
        if ((r = avfilter_graph_create_filter(&t->filter_source, avfilter_get_by_name("buffer"),
                                              "source", source_args, NULL, t->graph)) < 0) {
            return r;
        }
        if ((r = avfilter_graph_create_filter(&t->filter_sink, avfilter_get_by_name("buffersink"),
                                              "sink", NULL, NULL, t->graph)) < 0) {
            return r;
        }
#if TARGET_OS_SIMULATOR
        AVDictionary *hw_opts = NULL;
        av_dict_set(&hw_opts, "avoid_host_import", "1", 0);
        r = av_hwdevice_ctx_create(&t->gpu, AV_HWDEVICE_TYPE_VULKAN, NULL, hw_opts, 0);
        av_dict_free(&hw_opts);
        if (r < 0) return r;
#else
        if ((r = av_hwdevice_ctx_create(&t->gpu, AV_HWDEVICE_TYPE_VULKAN, NULL, NULL, 0)) < 0) {
            return r;
        }
#endif
        snprintf(filter_args, sizeof(filter_args),
                 "libplacebo=w=%d:h=%d:format=%s:colorspace=%s:color_primaries=%s:color_trc=%s:range=tv:reset_sar=1:apply_dolbyvision=1",
                 w, h, hdr ? "p010le" : "nv12",
                 hdr ? "bt2020nc" : "bt709",
                 hdr ? "bt2020" : "bt709",
                 hdr ? (target_color == ME_EXPORT_COLOR_HLG ? "arib-std-b67" : "smpte2084") : "bt709");
    } else {
        if (t->decoder->sample_rate <= 0 ||
            t->decoder->ch_layout.nb_channels < 1 ||
            t->decoder->ch_layout.nb_channels > 8) {
            return AVERROR(EINVAL);
        }
        const char *sfmt = av_get_sample_fmt_name(t->decoder->sample_fmt);
        if (!sfmt) return AVERROR(EINVAL);
        if (t->decoder->ch_layout.order == AV_CHANNEL_ORDER_UNSPEC) {
            av_channel_layout_default(&t->decoder->ch_layout, t->decoder->ch_layout.nb_channels);
        }

        t->encoder->time_base = (AVRational){ 1, t->decoder->sample_rate };
        t->encoder->sample_rate = t->decoder->sample_rate;
        t->encoder->sample_fmt = AV_SAMPLE_FMT_FLTP;
        if ((r = av_channel_layout_copy(&t->encoder->ch_layout, &t->decoder->ch_layout)) < 0) {
            return r;
        }
        t->encoder->bit_rate = t->decoder->ch_layout.nb_channels == 1
            ? 96000
            : (t->decoder->ch_layout.nb_channels == 2 ? 192000 : 384000);

        char layout[128];
        if ((r = av_channel_layout_describe(&t->decoder->ch_layout, layout, sizeof(layout))) < 0) {
            return r;
        }
        snprintf(source_args, sizeof(source_args),
                 "time_base=%d/%d:sample_rate=%d:sample_fmt=%s:channel_layout=%s",
                 src_tb.num, src_tb.den, t->decoder->sample_rate, sfmt, layout);
        if ((r = avfilter_graph_create_filter(&t->filter_source, avfilter_get_by_name("abuffer"),
                                              "source", source_args, NULL, t->graph)) < 0) {
            return r;
        }
        if ((r = avfilter_graph_create_filter(&t->filter_sink, avfilter_get_by_name("abuffersink"),
                                              "sink", NULL, NULL, t->graph)) < 0) {
            return r;
        }
        snprintf(filter_args, sizeof(filter_args),
                 "aformat=sample_fmts=fltp:sample_rates=%d:channel_layouts=%s",
                 t->encoder->sample_rate, layout);
    }

    AVFilterInOut *inputs = avfilter_inout_alloc();
    AVFilterInOut *outputs = avfilter_inout_alloc();
    if (!inputs || !outputs) {
        avfilter_inout_free(&inputs);
        avfilter_inout_free(&outputs);
        return AVERROR(ENOMEM);
    }
    outputs->name = av_strdup("in");
    outputs->filter_ctx = t->filter_source;
    outputs->pad_idx = 0;
    inputs->name = av_strdup("out");
    inputs->filter_ctx = t->filter_sink;
    inputs->pad_idx = 0;

#if TARGET_OS_SIMULATOR
    AVVulkanDeviceContext *sim_vkctx = NULL;
    int sim_saved_ext_count = 0;
    if (video && t->gpu) {
        AVHWDeviceContext *hwdev = (AVHWDeviceContext *)t->gpu->data;
        sim_vkctx = hwdev ? (AVVulkanDeviceContext *)hwdev->hwctx : NULL;
        if (sim_vkctx && sim_vkctx->enabled_dev_extensions && sim_vkctx->nb_enabled_dev_extensions > 0) {
            // MTLSimDriver aborts in _xpc_shmem_create_with_prot when MoltenVK imports
            // host pointers via VK_EXT_external_memory_host; hide it from libplacebo
            // during init/config and restore count before teardown.
            const char **exts = (const char **)sim_vkctx->enabled_dev_extensions;
            sim_saved_ext_count = sim_vkctx->nb_enabled_dev_extensions;
            int active = sim_saved_ext_count;
            for (int n = 0; n < active; ) {
                if (exts[n] && strcmp(exts[n], "VK_EXT_external_memory_host") == 0) {
                    const char *tmp = exts[n];
                    exts[n] = exts[active - 1];
                    exts[active - 1] = tmp;
                    active--;
                } else {
                    n++;
                }
            }
            sim_vkctx->nb_enabled_dev_extensions = active;
        }
    }
#endif

    if (video) {
        AVFilterContext *color = avfilter_graph_alloc_filter(t->graph, avfilter_get_by_name("libplacebo"), "color");
        if (!color) {
            avfilter_inout_free(&inputs);
            avfilter_inout_free(&outputs);
#if TARGET_OS_SIMULATOR
            if (sim_vkctx && sim_saved_ext_count > 0) sim_vkctx->nb_enabled_dev_extensions = sim_saved_ext_count;
#endif
            return AVERROR(ENOMEM);
        }
        color->hw_device_ctx = av_buffer_ref(t->gpu);
        r = avfilter_init_str(color, filter_args + strlen("libplacebo="));
        if (r >= 0) r = avfilter_link(t->filter_source, 0, color, 0);
        if (r >= 0) r = avfilter_link(color, 0, t->filter_sink, 0);
    } else {
        r = avfilter_graph_parse_ptr(t->graph, filter_args, &inputs, &outputs, NULL);
    }
    avfilter_inout_free(&inputs);
    avfilter_inout_free(&outputs);
    if (r >= 0) r = avfilter_graph_config(t->graph, NULL);
#if TARGET_OS_SIMULATOR
    if (sim_vkctx && sim_saved_ext_count > 0) {
        sim_vkctx->nb_enabled_dev_extensions = sim_saved_ext_count;
    }
#endif
    if (r < 0) return r;

    if (video) {
        video_encoder_config cfg = {
            .flags = t->encoder->flags,
            .width = t->encoder->width,
            .height = t->encoder->height,
            .time_base = t->encoder->time_base,
            .framerate = t->encoder->framerate,
            .sample_aspect_ratio = t->encoder->sample_aspect_ratio,
            .pix_fmt = t->encoder->pix_fmt,
            .profile = t->encoder->profile,
            .color_primaries = t->encoder->color_primaries,
            .color_trc = t->encoder->color_trc,
            .colorspace = t->encoder->colorspace,
            .color_range = t->encoder->color_range,
            .bit_rate = t->encoder->bit_rate,
            .rc_max_rate = t->encoder->rc_max_rate,
            .rc_buffer_size = t->encoder->rc_buffer_size,
        };
        r = open_video_encoder(t, enc, &cfg);
    } else {
        r = avcodec_open2(t->encoder, enc, NULL);
    }
    if (r < 0) return r;

    if (!video) {
        av_buffersink_set_frame_size(t->filter_sink, t->encoder->frame_size > 0 ? t->encoder->frame_size : 1024);
    }

    t->destination = avformat_new_stream(out, NULL);
    if (!t->destination) return AVERROR(ENOMEM);
    t->destination->time_base = t->encoder->time_base;
    t->destination->sample_aspect_ratio = t->encoder->sample_aspect_ratio;
    if ((r = avcodec_parameters_from_context(t->destination->codecpar, t->encoder)) < 0) return r;
    apply_mp4_codec_tag(t->destination->codecpar, 1);

    const AVPacketSideData *matrix = side(t->source, AV_PKT_DATA_DISPLAYMATRIX);
    if (matrix) {
        AVPacketSideData *m = av_packet_side_data_new(&t->destination->codecpar->coded_side_data,
                                                      &t->destination->codecpar->nb_coded_side_data,
                                                      AV_PKT_DATA_DISPLAYMATRIX, matrix->size, 0);
        if (!m) return AVERROR(ENOMEM);
        memcpy(m->data, matrix->data, matrix->size);
    }
    if (video && hdr) {
        enum AVPacketSideDataType types[] = {
            AV_PKT_DATA_MASTERING_DISPLAY_METADATA,
            AV_PKT_DATA_CONTENT_LIGHT_LEVEL
        };
        for (int n = 0; n < 2; n++) {
            const AVPacketSideData *original = side(t->source, types[n]);
            if (original) {
                AVPacketSideData *copy = av_packet_side_data_new(&t->destination->codecpar->coded_side_data,
                                                                 &t->destination->codecpar->nb_coded_side_data,
                                                                 types[n], original->size, 0);
                if (!copy) return AVERROR(ENOMEM);
                memcpy(copy->data, original->data, original->size);
            }
        }
    }
    return 0;
}

me_export_result me_export_job_execute(me_export_job *j, me_export_progress_callback cb, void *context) {
    if (!j) return ME_EXPORT_FAILED;
    track v = {0}, a = {0};
    AVFormatContext *out = NULL;
    AVPacket *pending[2] = { NULL, NULL };
    int r = 0, have_audio = 0, output_created = 0;

    j->executed = 0;
    j->video_units_written = 0;
    j->audio_units_written = 0;
    j->source_video_codec_id = AV_CODEC_ID_NONE;
    j->source_audio_codec_id = AV_CODEC_ID_NONE;
    j->source_has_audio = 0;
    j->expected_width = 0;
    j->expected_height = 0;
    j->source_duration_us = 0;

    if (access(j->output, F_OK) == 0) {
        r = AVERROR(EEXIST);
        goto done;
    }

    if ((r = find_track(j, &v, j->video, AVMEDIA_TYPE_VIDEO)) < 0) goto done;
    if (j->options.include_audio) {
        r = find_track(j, &a, j->audio ? j->audio : j->video, AVMEDIA_TYPE_AUDIO);
        if (r >= 0) {
            have_audio = 1;
        } else if (!j->audio && r == AVERROR_STREAM_NOT_FOUND) {
            r = 0;
        } else {
            goto done;
        }
    }

    j->source_video_codec_id = v.source->codecpar->codec_id;
    j->source_has_audio = have_audio;
    j->source_audio_codec_id = have_audio ? a.source->codecpar->codec_id : AV_CODEC_ID_NONE;
    j->source_duration_us = track_duration_us(v.input, v.source);
    if (j->source_duration_us <= 0 && have_audio) {
        j->source_duration_us = track_duration_us(a.input, a.source);
    }
    if (j->options.mode == ME_EXPORT_REMUX) {
        j->expected_width = v.source->codecpar->width;
        j->expected_height = v.source->codecpar->height;
    } else {
        fitted_size(v.source->codecpar, &j->options, &j->expected_width, &j->expected_height);
    }

    if ((r = avformat_alloc_output_context2(&out, NULL, "mp4", j->output)) < 0) goto done;
    if (j->options.mode == ME_EXPORT_REMUX) {
        r = copy_track(&v, out);
        if (r >= 0 && have_audio) r = copy_track(&a, out);
    } else {
        r = setup_transcode(j, &v, out, 1);
        if (r >= 0 && have_audio) r = setup_transcode(j, &a, out, 0);
    }
    if (r < 0) goto done;

    out->interrupt_callback = (AVIOInterruptCB){ interrupted, j };
    if ((r = avio_open2(&out->pb, j->output, AVIO_FLAG_READ_WRITE, &out->interrupt_callback, NULL)) < 0) {
        goto done;
    }
    output_created = 1;

    AVDictionary *mux_opts = NULL;
    av_dict_set(&mux_opts, "movflags", "+faststart", 0);
    r = avformat_write_header(out, &mux_opts);
    av_dict_free(&mux_opts);
    if (r < 0) goto done;

    track *tracks[2] = { &v, &a };
    int ended[2] = { 0, !have_audio };
    pending[0] = av_packet_alloc();
    pending[1] = av_packet_alloc();
    if (!pending[0] || !pending[1]) {
        r = AVERROR(ENOMEM);
        goto done;
    }

    double duration_seconds = j->source_duration_us > 0 ? j->source_duration_us / (double)AV_TIME_BASE : 0.0;
    double max_position = 0.0;

    while (!ended[0] || !ended[1]) {
        for (int n = 0; n < 2; n++) {
            if (ended[n] || pending[n]->size) continue;
            track *t = tracks[n];
            while ((r = av_read_frame(t->input, pending[n])) >= 0 && pending[n]->stream_index != t->index) {
                av_packet_unref(pending[n]);
            }
            if (r == AVERROR_EOF) {
                ended[n] = 1;
                r = 0;
                if (j->options.mode != ME_EXPORT_REMUX) {
                    if ((r = decode_packet(t, out, NULL)) >= 0) {
                        r = av_buffersrc_add_frame_flags(t->filter_source, NULL, 0);
                    }
                    if (r >= 0) r = filter_drain(t, out);
                    if (r >= 0) r = encode_frame(t, out, NULL);
                }
            }
            if (r < 0) break;
        }
        if (r < 0 || interrupted(j)) break;

        int n = pending[0]->size ? 0 : 1;
        if (pending[0]->size && pending[1]->size) {
            int64_t ts0 = pending[0]->dts != AV_NOPTS_VALUE ? pending[0]->dts : pending[0]->pts;
            int64_t ts1 = pending[1]->dts != AV_NOPTS_VALUE ? pending[1]->dts : pending[1]->pts;
            if (ts0 != AV_NOPTS_VALUE && ts1 != AV_NOPTS_VALUE &&
                av_compare_ts(ts0, safe_time_base(tracks[0]->source->time_base),
                              ts1, safe_time_base(tracks[1]->source->time_base)) > 0) {
                n = 1;
            }
        }
        if (!pending[n]->size) continue;

        track *t = tracks[n];
        int64_t pos_ts = pending[n]->pts != AV_NOPTS_VALUE ? pending[n]->pts : pending[n]->dts;
        if (pos_ts != AV_NOPTS_VALUE) {
            double pos = pos_ts * av_q2d(safe_time_base(t->source->time_base));
            if (pos > max_position) max_position = pos;
        }

        r = j->options.mode == ME_EXPORT_REMUX
            ? output_packet(t, out, pending[n], t->source->time_base)
            : decode_packet(t, out, pending[n]);
        av_packet_unref(pending[n]);

        if (cb) {
            me_export_progress progress = {
                max_position,
                duration_seconds,
                out->pb ? avio_tell(out->pb) : 0
            };
            cb(context, &progress);
        }
        if (r < 0) break;
    }

    if (interrupted(j)) {
        r = AVERROR_EXIT;
        goto done;
    }
    if (r < 0) goto done;

    r = av_write_trailer(out);
    if (r >= 0) {
        j->executed = 1;
    }

done:
    av_packet_free(&pending[0]);
    av_packet_free(&pending[1]);
    close_track(&v);
    close_track(&a);
    if (out) {
        if (out->pb) {
            int close_result = avio_closep(&out->pb);
            if (r >= 0) r = close_result;
        }
        avformat_free_context(out);
    }
    if (r < 0 && !interrupted(j)) fail(j, r, "Export");
    if ((r < 0 || interrupted(j)) && output_created) unlink(j->output);
    return interrupted(j) ? ME_EXPORT_CANCELLED : r < 0 ? ME_EXPORT_FAILED : ME_EXPORT_OK;
}

me_export_result me_export_job_validate_output(me_export_job *j) {
    if (!j) return ME_EXPORT_FAILED;
    j->validation_detail[0] = 0;

    enum AVCodecID expected_vcodec = j->source_video_codec_id;
    enum AVCodecID expected_acodec = j->source_audio_codec_id;
    int expected_has_audio = j->source_has_audio;
    int expected_w = j->expected_width;
    int expected_h = j->expected_height;
    int64_t expected_dur_us = j->source_duration_us;

    if (!j->executed) {
        track sv = {0}, sa = {0};
        int sr = find_track(j, &sv, j->video, AVMEDIA_TYPE_VIDEO);
        if (sr < 0) {
            validation_note(j, "source-video", "stage=%s code=%d", sv.input_stage, sr);
            close_track(&sv);
            if (!interrupted(j)) {
                char where[448];
                snprintf(where, sizeof(where), "Validate finalized MP4 [%s]", j->validation_detail);
                fail(j, sr, where);
            }
            return interrupted(j) ? ME_EXPORT_CANCELLED : ME_EXPORT_FAILED;
        }
        expected_vcodec = sv.source->codecpar->codec_id;
        expected_dur_us = track_duration_us(sv.input, sv.source);
        if (j->options.mode == ME_EXPORT_REMUX) {
            expected_w = sv.source->codecpar->width;
            expected_h = sv.source->codecpar->height;
        } else {
            fitted_size(sv.source->codecpar, &j->options, &expected_w, &expected_h);
        }
        if (j->options.include_audio) {
            sr = find_track(j, &sa, j->audio ? j->audio : j->video, AVMEDIA_TYPE_AUDIO);
            if (sr >= 0) {
                expected_has_audio = 1;
                expected_acodec = sa.source->codecpar->codec_id;
                if (expected_dur_us <= 0) {
                    expected_dur_us = track_duration_us(sa.input, sa.source);
                }
            }
        }
        close_track(&sv);
        close_track(&sa);
    }

    AVFormatContext *out_ctx = NULL;
    AVPacket *pkt = NULL;
    const char *stage = "open";
    int r = open_input(j, j->output, &out_ctx, &stage);
    if (r < 0) {
        validation_note(j, "output-open", "stage=%s code=%d", stage, r);
        goto done;
    }

    int v_idx = av_find_best_stream(out_ctx, AVMEDIA_TYPE_VIDEO, -1, -1, NULL, 0);
    if (v_idx < 0) {
        validation_note(j, "video-stream", "missing code=%d", v_idx);
        r = v_idx;
        goto done;
    }

    AVStream *v_stream = out_ctx->streams[v_idx];
    AVCodecParameters *vp = v_stream->codecpar;
    if (vp->width <= 0 || vp->height <= 0) {
        validation_note(j, "video-geometry", "invalid=%dx%d", vp->width, vp->height);
        r = AVERROR_INVALIDDATA;
        goto done;
    }

    if (j->options.mode != ME_EXPORT_REMUX) {
        enum AVCodecID target_codec = j->options.mode == ME_EXPORT_H264 ? AV_CODEC_ID_H264 : AV_CODEC_ID_HEVC;
        if (vp->codec_id != target_codec) {
            validation_note(j, "video-codec", "expected=%d actual=%d", target_codec, vp->codec_id);
            r = AVERROR_INVALIDDATA;
            goto done;
        }
        if (expected_w > 0 && expected_h > 0 &&
            (abs(vp->width - expected_w) > 2 || abs(vp->height - expected_h) > 2)) {
            validation_note(j, "video-geometry", "expected=%dx%d actual=%dx%d",
                            expected_w, expected_h, vp->width, vp->height);
            r = AVERROR_INVALIDDATA;
            goto done;
        }
    } else if (expected_vcodec != AV_CODEC_ID_NONE && vp->codec_id != expected_vcodec) {
        validation_note(j, "video-codec", "expected=%d actual=%d", expected_vcodec, vp->codec_id);
        r = AVERROR_INVALIDDATA;
        goto done;
    }

    if (j->executed && j->video_units_written == 0) {
        validation_note(j, "video-payload", "written=0");
        r = AVERROR_INVALIDDATA;
        goto done;
    }

    if (j->options.include_audio && expected_has_audio) {
        int a_idx = av_find_best_stream(out_ctx, AVMEDIA_TYPE_AUDIO, -1, -1, NULL, 0);
        if (a_idx < 0) {
            validation_note(j, "audio-stream", "missing code=%d", a_idx);
            r = a_idx;
            goto done;
        }
        AVCodecParameters *ap = out_ctx->streams[a_idx]->codecpar;
        if (j->options.mode != ME_EXPORT_REMUX) {
            if (ap->codec_id != AV_CODEC_ID_AAC) {
                validation_note(j, "audio-codec", "expected=%d actual=%d", AV_CODEC_ID_AAC, ap->codec_id);
                r = AVERROR_INVALIDDATA;
                goto done;
            }
        } else if (expected_acodec != AV_CODEC_ID_NONE && ap->codec_id != expected_acodec) {
            validation_note(j, "audio-codec", "expected=%d actual=%d", expected_acodec, ap->codec_id);
            r = AVERROR_INVALIDDATA;
            goto done;
        }
        if (ap->sample_rate <= 0 || ap->ch_layout.nb_channels <= 0) {
            validation_note(j, "audio-params", "rate=%d channels=%d",
                            ap->sample_rate, ap->ch_layout.nb_channels);
            r = AVERROR_INVALIDDATA;
            goto done;
        }
        if (j->executed && j->audio_units_written == 0) {
            validation_note(j, "audio-payload", "written=0");
            r = AVERROR_INVALIDDATA;
            goto done;
        }
    }

    // Confirm at least 1 non-empty video packet is readable from the finalized container (O(1)).
    pkt = av_packet_alloc();
    if (!pkt) {
        r = AVERROR(ENOMEM);
        goto done;
    }
    int found_video_packet = 0;
    while (!interrupted(j) && (r = av_read_frame(out_ctx, pkt)) >= 0) {
        int is_video = (pkt->stream_index == v_idx && pkt->size > 0);
        av_packet_unref(pkt);
        if (is_video) {
            found_video_packet = 1;
            break;
        }
    }
    if (interrupted(j)) {
        r = AVERROR_EXIT;
        goto done;
    }
    if (!found_video_packet) {
        validation_note(j, "video-payload", "no readable video packet code=%d", r);
        r = (r < 0 && r != AVERROR_EOF) ? r : AVERROR_INVALIDDATA;
        goto done;
    }
    r = 0;

    int64_t out_dur_us = track_duration_us(out_ctx, v_stream);
    if (expected_dur_us > 0) {
        if (out_dur_us <= 0) {
            validation_note(j, "duration", "source-us=%" PRId64 " output-us=%" PRId64,
                            expected_dur_us, out_dur_us);
            r = AVERROR_INVALIDDATA;
            goto done;
        }
        int64_t tol = expected_dur_us / 20;
        if (tol < 1500000) tol = 1500000;
        if (llabs(expected_dur_us - out_dur_us) > tol) {
            validation_note(j, "duration", "source-us=%" PRId64 " output-us=%" PRId64 " tol-us=%" PRId64,
                            expected_dur_us, out_dur_us, tol);
            r = AVERROR_INVALIDDATA;
            goto done;
        }
    }

done:
    av_packet_free(&pkt);
    avformat_close_input(&out_ctx);
    if (r < 0 && !interrupted(j)) {
        char where[448];
        snprintf(where, sizeof(where), "Validate finalized MP4 [%s]",
                 j->validation_detail[0] ? j->validation_detail : "unspecified");
        fail(j, r, where);
    }
    return interrupted(j) ? ME_EXPORT_CANCELLED : r < 0 ? ME_EXPORT_FAILED : ME_EXPORT_OK;
}

me_export_result me_export_job_check_capability(me_export_job *j) {
    if (!j) return ME_EXPORT_FAILED;
    track video = {0}, audio = {0};
    AVFormatContext *out = NULL;
    int r = find_track(j, &video, j->video, AVMEDIA_TYPE_VIDEO);
    if (r >= 0) r = avformat_alloc_output_context2(&out, NULL, "mp4", NULL);
    if (r >= 0) {
        if (j->options.mode == ME_EXPORT_REMUX) {
            r = copy_track(&video, out);
        } else {
            r = setup_transcode(j, &video, out, 1);
        }
    }
    if (r >= 0 && j->options.include_audio) {
        r = find_track(j, &audio, j->audio ? j->audio : j->video, AVMEDIA_TYPE_AUDIO);
        if (r == AVERROR_STREAM_NOT_FOUND && !j->audio) {
            r = 0;
        } else if (r >= 0) {
            r = j->options.mode == ME_EXPORT_REMUX
                ? copy_track(&audio, out)
                : setup_transcode(j, &audio, out, 0);
        }
    }
    close_track(&video);
    close_track(&audio);
    avformat_free_context(out);
    if (r < 0 && !interrupted(j)) fail(j, r, "Admit exact export recipe");
    return interrupted(j) ? ME_EXPORT_CANCELLED : r < 0 ? ME_EXPORT_FAILED : ME_EXPORT_OK;
}
