#include "MediaExport.h"
#include <ExportNamespace.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <stdarg.h>
#include <inttypes.h>
#include <unistd.h>
#include <math.h>
#include <libavformat/avformat.h>
#include <libavcodec/avcodec.h>
#include <libavutil/avutil.h>
#include <libavutil/dovi_meta.h>
#include <libavutil/pixdesc.h>
#include <libavutil/channel_layout.h>
#include <libavutil/display.h>
#include <libavutil/sha.h>
#include <libavutil/opt.h>
#include <libavutil/hwcontext.h>
#include <libavutil/hwcontext_vulkan.h>
#include <libavfilter/avfilter.h>
#include <libavfilter/buffersrc.h>
#include <libavfilter/buffersink.h>
#include <vulkan/vulkan.h>

struct me_export_job {
    me_export_options options;
    char *video, *audio, *output;
    atomic_int cancelled;
    char error[512];
    char validation_detail[384];
    struct AVSHA *video_timeline;
    struct AVSHA *decoded_video_timeline;
    uint8_t expected_video_timeline[32];
    int timeline_ready;
    int64_t audio_first, audio_end;
    int audio_timing_ready;
    int source_audio_timing_ready;
    int64_t source_audio_first,source_audio_end;
};
typedef struct {
    AVFormatContext *input;
    AVStream *source, *destination;
    AVCodecContext *decoder, *encoder;
    AVFilterGraph *graph;
    AVFilterContext *filter_source, *filter_sink;
    AVBufferRef *gpu;
    int index;
    const char *input_stage;
    me_export_job *job;
} track;
static int interrupted(void *p) { return atomic_load(&((me_export_job *)p)->cancelled); }
static int fail(me_export_job *j, int code, const char *where) {
    char detail[AV_ERROR_MAX_STRING_SIZE]; av_strerror(code, detail, sizeof(detail));
    snprintf(j->error, sizeof(j->error), "%s: %s", where, detail); return code;
}
uint32_t me_export_abi_version(void) { return ME_EXPORT_ABI_VERSION; }
me_export_job *me_export_job_create(const me_export_options *o) {
    if (!o || !o->video_path || !o->output_path) return NULL;
    me_export_job *j = calloc(1, sizeof(*j)); if (!j) return NULL;
    j->video = strdup(o->video_path); j->audio = o->audio_path ? strdup(o->audio_path) : NULL;
    j->output = strdup(o->output_path); j->options = *o;
    if (!j->video || !j->output || (o->audio_path && !j->audio)) { me_export_job_destroy(j); return NULL; }
    j->options.video_path = j->video; j->options.audio_path = j->audio; j->options.output_path = j->output;
    atomic_init(&j->cancelled, 0); return j;
}
void me_export_job_cancel(me_export_job *j) { if (j) atomic_store(&j->cancelled, 1); }
const char *me_export_job_error(const me_export_job *j) { return j ? j->error : "Invalid job"; }
void me_export_job_destroy(me_export_job *j) { if (j) { free(j->video); free(j->audio); free(j->output); av_free(j->video_timeline); av_free(j->decoded_video_timeline); free(j); } }
static int open_input(me_export_job *j, const char *path, AVFormatContext **ctx, const char **stage) {
    *stage="alloc";
    *ctx = avformat_alloc_context(); if (!*ctx) return AVERROR(ENOMEM);
    (*ctx)->interrupt_callback = (AVIOInterruptCB){ interrupted, j };
    *stage="open";
    int r = avformat_open_input(ctx, path, NULL, NULL);
    if (r >= 0) { *stage="stream-info"; r = avformat_find_stream_info(*ctx, NULL); }
    return r;
}
static const AVPacketSideData *side(AVStream *s, enum AVPacketSideDataType type) {
    return av_packet_side_data_get(s->codecpar->coded_side_data, s->codecpar->nb_coded_side_data, type);
}
static void close_track(track *t) {
    avfilter_graph_free(&t->graph); av_buffer_unref(&t->gpu);
    avcodec_free_context(&t->encoder); avcodec_free_context(&t->decoder);
    avformat_close_input(&t->input);
}
static int find_track(me_export_job *j, track *t, const char *path, enum AVMediaType type) {
    t->job=j;t->index=-1;
    int r = open_input(j, path, &t->input, &t->input_stage); if (r < 0) return r;
    t->input_stage="select";
    t->index = av_find_best_stream(t->input, type, -1, -1, NULL, 0);
    if (t->index < 0) return t->index;
    t->source = t->input->streams[t->index]; return 0;
}
me_export_result me_export_job_probe(me_export_job *j, me_export_inventory *i) {
    if (!j || !i) return ME_EXPORT_FAILED;
    memset(i, 0, sizeof(*i)); track v = {0}, a = {0};
    int r = find_track(j, &v, j->video, AVMEDIA_TYPE_VIDEO);
    if (r < 0) { fail(j,r,"Open video"); goto done; }
    AVCodecParameters *p = v.source->codecpar;
    i->width=p->width; i->height=p->height; i->video_codec_id=p->codec_id; i->video_bitrate=p->bit_rate;
    i->bit_depth=p->bits_per_raw_sample;
    const AVPixFmtDescriptor *d=av_pix_fmt_desc_get(p->format); if (!i->bit_depth && d) i->bit_depth=d->comp[0].depth;
    i->color_primaries=p->color_primaries; i->color_transfer=p->color_trc; i->color_matrix=p->color_space; i->color_range=p->color_range;
    i->duration_microseconds=v.input->duration;
    i->average_frame_rate=av_q2d(av_guess_frame_rate(v.input,v.source,NULL));
    const AVPacketSideData *dv=side(v.source,AV_PKT_DATA_DOVI_CONF);
    if (dv && dv->size >= sizeof(AVDOVIDecoderConfigurationRecord)) {
        const AVDOVIDecoderConfigurationRecord *c=(const void *)dv->data;
        i->dolby_vision_profile=c->dv_profile; i->dolby_vision_level=c->dv_level;
        i->dolby_has_base_layer=c->bl_present_flag; i->dolby_has_enhancement_layer=c->el_present_flag; i->dolby_has_rpu=c->rpu_present_flag;
    }
    i->has_mastering_metadata=side(v.source,AV_PKT_DATA_MASTERING_DISPLAY_METADATA)!=NULL;
    i->has_content_light_metadata=side(v.source,AV_PKT_DATA_CONTENT_LIGHT_LEVEL)!=NULL;
    r=find_track(j,&a,j->audio ? j->audio:j->video,AVMEDIA_TYPE_AUDIO);
    if (r>=0) { i->has_audio=1; i->audio_codec_id=a.source->codecpar->codec_id; i->audio_channels=a.source->codecpar->ch_layout.nb_channels; i->audio_sample_rate=a.source->codecpar->sample_rate; }
    else if (!j->audio && r==AVERROR_STREAM_NOT_FOUND) r=0;
    else fail(j,r,"Open audio");
done:
    close_track(&v);close_track(&a);
    return interrupted(j) ? ME_EXPORT_CANCELLED : r<0 ? ME_EXPORT_FAILED:ME_EXPORT_OK;
}
static int copy_track(track *t, AVFormatContext *out) {
    t->destination=avformat_new_stream(out,NULL); if (!t->destination) return AVERROR(ENOMEM);
    int r=avcodec_parameters_copy(t->destination->codecpar,t->source->codecpar);
    t->destination->codecpar->codec_tag=0; t->destination->time_base=t->source->time_base;
    t->destination->sample_aspect_ratio=t->source->sample_aspect_ratio;
    if (r>=0) r=av_dict_copy(&t->destination->metadata,t->source->metadata,0);
    return r;
}
static int output_packet(track *t, AVFormatContext *out, AVPacket *p, AVRational timebase) {
    av_packet_rescale_ts(p,timebase,t->destination->time_base);p->stream_index=t->destination->index;p->pos=-1;
    return av_interleaved_write_frame(out,p);
}
static int encoder_drain(track *t,AVFormatContext *out) {
    AVPacket *p=av_packet_alloc();if(!p)return AVERROR(ENOMEM);int r;
    while(!interrupted(t->job)&&(r=avcodec_receive_packet(t->encoder,p))>=0) { r=output_packet(t,out,p,t->encoder->time_base);av_packet_unref(p);if(r<0)break; }
    av_packet_free(&p);return interrupted(t->job)?AVERROR_EXIT:r==AVERROR(EAGAIN)||r==AVERROR_EOF?0:r;
}
static int encode_frame(track *t,AVFormatContext *out,AVFrame *f) {
    if(f){
        AVRational filter_time=av_buffersink_get_time_base(t->filter_sink);
        if(f->pts!=AV_NOPTS_VALUE)f->pts=av_rescale_q(f->pts,filter_time,t->encoder->time_base);
        if(f->duration>0)f->duration=av_rescale_q(f->duration,filter_time,t->encoder->time_base);
        if(t->decoder->codec_type==AVMEDIA_TYPE_VIDEO){
            if(f->pts==AV_NOPTS_VALUE||f->duration<=0)return AVERROR_INVALIDDATA;
            int64_t timeline[2]={av_rescale_q(f->pts,t->encoder->time_base,AV_TIME_BASE_Q),av_rescale_q(f->duration,t->encoder->time_base,AV_TIME_BASE_Q)};
            av_sha_update(t->job->video_timeline,(const uint8_t *)timeline,sizeof(timeline));
        }else if(f->pts!=AV_NOPTS_VALUE){
            int64_t first=av_rescale_q(f->pts,t->encoder->time_base,AV_TIME_BASE_Q);
            int64_t end=first+av_rescale_q(f->nb_samples,(AVRational){1,f->sample_rate},AV_TIME_BASE_Q);
            if(!t->job->audio_timing_ready)t->job->audio_first=first;
            t->job->audio_end=end;t->job->audio_timing_ready=1;
        }
    }
    int r=avcodec_send_frame(t->encoder,f);return r<0?r:encoder_drain(t,out);
}
static int filter_drain(track *t,AVFormatContext *out) {
    AVFrame *f=av_frame_alloc();if(!f)return AVERROR(ENOMEM);int r;
    while(!interrupted(t->job)&&(r=av_buffersink_get_frame(t->filter_sink,f))>=0){r=encode_frame(t,out,f);av_frame_unref(f);if(r<0)break;}
    av_frame_free(&f);return interrupted(t->job)?AVERROR_EXIT:r==AVERROR(EAGAIN)||r==AVERROR_EOF?0:r;
}
static int decode_packet(track *t,AVFormatContext *out,AVPacket *p) {
    int r=avcodec_send_packet(t->decoder,p);if(r<0)return r;
    AVFrame *f=av_frame_alloc();if(!f)return AVERROR(ENOMEM);
    while(!interrupted(t->job)&&(r=avcodec_receive_frame(t->decoder,f))>=0){
        if(t->decoder->codec_type==AVMEDIA_TYPE_VIDEO){
            if(f->pts==AV_NOPTS_VALUE||f->duration<=0){r=AVERROR_INVALIDDATA;break;}
            int64_t timing[2]={av_rescale_q(f->pts,t->source->time_base,AV_TIME_BASE_Q),av_rescale_q(f->duration,t->source->time_base,AV_TIME_BASE_Q)};
            av_sha_update(t->job->decoded_video_timeline,(const uint8_t *)timing,sizeof(timing));
        }
        if(t->decoder->codec_type==AVMEDIA_TYPE_AUDIO){
            if(f->pts==AV_NOPTS_VALUE||f->sample_rate<=0){r=AVERROR_INVALIDDATA;break;}
            int64_t first=av_rescale_q(f->pts,t->source->time_base,AV_TIME_BASE_Q),end=first+av_rescale_q(f->nb_samples,(AVRational){1,f->sample_rate},AV_TIME_BASE_Q);
            if(!t->job->source_audio_timing_ready)t->job->source_audio_first=first;
            t->job->source_audio_end=end;t->job->source_audio_timing_ready=1;
        }
        if(t->decoder->codec_type==AVMEDIA_TYPE_VIDEO && side(t->source,AV_PKT_DATA_DOVI_CONF) && !av_frame_get_side_data(f,AV_FRAME_DATA_DOVI_METADATA)){r=AVERROR_INVALIDDATA;break;}
        r=av_buffersrc_add_frame_flags(t->filter_source,f,AV_BUFFERSRC_FLAG_KEEP_REF);av_frame_unref(f);
        if(r>=0)r=filter_drain(t,out);if(r<0)break;
    }
    av_frame_free(&f);return interrupted(t->job)?AVERROR_EXIT:r==AVERROR(EAGAIN)||r==AVERROR_EOF?0:r;
}
static void fitted_size(const AVCodecParameters *p,const me_export_options *o,int *width,int *height){
    double sar=p->sample_aspect_ratio.num>0&&p->sample_aspect_ratio.den>0?av_q2d(p->sample_aspect_ratio):1;
    double display_w=p->width*sar,display_h=p->height,scale=1;
    if(o->maximum_long_edge>0)scale=fmin(scale,o->maximum_long_edge/fmax(display_w,display_h));
    if(o->maximum_short_edge>0)scale=fmin(scale,o->maximum_short_edge/fmin(display_w,display_h));
    *width=(int)(display_w*scale)/2*2;*height=(int)(display_h*scale)/2*2;
}
static int setup_transcode(me_export_job *j,track *t,AVFormatContext *out,int video) {
    const AVCodec *dec=t->source->codecpar->codec_id==AV_CODEC_ID_AV1?avcodec_find_decoder_by_name("libdav1d"):avcodec_find_decoder(t->source->codecpar->codec_id);if(!dec)return AVERROR_DECODER_NOT_FOUND;
    t->decoder=avcodec_alloc_context3(dec);if(!t->decoder)return AVERROR(ENOMEM);
    int r=avcodec_parameters_to_context(t->decoder,t->source->codecpar);if(r<0)return r;
    t->decoder->pkt_timebase=t->source->time_base;
    if((r=avcodec_open2(t->decoder,dec,NULL))<0)return r;
    const char *name=video?(j->options.mode==ME_EXPORT_H264?"h264_videotoolbox":"hevc_videotoolbox"):"aac";
    const AVCodec *enc=avcodec_find_encoder_by_name(name);if(!enc)return AVERROR_ENCODER_NOT_FOUND;
    t->encoder=avcodec_alloc_context3(enc);if(!t->encoder)return AVERROR(ENOMEM);
    t->encoder->flags|=AV_CODEC_FLAG_GLOBAL_HEADER;
    char source_args[512],filter_args[1024];
    t->graph=avfilter_graph_alloc();if(!t->graph)return AVERROR(ENOMEM);
    if(video){
        if(t->decoder->pix_fmt==AV_PIX_FMT_NONE||t->decoder->width<1||t->decoder->height<1)return AVERROR_INVALIDDATA;
        int w,h;fitted_size(t->source->codecpar,&j->options,&w,&h);if(w<2||h<2)return AVERROR(EINVAL);
        if(j->options.color==ME_EXPORT_COLOR_SOURCE) {
            const AVPacketSideData *dv=side(t->source,AV_PKT_DATA_DOVI_CONF);
            j->options.color=t->source->codecpar->color_trc==AVCOL_TRC_ARIB_STD_B67?ME_EXPORT_COLOR_HLG:
                (dv||t->source->codecpar->color_trc==AVCOL_TRC_SMPTE2084)?ME_EXPORT_COLOR_PQ:ME_EXPORT_COLOR_SDR;
        }
        int hdr=j->options.color==ME_EXPORT_COLOR_PQ||j->options.color==ME_EXPORT_COLOR_HLG;
        if(hdr&&j->options.mode!=ME_EXPORT_HEVC)return AVERROR(EINVAL);
        t->encoder->width=w;t->encoder->height=h;t->encoder->time_base=t->source->time_base;
        t->encoder->framerate=av_guess_frame_rate(t->input,t->source,NULL);
        if(t->encoder->framerate.num<=0||t->encoder->framerate.den<=0)return AVERROR_INVALIDDATA;
        t->encoder->sample_aspect_ratio=(AVRational){1,1};
        t->encoder->pix_fmt=hdr?AV_PIX_FMT_P010LE:AV_PIX_FMT_NV12;
        t->encoder->profile=hdr?AV_PROFILE_HEVC_MAIN_10:j->options.mode==ME_EXPORT_HEVC?AV_PROFILE_HEVC_MAIN:AV_PROFILE_H264_HIGH;
        t->encoder->color_primaries=hdr?AVCOL_PRI_BT2020:AVCOL_PRI_BT709;
        t->encoder->color_trc=hdr?(j->options.color==ME_EXPORT_COLOR_HLG?AVCOL_TRC_ARIB_STD_B67:AVCOL_TRC_SMPTE2084):AVCOL_TRC_BT709;
        t->encoder->colorspace=hdr?AVCOL_SPC_BT2020_NCL:AVCOL_SPC_BT709;t->encoder->color_range=AVCOL_RANGE_MPEG;
        int hevc=j->options.mode==ME_EXPORT_HEVC;
        double base=j->options.resolution_tier==720?(hevc?3e6:5e6):j->options.resolution_tier==1080?(hevc?5e6:8e6):j->options.resolution_tier==2160?(hevc?16e6:24e6):fmax(hevc?1.5e6:2.5e6,(hevc?5e6:8e6)*w*h/(1920.0*1080));
        base*=fmin(2,fmax(1,av_q2d(t->encoder->framerate)/30));
        if(t->source->codecpar->codec_id==enc->id&&t->source->codecpar->color_trc==t->encoder->color_trc&&t->source->codecpar->color_primaries==t->encoder->color_primaries&&t->source->codecpar->color_space==t->encoder->colorspace&&av_pix_fmt_desc_get(t->decoder->pix_fmt)->comp[0].depth==av_pix_fmt_desc_get(t->encoder->pix_fmt)->comp[0].depth&&t->source->codecpar->bit_rate>0)base=fmax(base*.5,fmin(base,t->source->codecpar->bit_rate*1.25));
        t->encoder->bit_rate=(int64_t)base;t->encoder->rc_max_rate=base*1.5;t->encoder->rc_buffer_size=base*2;
        snprintf(source_args,sizeof(source_args),"video_size=%dx%d:pix_fmt=%d:time_base=%d/%d:pixel_aspect=%d/%d",t->decoder->width,t->decoder->height,t->decoder->pix_fmt,t->source->time_base.num,t->source->time_base.den,t->source->sample_aspect_ratio.num?t->source->sample_aspect_ratio.num:1,t->source->sample_aspect_ratio.den?t->source->sample_aspect_ratio.den:1);
        if((r=avfilter_graph_create_filter(&t->filter_source,avfilter_get_by_name("buffer"),"source",source_args,NULL,t->graph))<0)return r;
        if((r=avfilter_graph_create_filter(&t->filter_sink,avfilter_get_by_name("buffersink"),"sink",NULL,NULL,t->graph))<0)return r;
        if((r=av_hwdevice_ctx_create(&t->gpu,AV_HWDEVICE_TYPE_VULKAN,NULL,NULL,0))<0)return r;
        snprintf(filter_args,sizeof(filter_args),"libplacebo=w=%d:h=%d:format=%s:colorspace=%s:color_primaries=%s:color_trc=%s:range=tv:reset_sar=1:apply_dolbyvision=1",w,h,hdr?"p010le":"nv12",hdr?"bt2020nc":"bt709",hdr?"bt2020":"bt709",hdr?(j->options.color==ME_EXPORT_COLOR_HLG?"arib-std-b67":"smpte2084"):"bt709");
    }else{
        if(t->decoder->ch_layout.nb_channels<1||t->decoder->ch_layout.nb_channels>8)return AVERROR(EINVAL);
        t->encoder->time_base=(AVRational){1,t->decoder->sample_rate};t->encoder->sample_rate=t->decoder->sample_rate;t->encoder->sample_fmt=AV_SAMPLE_FMT_FLTP;
        av_channel_layout_copy(&t->encoder->ch_layout,&t->decoder->ch_layout);
        t->encoder->bit_rate=t->decoder->ch_layout.nb_channels==1?96000:t->decoder->ch_layout.nb_channels==2?192000:384000;
        char layout[128];av_channel_layout_describe(&t->decoder->ch_layout,layout,sizeof(layout));
        snprintf(source_args,sizeof(source_args),"time_base=%d/%d:sample_rate=%d:sample_fmt=%s:channel_layout=%s",t->source->time_base.num,t->source->time_base.den,t->decoder->sample_rate,av_get_sample_fmt_name(t->decoder->sample_fmt),layout);
        if((r=avfilter_graph_create_filter(&t->filter_source,avfilter_get_by_name("abuffer"),"source",source_args,NULL,t->graph))<0)return r;
        if((r=avfilter_graph_create_filter(&t->filter_sink,avfilter_get_by_name("abuffersink"),"sink",NULL,NULL,t->graph))<0)return r;
        snprintf(filter_args,sizeof(filter_args),"aformat=sample_fmts=fltp:sample_rates=%d:channel_layouts=%s",t->encoder->sample_rate,layout);
    }
    AVFilterInOut *inputs=avfilter_inout_alloc(),*outputs=avfilter_inout_alloc();if(!inputs||!outputs){avfilter_inout_free(&inputs);avfilter_inout_free(&outputs);return AVERROR(ENOMEM);}
    outputs->name=av_strdup("in");outputs->filter_ctx=t->filter_source;outputs->pad_idx=0;
    inputs->name=av_strdup("out");inputs->filter_ctx=t->filter_sink;inputs->pad_idx=0;
    if(video){
        AVFilterContext *color=avfilter_graph_alloc_filter(t->graph,avfilter_get_by_name("libplacebo"),"color");
        if(!color){avfilter_inout_free(&inputs);avfilter_inout_free(&outputs);return AVERROR(ENOMEM);}
        color->hw_device_ctx=av_buffer_ref(t->gpu);
        r=avfilter_init_str(color,filter_args+strlen("libplacebo="));
        if(r>=0)r=avfilter_link(t->filter_source,0,color,0);
        if(r>=0)r=avfilter_link(color,0,t->filter_sink,0);
    }else r=avfilter_graph_parse_ptr(t->graph,filter_args,&inputs,&outputs,NULL);
    avfilter_inout_free(&inputs);avfilter_inout_free(&outputs);if(r<0)return r;
    if((r=avfilter_graph_config(t->graph,NULL))<0)return r;
    if(!video)av_buffersink_set_frame_size(t->filter_sink,1024);
    AVDictionary *opts=NULL;if(video){av_dict_set(&opts,"realtime","0",0);av_dict_set(&opts,"allow_sw","0",0);}
    r=avcodec_open2(t->encoder,enc,&opts);if(r>=0&&av_dict_count(opts))r=AVERROR_OPTION_NOT_FOUND;av_dict_free(&opts);if(r<0)return r;
    t->destination=avformat_new_stream(out,NULL);if(!t->destination)return AVERROR(ENOMEM);
    t->destination->time_base=t->encoder->time_base;t->destination->sample_aspect_ratio=t->encoder->sample_aspect_ratio;
    if((r=avcodec_parameters_from_context(t->destination->codecpar,t->encoder))<0)return r;
    const AVPacketSideData *matrix=side(t->source,AV_PKT_DATA_DISPLAYMATRIX);
    if(matrix){AVPacketSideData *m=av_packet_side_data_new(&t->destination->codecpar->coded_side_data,&t->destination->codecpar->nb_coded_side_data,AV_PKT_DATA_DISPLAYMATRIX,matrix->size,0);if(!m)return AVERROR(ENOMEM);memcpy(m->data,matrix->data,matrix->size);}
    if(video&&(j->options.color==ME_EXPORT_COLOR_PQ||j->options.color==ME_EXPORT_COLOR_HLG)){
        enum AVPacketSideDataType types[]={AV_PKT_DATA_MASTERING_DISPLAY_METADATA,AV_PKT_DATA_CONTENT_LIGHT_LEVEL};
        for(int n=0;n<2;n++){const AVPacketSideData *original=side(t->source,types[n]);if(original){AVPacketSideData *copy=av_packet_side_data_new(&t->destination->codecpar->coded_side_data,&t->destination->codecpar->nb_coded_side_data,types[n],original->size,0);if(!copy)return AVERROR(ENOMEM);memcpy(copy->data,original->data,original->size);}}
    }
    return 0;
}
me_export_result me_export_job_execute(me_export_job *j,me_export_progress_callback cb,void *context){
    if(!j)return ME_EXPORT_FAILED;track v={0},a={0};AVFormatContext *out=NULL;AVPacket *p=av_packet_alloc();int r=0,have_audio=0,output_created=0;
    if(!p){r=AVERROR(ENOMEM);goto done;}
    if(access(j->output,F_OK)==0){r=AVERROR(EEXIST);goto done;}
    j->timeline_ready=0;j->audio_timing_ready=0;j->source_audio_timing_ready=0;
    if(j->options.mode!=ME_EXPORT_REMUX){av_free(j->video_timeline);j->video_timeline=av_sha_alloc();av_free(j->decoded_video_timeline);j->decoded_video_timeline=av_sha_alloc();if(!j->video_timeline||!j->decoded_video_timeline){r=AVERROR(ENOMEM);goto done;}av_sha_init(j->video_timeline,256);av_sha_init(j->decoded_video_timeline,256);}
    if((r=find_track(j,&v,j->video,AVMEDIA_TYPE_VIDEO))<0)goto done;
    if(j->options.include_audio){r=find_track(j,&a,j->audio?j->audio:j->video,AVMEDIA_TYPE_AUDIO);if(r>=0)have_audio=1;else if(!j->audio&&r==AVERROR_STREAM_NOT_FOUND)r=0;else goto done;}
    if((r=avformat_alloc_output_context2(&out,NULL,"mp4",j->output))<0)goto done;
    if(j->options.mode==ME_EXPORT_REMUX){r=copy_track(&v,out);if(r>=0&&have_audio)r=copy_track(&a,out);}else{r=setup_transcode(j,&v,out,1);if(r>=0&&have_audio)r=setup_transcode(j,&a,out,0);}if(r<0)goto done;
    out->interrupt_callback=(AVIOInterruptCB){interrupted,j};
    if((r=avio_open2(&out->pb,j->output,AVIO_FLAG_WRITE,&out->interrupt_callback,NULL))<0)goto done;
    output_created=1;
    if((r=avformat_write_header(out,NULL))<0)goto done;
    track *tracks[2]={&v,&a};
    int ended[2]={0,!have_audio};
    AVPacket *pending[2]={av_packet_alloc(),av_packet_alloc()};
    if(!pending[0]||!pending[1]) {av_packet_free(&pending[0]);av_packet_free(&pending[1]);r=AVERROR(ENOMEM);goto done;}
    while(!ended[0]||!ended[1]) {
        for(int n=0;n<2;n++) {
            if(ended[n]||pending[n]->size)continue;
            track *t=tracks[n];
            while((r=av_read_frame(t->input,pending[n]))>=0 && pending[n]->stream_index!=t->index)av_packet_unref(pending[n]);
            if(r==AVERROR_EOF){
                ended[n]=1;r=0;
                if(j->options.mode!=ME_EXPORT_REMUX){
                    if((r=decode_packet(t,out,NULL))>=0)r=av_buffersrc_add_frame_flags(t->filter_source,NULL,0);
                    if(r>=0)r=filter_drain(t,out);
                    if(r>=0)r=encode_frame(t,out,NULL);
                }
            }
            if(r<0)break;
        }
        if(r<0||interrupted(j))break;
        int n=pending[0]->size?0:1;
        if(pending[0]->size&&pending[1]->size && av_compare_ts(pending[0]->dts,tracks[0]->source->time_base,pending[1]->dts,tracks[1]->source->time_base)>0)n=1;
        if(!pending[n]->size)continue;
        track *t=tracks[n];double position=pending[n]->pts==AV_NOPTS_VALUE?0:pending[n]->pts*av_q2d(t->source->time_base);
        r=j->options.mode==ME_EXPORT_REMUX?output_packet(t,out,pending[n],t->source->time_base):decode_packet(t,out,pending[n]);
        av_packet_unref(pending[n]);
        if(cb){me_export_progress progress={position,v.input->duration/(double)AV_TIME_BASE,out->pb?avio_tell(out->pb):0};cb(context,&progress);}
        if(r<0)break;
    }
    av_packet_free(&pending[0]);av_packet_free(&pending[1]);
    if(interrupted(j)){r=AVERROR_EXIT;goto done;}if(r<0)goto done;
    r=av_write_trailer(out);
    if(r>=0&&j->options.mode!=ME_EXPORT_REMUX){uint8_t source_timeline[32];av_sha_final(j->decoded_video_timeline,source_timeline);av_sha_final(j->video_timeline,j->expected_video_timeline);if(memcmp(source_timeline,j->expected_video_timeline,32))r=AVERROR_INVALIDDATA;else j->timeline_ready=1;}
done:
    av_packet_free(&p);close_track(&v);close_track(&a);
    if(out){if(out->pb){int close_result=avio_closep(&out->pb);if(r>=0)r=close_result;}avformat_free_context(out);}
    if(r<0&&!interrupted(j))fail(j,r,"Export");
    if((r<0||interrupted(j))&&output_created)unlink(j->output);
    return interrupted(j)?ME_EXPORT_CANCELLED:r<0?ME_EXPORT_FAILED:ME_EXPORT_OK;
}
typedef struct { uint64_t packets, bytes; } payload_facts;
static void validation_note(me_export_job *j,int audio,const track *source,const track *output,const char *stage,const char *format,...) av_printf_format(6,7);
static void validation_note(me_export_job *j,int audio,const track *source,const track *output,const char *stage,const char *format,...) {
    if(j->validation_detail[0])return;
    int length=snprintf(j->validation_detail,sizeof(j->validation_detail),"%s.%s.%s tracks=%d/%d ",j->options.mode==ME_EXPORT_REMUX?"remux":"transcode",audio?"audio":"video",stage,source?source->index:-1,output?output->index:-1);
    if(length<0||(size_t)length>=sizeof(j->validation_detail))return;
    va_list args;va_start(args,format);
    vsnprintf(j->validation_detail+length,sizeof(j->validation_detail)-(size_t)length,format,args);
    va_end(args);
}
static int payload_digest(me_export_job *j,track *t,uint8_t digest[32],int64_t *first,int64_t *last,payload_facts *facts){
    memset(facts,0,sizeof(*facts));
    struct AVSHA *sha=av_sha_alloc();AVPacket *p=av_packet_alloc();if(!sha||!p){av_free(sha);av_packet_free(&p);return AVERROR(ENOMEM);}
    av_sha_init(sha,256);*first=AV_NOPTS_VALUE;*last=AV_NOPTS_VALUE;int r;
    while(!interrupted(j)&&(r=av_read_frame(t->input,p))>=0){
        if(p->stream_index==t->index){facts->packets++;facts->bytes+=(uint64_t)p->size;av_sha_update(sha,p->data,p->size);
            int64_t timing[3]={p->pts==AV_NOPTS_VALUE?AV_NOPTS_VALUE:av_rescale_q(p->pts,t->source->time_base,AV_TIME_BASE_Q),p->dts==AV_NOPTS_VALUE?AV_NOPTS_VALUE:av_rescale_q(p->dts,t->source->time_base,AV_TIME_BASE_Q),av_rescale_q(p->duration,t->source->time_base,AV_TIME_BASE_Q)};
            av_sha_update(sha,(const uint8_t *)timing,sizeof(timing));
            int64_t position=p->pts==AV_NOPTS_VALUE?p->dts:p->pts;
            if(position!=AV_NOPTS_VALUE){position=av_rescale_q(position,t->source->time_base,AV_TIME_BASE_Q);if(*first==AV_NOPTS_VALUE||position<*first)*first=position;int64_t end=position+av_rescale_q(p->duration,t->source->time_base,AV_TIME_BASE_Q);if(*last==AV_NOPTS_VALUE||end>*last)*last=end;}
        }av_packet_unref(p);
    }
    av_sha_final(sha,digest);av_free(sha);av_packet_free(&p);
    return interrupted(j)?AVERROR_EXIT:r==AVERROR_EOF?0:r;
}
static int same_side(track *a,track *b,enum AVPacketSideDataType type){
    const AVPacketSideData *x=side(a->source,type),*y=side(b->source,type);
    return (!x&&!y)||(x&&y&&x->size==y->size&&!memcmp(x->data,y->data,x->size));
}
static size_t first_different_byte(const uint8_t *a,const uint8_t *b,size_t size){
    size_t n=0;while(n<size&&a[n]==b[n])n++;return n;
}
static int same_remux_parameters(me_export_job *j,int audio,track *source,track *output){
    AVCodecParameters *a=source->source->codecpar,*b=output->source->codecpar;
#define COMPARE_REMUX_FIELD(field) do { \
    if(a->field!=b->field){ \
        validation_note(j,audio,source,output,"parameters","field=" #field " source=%d output=%d info(format/profile/rate/channels)=%d/%d/%d/%d:%d/%d/%d/%d", \
            (int)a->field,(int)b->field,a->format,a->profile,a->sample_rate,a->ch_layout.nb_channels,b->format,b->profile,b->sample_rate,b->ch_layout.nb_channels); \
        return 0; \
    } \
} while(0)
    COMPARE_REMUX_FIELD(codec_id);
    COMPARE_REMUX_FIELD(extradata_size);
    if(a->extradata_size&&memcmp(a->extradata,b->extradata,a->extradata_size)){
        size_t n=first_different_byte(a->extradata,b->extradata,(size_t)a->extradata_size);
        validation_note(j,audio,source,output,"configuration","byte=%zu source=%u output=%u size=%d codec=%d/%d tag=%08x/%08x",n,(unsigned)a->extradata[n],(unsigned)b->extradata[n],a->extradata_size,a->codec_id,b->codec_id,a->codec_tag,b->codec_tag);
        return 0;
    }
    COMPARE_REMUX_FIELD(width);COMPARE_REMUX_FIELD(height);
    COMPARE_REMUX_FIELD(color_primaries);COMPARE_REMUX_FIELD(color_trc);
    COMPARE_REMUX_FIELD(color_space);COMPARE_REMUX_FIELD(color_range);
