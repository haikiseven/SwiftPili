#ifndef SWIFTPILI_MEDIA_EXPORT_H
#define SWIFTPILI_MEDIA_EXPORT_H
#include <stdint.h>
#include <stddef.h>
#ifdef __cplusplus
extern "C" {
#endif
#define ME_EXPORT_ABI_VERSION 1

typedef struct me_export_job me_export_job;
typedef enum { ME_EXPORT_REMUX = 0, ME_EXPORT_H264 = 1, ME_EXPORT_HEVC = 2 } me_export_mode;
typedef enum { ME_EXPORT_COLOR_SOURCE = 0, ME_EXPORT_COLOR_SDR = 1, ME_EXPORT_COLOR_PQ = 2, ME_EXPORT_COLOR_HLG = 3 } me_export_color;
typedef enum { ME_EXPORT_OK = 0, ME_EXPORT_CANCELLED = 1, ME_EXPORT_FAILED = 2 } me_export_result;
typedef struct {
    const char *video_path;
    const char *audio_path; /* nullable, separate audio input */
    const char *output_path;
    me_export_mode mode;
    me_export_color color;
    int include_audio;
    int maximum_long_edge; /* 0 preserves source size */
    int maximum_short_edge;
    int resolution_tier; /* 0 source, 720, 1080, 2160 */
} me_export_options;
typedef struct {
    int width, height;
    int video_codec_id, audio_codec_id;
    int bit_depth, audio_channels, audio_sample_rate;
    int color_primaries, color_transfer, color_matrix, color_range;
    int dolby_vision_profile, dolby_vision_level;
    int dolby_has_base_layer, dolby_has_enhancement_layer, dolby_has_rpu;
    int64_t video_bitrate, duration_microseconds;
    double average_frame_rate;
    int has_audio, has_mastering_metadata, has_content_light_metadata;
} me_export_inventory;
typedef struct {
    double processed_seconds, duration_seconds;
    int64_t bytes_written;
} me_export_progress;
typedef void (*me_export_progress_callback)(void *context, const me_export_progress *progress);
/* Copies all strings/options. A job has one executing thread; cancel is safe
 * from another thread. Caller retains callback context until execute returns. */
me_export_job *me_export_job_create(const me_export_options *options);
void me_export_job_cancel(me_export_job *job);
/* probe and execute return only after all their native readers are closed.
 * execute success additionally means encoder/filter drained and mux trailer
 * written/closed. Caller owns final validation/publication/save, never infer
 * completion from progress. Output is removed on failed/cancelled execute. */
me_export_result me_export_job_probe(me_export_job *job, me_export_inventory *inventory);
me_export_result me_export_job_execute(me_export_job *job, me_export_progress_callback progress, void *context);
me_export_result me_export_job_check_capability(me_export_job *job);
me_export_result me_export_job_validate_output(me_export_job *job);
const char *me_export_job_error(const me_export_job *job);
void me_export_job_destroy(me_export_job *job); /* only after actual return */
uint32_t me_export_abi_version(void);
#ifdef __cplusplus
}
#endif
#endif