#undef COMPARE_REMUX_FIELD
    return 1;
}
static void side_mismatch_note(me_export_job *j,int audio,track *source,track *output,enum AVPacketSideDataType type){
    const AVPacketSideData *a=side(source->source,type),*b=side(output->source,type);
    if(!a||!b||a->size!=b->size){
        validation_note(j,audio,source,output,"metadata","type=%d present=%d/%d size=%zu/%zu",type,a!=NULL,b!=NULL,a?a->size:0,b?b->size:0);
    }else{
        size_t n=first_different_byte(a->data,b->data,a->size);
        if(n<a->size)validation_note(j,audio,source,output,"metadata","type=%d byte=%zu source=%u output=%u size=%zu",type,n,(unsigned)a->data[n],(unsigned)b->data[n],a->size);
    }
}
static int read_selected_packet(me_export_job *j,track *t,AVPacket *p){
    int r=AVERROR_EXIT;
    while(!interrupted(j)&&(r=av_read_frame(t->input,p))>=0){
        if(p->stream_index==t->index)return 0;
        av_packet_unref(p);
    }
    return interrupted(j)?AVERROR_EXIT:r;
}
static int64_t packet_time_microseconds(int64_t value,AVRational timebase,int preserve_missing){
    return preserve_missing&&value==AV_NOPTS_VALUE?AV_NOPTS_VALUE:av_rescale_q(value,timebase,AV_TIME_BASE_Q);
}
static void explain_payload_mismatch(me_export_job *j,int audio,const track *original_source,const track *original_output,const payload_facts *source_facts,const payload_facts *output_facts){
    track source={.index=-1},output={.index=-1};AVPacket *a=av_packet_alloc(),*b=av_packet_alloc();
    enum AVMediaType type=audio?AVMEDIA_TYPE_AUDIO:AVMEDIA_TYPE_VIDEO;
    int r=0;
    if(!a||!b){validation_note(j,audio,original_source,original_output,"mixed-sha","diagnostic allocation failed code=%d",AVERROR(ENOMEM));goto done;}
    r=find_track(j,&source,audio&&j->audio?j->audio:j->video,type);
    if(r<0){validation_note(j,audio,original_source,original_output,"mixed-sha","diagnostic source.%s code=%d",source.input_stage,r);goto done;}
    r=find_track(j,&output,j->output,type);
    if(r<0){validation_note(j,audio,original_source,original_output,"mixed-sha","diagnostic output.%s code=%d",output.input_stage,r);goto done;}
    uint64_t limit=source_facts->packets>output_facts->packets?source_facts->packets:output_facts->packets;
    for(uint64_t n=0;!interrupted(j);n++){
        int source_result=read_selected_packet(j,&source,a),output_result=read_selected_packet(j,&output,b);
        if(interrupted(j))break;
        if((source_result<0&&source_result!=AVERROR_EOF)||(output_result<0&&output_result!=AVERROR_EOF)){
            validation_note(j,audio,&source,&output,"mixed-sha","diagnostic read packet=%" PRIu64 " source-code=%d output-code=%d",n,source_result,output_result);break;
        }
        if(source_result==AVERROR_EOF||output_result==AVERROR_EOF){
            validation_note(j,audio,&source,&output,"mixed-sha","packet=%" PRIu64 " eof=%d/%d census(packets/bytes)=%" PRIu64 "/%" PRIu64 ":%" PRIu64 "/%" PRIu64,n,source_result==AVERROR_EOF,output_result==AVERROR_EOF,source_facts->packets,source_facts->bytes,output_facts->packets,output_facts->bytes);break;
        }
        if(a->size!=b->size){validation_note(j,audio,&source,&output,"payload","packet=%" PRIu64 " size=%d/%d census-packets=%" PRIu64 "/%" PRIu64,n,a->size,b->size,source_facts->packets,output_facts->packets);break;}
        if(a->size&&memcmp(a->data,b->data,(size_t)a->size)){
            size_t byte=first_different_byte(a->data,b->data,(size_t)a->size);
            validation_note(j,audio,&source,&output,"payload","packet=%" PRIu64 " byte=%zu source=%u output=%u size=%d",n,byte,(unsigned)a->data[byte],(unsigned)b->data[byte],a->size);break;
        }
        int64_t source_time[3]={a->pts,a->dts,a->duration},output_time[3]={b->pts,b->dts,b->duration};
        const char *fields[]={"pts","dts","duration"};
        for(int field=0;field<3;field++){
            int64_t source_us=packet_time_microseconds(source_time[field],source.source->time_base,field<2),output_us=packet_time_microseconds(output_time[field],output.source->time_base,field<2);
            if(source_us!=output_us){
                validation_note(j,audio,&source,&output,"packet-time","packet=%" PRIu64 " field=%s ticks=%" PRId64 "/%" PRId64 " tb=%d/%d:%d/%d us=%" PRId64 "/%" PRId64 " flags=%x/%x",n,fields[field],source_time[field],output_time[field],source.source->time_base.num,source.source->time_base.den,output.source->time_base.num,output.source->time_base.den,source_us,output_us,(unsigned)a->flags,(unsigned)b->flags);
                break;
            }
        }
        if(j->validation_detail[0])break;
        av_packet_unref(a);av_packet_unref(b);
        if(n>=limit){validation_note(j,audio,&source,&output,"mixed-sha","diagnostic census changed limit=%" PRIu64,limit);break;}
    }
done:
    av_packet_free(&a);av_packet_free(&b);close_track(&source);close_track(&output);
}
static int decoded_timeline(me_export_job *j,track *t,uint8_t digest[32]){
    const AVCodec *codec=avcodec_find_decoder(t->source->codecpar->codec_id);
    if(!codec)return AVERROR_DECODER_NOT_FOUND;
    AVCodecContext *decoder=avcodec_alloc_context3(codec);AVPacket *packet=av_packet_alloc();AVFrame *frame=av_frame_alloc();struct AVSHA *sha=av_sha_alloc();int r=0;
    if(!decoder||!packet||!frame||!sha){r=AVERROR(ENOMEM);goto done;}
    if((r=avcodec_parameters_to_context(decoder,t->source->codecpar))<0)goto done;
    decoder->pkt_timebase=t->source->time_base;if((r=avcodec_open2(decoder,codec,NULL))<0)goto done;av_sha_init(sha,256);
    int ended=0;
    while(!interrupted(j)){
        if(!ended){r=av_read_frame(t->input,packet);if(r==AVERROR_EOF){ended=1;av_packet_unref(packet);}else if(r<0)break;else if(packet->stream_index!=t->index){av_packet_unref(packet);continue;}}
        r=avcodec_send_packet(decoder,ended?NULL:packet);av_packet_unref(packet);if(r<0)break;
        while((r=avcodec_receive_frame(decoder,frame))>=0){
            if(frame->pts==AV_NOPTS_VALUE||frame->duration<=0){r=AVERROR_INVALIDDATA;break;}
            int64_t timing[2]={av_rescale_q(frame->pts,t->source->time_base,AV_TIME_BASE_Q),av_rescale_q(frame->duration,t->source->time_base,AV_TIME_BASE_Q)};av_sha_update(sha,(const uint8_t *)timing,sizeof(timing));av_frame_unref(frame);
        }
        if(r==AVERROR_EOF){r=0;break;}if(r!=AVERROR(EAGAIN))break;if(ended){r=AVERROR_INVALIDDATA;break;}
    }
    if(r>=0)av_sha_final(sha,digest);
done:avcodec_free_context(&decoder);av_packet_free(&packet);av_frame_free(&frame);av_free(sha);return interrupted(j)?AVERROR_EXIT:r;
}
me_export_result me_export_job_validate_output(me_export_job *j){
    if(!j)return ME_EXPORT_FAILED;track source={.index=-1},output={.index=-1};int r=0;
    j->validation_detail[0]=0;
    for(int audio=0;audio<=!!j->options.include_audio;audio++){
        output.index=-1;
        enum AVMediaType type=audio?AVMEDIA_TYPE_AUDIO:AVMEDIA_TYPE_VIDEO;
        r=find_track(j,&source,audio&&j->audio?j->audio:j->video,type);
        if(audio&&!j->audio&&r==AVERROR_STREAM_NOT_FOUND){r=0;break;}
        if(r<0){validation_note(j,audio,&source,&output,"source-input","stage=%s code=%d",source.input_stage,r);break;}
        if((r=find_track(j,&output,j->output,type))<0){validation_note(j,audio,&source,&output,"output-input","stage=%s code=%d",output.input_stage,r);break;}
        AVCodecParameters *a=source.source->codecpar,*b=output.source->codecpar;
        if(j->options.mode==ME_EXPORT_REMUX){
            if(!same_remux_parameters(j,audio,&source,&output)){r=AVERROR_INVALIDDATA;break;}
            enum AVPacketSideDataType metadata[]={AV_PKT_DATA_DOVI_CONF,AV_PKT_DATA_MASTERING_DISPLAY_METADATA,AV_PKT_DATA_CONTENT_LIGHT_LEVEL,AV_PKT_DATA_DISPLAYMATRIX};
            for(unsigned n=0;n<sizeof(metadata)/sizeof(metadata[0]);n++)if(!same_side(&source,&output,metadata[n])){side_mismatch_note(j,audio,&source,&output,metadata[n]);r=AVERROR_INVALIDDATA;break;}if(r<0)break;
            uint8_t one[32],two[32];int64_t first1,last1,first2,last2;
            payload_facts source_facts,output_facts;
            if((r=payload_digest(j,&source,one,&first1,&last1,&source_facts))<0){validation_note(j,audio,&source,&output,"source-read","packets=%" PRIu64 " bytes=%" PRIu64 " code=%d",source_facts.packets,source_facts.bytes,r);break;}
            if((r=payload_digest(j,&output,two,&first2,&last2,&output_facts))<0){validation_note(j,audio,&source,&output,"output-read","packets=%" PRIu64 " bytes=%" PRIu64 " code=%d",output_facts.packets,output_facts.bytes,r);break;}
            if(memcmp(one,two,32)){
                explain_payload_mismatch(j,audio,&source,&output,&source_facts,&output_facts);
                validation_note(j,audio,&source,&output,"mixed-sha","census(packets/bytes)=%" PRIu64 "/%" PRIu64 ":%" PRIu64 "/%" PRIu64,source_facts.packets,source_facts.bytes,output_facts.packets,output_facts.bytes);
                r=AVERROR_INVALIDDATA;break;
            }
            if(first1!=first2){validation_note(j,audio,&source,&output,"timeline","field=first-us source=%" PRId64 " output=%" PRId64,first1,first2);r=AVERROR_INVALIDDATA;break;}
            if(llabs(last1-last2)>2000){validation_note(j,audio,&source,&output,"timeline","field=end-us source=%" PRId64 " output=%" PRId64 " tolerance=2000",last1,last2);r=AVERROR_INVALIDDATA;break;}
        }else if(!audio){
            enum AVCodecID expected=j->options.mode==ME_EXPORT_H264?AV_CODEC_ID_H264:AV_CODEC_ID_HEVC;
            int hdr=j->options.color==ME_EXPORT_COLOR_PQ||j->options.color==ME_EXPORT_COLOR_HLG;
            enum AVColorTransferCharacteristic trc=hdr?(j->options.color==ME_EXPORT_COLOR_HLG?AVCOL_TRC_ARIB_STD_B67:AVCOL_TRC_SMPTE2084):AVCOL_TRC_BT709;
            const AVPixFmtDescriptor *pixel=av_pix_fmt_desc_get(b->format);
            if(b->codec_id!=expected||b->color_trc!=trc||b->color_primaries!=(hdr?AVCOL_PRI_BT2020:AVCOL_PRI_BT709)||side(output.source,AV_PKT_DATA_DOVI_CONF)||(hdr&&(!pixel||pixel->comp[0].depth<10))){validation_note(j,audio,&source,&output,"parameters","expected/output codec=%d/%d trc=%d/%d primaries=%d/%d dovi=%d hdr=%d depth=%d",expected,b->codec_id,trc,b->color_trc,hdr?AVCOL_PRI_BT2020:AVCOL_PRI_BT709,b->color_primaries,side(output.source,AV_PKT_DATA_DOVI_CONF)!=NULL,hdr,pixel?pixel->comp[0].depth:-1);r=AVERROR_INVALIDDATA;break;}
            int expected_width,expected_height;fitted_size(a,&j->options,&expected_width,&expected_height);
            AVRational expected_sar={1,1};
            if(b->width!=expected_width||b->height!=expected_height||av_cmp_q(expected_sar,output.source->sample_aspect_ratio)||!same_side(&source,&output,AV_PKT_DATA_DISPLAYMATRIX)){
                if(b->width==expected_width&&b->height==expected_height&&!av_cmp_q(expected_sar,output.source->sample_aspect_ratio))side_mismatch_note(j,audio,&source,&output,AV_PKT_DATA_DISPLAYMATRIX);
                else validation_note(j,audio,&source,&output,"geometry","expected/output size=%dx%d/%dx%d sar=%d/%d:%d/%d",expected_width,expected_height,b->width,b->height,expected_sar.num,expected_sar.den,output.source->sample_aspect_ratio.num,output.source->sample_aspect_ratio.den);
                r=AVERROR_INVALIDDATA;break;
            }
            if(hdr&&(!same_side(&source,&output,AV_PKT_DATA_MASTERING_DISPLAY_METADATA)||!same_side(&source,&output,AV_PKT_DATA_CONTENT_LIGHT_LEVEL))){side_mismatch_note(j,audio,&source,&output,!same_side(&source,&output,AV_PKT_DATA_MASTERING_DISPLAY_METADATA)?AV_PKT_DATA_MASTERING_DISPLAY_METADATA:AV_PKT_DATA_CONTENT_LIGHT_LEVEL);r=AVERROR_INVALIDDATA;break;}
            if((j->options.maximum_long_edge>0&&fmax(b->width,b->height)>j->options.maximum_long_edge)||(j->options.maximum_short_edge>0&&fmin(b->width,b->height)>j->options.maximum_short_edge)){validation_note(j,audio,&source,&output,"geometry","output=%dx%d max-long=%d max-short=%d",b->width,b->height,j->options.maximum_long_edge,j->options.maximum_short_edge);r=AVERROR_INVALIDDATA;break;}
            uint8_t timeline[32];
            if(!j->timeline_ready||(r=decoded_timeline(j,&output,timeline))<0||memcmp(timeline,j->expected_video_timeline,32)){validation_note(j,audio,&source,&output,"decoded-timeline","ready=%d code=%d",j->timeline_ready,r);r=r<0?r:AVERROR_INVALIDDATA;break;}
            if(source.input->duration>0&&output.input->duration>0&&llabs(source.input->duration-output.input->duration)>250000){validation_note(j,audio,&source,&output,"timeline","field=container-duration-us source=%" PRId64 " output=%" PRId64 " tolerance=250000",source.input->duration,output.input->duration);r=AVERROR_INVALIDDATA;break;}
        }else{
            if(b->codec_id!=AV_CODEC_ID_AAC||a->ch_layout.nb_channels!=b->ch_layout.nb_channels||a->sample_rate!=b->sample_rate){validation_note(j,audio,&source,&output,"parameters","expected-codec=%d output-codec=%d source/output channels=%d/%d rate=%d/%d",AV_CODEC_ID_AAC,b->codec_id,a->ch_layout.nb_channels,b->ch_layout.nb_channels,a->sample_rate,b->sample_rate);r=AVERROR_INVALIDDATA;break;}
            uint8_t discarded[32];int64_t first,last;
            payload_facts output_facts;
            if((r=payload_digest(j,&output,discarded,&first,&last,&output_facts))<0){validation_note(j,audio,&source,&output,"output-read","packets=%" PRIu64 " bytes=%" PRIu64 " code=%d",output_facts.packets,output_facts.bytes,r);break;}
            int64_t tolerance=av_rescale_q(2048,(AVRational){1,b->sample_rate},AV_TIME_BASE_Q);
            if(!j->audio_timing_ready||!j->source_audio_timing_ready||llabs(j->audio_first-j->source_audio_first)>tolerance||llabs(j->audio_end-j->source_audio_end)>tolerance||llabs(first-j->audio_first)>tolerance||llabs(last-j->audio_end)>tolerance){validation_note(j,audio,&source,&output,"timeline","ready=%d/%d source-first/end=%" PRId64 "/%" PRId64 " encoded-first/end=%" PRId64 "/%" PRId64 " output-first/end=%" PRId64 "/%" PRId64 " tolerance-us=%" PRId64,j->source_audio_timing_ready,j->audio_timing_ready,j->source_audio_first,j->source_audio_end,j->audio_first,j->audio_end,first,last,tolerance);r=AVERROR_INVALIDDATA;break;}
        }
        close_track(&source);close_track(&output);
    }
    close_track(&source);close_track(&output);
    if(r<0&&!interrupted(j)){
        char where[448];snprintf(where,sizeof(where),"Validate finalized MP4 [%s]",j->validation_detail[0]?j->validation_detail:"unspecified");
        fail(j,r,where);
    }
    return interrupted(j)?ME_EXPORT_CANCELLED:r<0?ME_EXPORT_FAILED:ME_EXPORT_OK;
}

me_export_result me_export_job_check_capability(me_export_job *j){
    if(!j)return ME_EXPORT_FAILED;
    track video={0},audio={0};AVFormatContext *out=NULL;int r=find_track(j,&video,j->video,AVMEDIA_TYPE_VIDEO);
    if(r>=0)r=avformat_alloc_output_context2(&out,NULL,"mp4",NULL);
    if(r>=0){
        if(j->options.mode==ME_EXPORT_REMUX){
            r=copy_track(&video,out);
            if(r>=0&&avformat_query_codec(out->oformat,video.source->codecpar->codec_id,FF_COMPLIANCE_NORMAL)<=0)r=AVERROR(EINVAL);
        }else r=setup_transcode(j,&video,out,1);
    }
    if(r>=0&&j->options.include_audio){
        r=find_track(j,&audio,j->audio?j->audio:j->video,AVMEDIA_TYPE_AUDIO);
        if(r==AVERROR_STREAM_NOT_FOUND&&!j->audio)r=0;
        else if(r>=0){r=j->options.mode==ME_EXPORT_REMUX?copy_track(&audio,out):setup_transcode(j,&audio,out,0);if(r>=0&&j->options.mode==ME_EXPORT_REMUX&&avformat_query_codec(out->oformat,audio.source->codecpar->codec_id,FF_COMPLIANCE_NORMAL)<=0)r=AVERROR(EINVAL);}
    }
    close_track(&video);close_track(&audio);avformat_free_context(out);
    if(r<0&&!interrupted(j))fail(j,r,"Admit exact export recipe");
    return interrupted(j)?ME_EXPORT_CANCELLED:r<0?ME_EXPORT_FAILED:ME_EXPORT_OK;
}
