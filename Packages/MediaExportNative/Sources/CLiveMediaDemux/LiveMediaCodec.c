#include "LiveMediaCodec.h"

#include <libavcodec/adts_parser.h>
#include <libavutil/mem.h>
#include <string.h>

/* These two helpers are private to the pinned FFmpeg build. The generated
 * namespace maps their definitions in both slices, like the public functions. */
int ff_nal_parse_units_buf(const uint8_t *data, uint8_t **output, int *size);
int ff_isom_write_avcc(AVIOContext *output, const uint8_t *data, int size);

enum { MAX_CONFIG_BYTES = 64 * 1024 };

static int set_config(MLDCodec *codec, const uint8_t *data, size_t size)
{
    if (!data || !size || size > MAX_CONFIG_BYTES)
        return MLD_INVALID;
    if (codec->config) {
        if (size == (size_t)codec->config_size && !memcmp(codec->config, data, size))
            return MLD_OK;
        return MLD_UNSUPPORTED;
    }
    codec->config = av_memdup(data, size);
    if (!codec->config)
        return MLD_INVALID;
    codec->config_size = (int)size;
    return MLD_OK;
}

static int register_parameter_set(MLDCodec *codec, const uint8_t *data, int size)
{
    const int type = data[0] & 31;
    if (type != 7 && type != 8)
        return MLD_OK;
    if (size < (type == 7 ? 4 : 2) || size > UINT16_MAX)
        return MLD_INVALID;

    for (int i = 0; i < codec->set_count; ++i) {
        const MLDParameterSet *set = &codec->sets[i];
        if (size == set->size && !memcmp(data, set->data, size))
            return MLD_OK;
    }
    if (codec->config)
        return MLD_UNSUPPORTED;
    if (codec->set_count == sizeof(codec->sets) / sizeof(codec->sets[0]) ||
        size > MAX_CONFIG_BYTES - codec->set_bytes - 4)
        return MLD_INVALID;

    uint8_t *copy = av_memdup(data, size);
    if (!copy)
        return MLD_INVALID;
    codec->sets[codec->set_count++] = (MLDParameterSet){copy, size};
    codec->set_bytes += size + 4;
    codec->has_sps |= type == 7;
    codec->has_pps |= type == 8;
    return MLD_OK;
}

static int flv_avcc(MLDCodec *codec, const uint8_t *data, size_t size)
{
    if (codec->config)
        return set_config(codec, data, size);
    if (!data || size < 7 || size > MAX_CONFIG_BYTES || data[0] != 1)
        return MLD_INVALID;

    const int length = (data[4] & 3) + 1;
    if (length == 3)
        return MLD_UNSUPPORTED;
    codec->nal_length = length;
    size_t offset = 6;
    int count = data[5] & 31;
    for (int type = 7; type <= 8; ++type) {
        if (type == 8) {
            if (offset == size)
                return MLD_INVALID;
            count = data[offset++];
        }
        if (!count)
            return MLD_INVALID;
        while (count-- > 0) {
            if (size - offset < 2)
                return MLD_INVALID;
            int n = data[offset] * 256 + data[offset + 1];
            offset += 2;
            if (n == 0 || (size_t)n > size - offset || (data[offset] & 0x9f) != type)
                return MLD_INVALID;
            int result = register_parameter_set(codec, data + offset, n);
            if (result != MLD_OK)
                return result;
            offset += n;
        }
    }
    return set_config(codec, data, size);
}

static int ts_avcc(MLDCodec *codec)
{
    if (codec->config || !codec->has_sps || !codec->has_pps)
        return MLD_OK;
    AVIOContext *annex_b = NULL;
    AVIOContext *avcc = NULL;
    uint8_t *annex_b_data = NULL;
    uint8_t *avcc_data = NULL;
    int result = MLD_INVALID;

    if (avio_open_dyn_buf(&annex_b) < 0 || avio_open_dyn_buf(&avcc) < 0)
        goto done;
    for (int i = 0; i < codec->set_count; ++i) {
        const MLDParameterSet *set = &codec->sets[i];
        avio_wb32(annex_b, 1);
        avio_write(annex_b, set->data, set->size);
    }
    int annex_b_size = avio_get_dyn_buf(annex_b, &annex_b_data);
    if (annex_b_size != codec->set_bytes ||
        ff_isom_write_avcc(avcc, annex_b_data, annex_b_size) < 0)
        goto done;
    int avcc_size = avio_get_dyn_buf(avcc, &avcc_data);
    if (avcc_size > 0)
        result = set_config(codec, avcc_data, avcc_size);

done:
    if (annex_b) {
        avio_close_dyn_buf(annex_b, &annex_b_data);
        av_free(annex_b_data);
    }
    if (avcc) {
        avio_close_dyn_buf(avcc, &avcc_data);
        av_free(avcc_data);
    }
    return result;
}

static int ts_video_length_prefix(AVPacket *packet)
{
    int first_nonzero = 0;
    while (first_nonzero < packet->size && packet->data[first_nonzero] == 0)
        ++first_nonzero;
    if (first_nonzero < 2 || first_nonzero >= packet->size || packet->data[first_nonzero] != 1)
        return MLD_INVALID;

    int size = packet->size;
    uint8_t *data = NULL;
    if (ff_nal_parse_units_buf(packet->data, &data, &size) < 0 ||
        size <= 0 || size > MLD_MAX_PACKET_BYTES) {
        av_free(data);
        return MLD_INVALID;
    }
    // The FFmpeg dynamic buffer is AV_INPUT_BUFFER_PADDING_SIZE-padded.
    AVPacket converted = {0};
    if (av_packet_from_data(&converted, data, size) < 0) {
        av_free(data);
        return MLD_INVALID;
    }
    // Timing is already read by the caller. Transfer only the payload buffer.
    av_buffer_unref(&packet->buf);
    packet->buf = converted.buf;
    packet->data = converted.data;
    packet->size = converted.size;
    return MLD_OK;
}

int mld_video_packet(MLDCodec *codec, int format, const AVCodecParameters *par,
                     AVPacket *packet, int *has_access_unit, int *is_key)
{
    if (format == MLD_TS) {
        codec->nal_length = 4;
        int result = ts_video_length_prefix(packet);
        if (result != MLD_OK)
            return result;
    } else {
        size_t size = 0;
        const uint8_t *data = av_packet_get_side_data(packet, AV_PKT_DATA_NEW_EXTRADATA, &size);
        if (!codec->config) {
            if (par->extradata_size <= 0)
                return MLD_INVALID;
            int result = flv_avcc(codec, par->extradata, par->extradata_size);
            if (result != MLD_OK)
                return result;
        }
        if (data) {
            int result = flv_avcc(codec, data, size);
            if (result != MLD_OK)
                return result;
        }
    }

    for (int cursor = 0; cursor < packet->size;) {
        if (packet->size - cursor < codec->nal_length)
            return MLD_INVALID;
        uint32_t size = 0;
        for (int i = 0; i < codec->nal_length; ++i)
            size = (size << 8) | packet->data[cursor++];
        const uint8_t *nal = packet->data + cursor;
        if (size == 0 || size > (uint32_t)(packet->size - cursor) || (*nal & 0x80))
            return MLD_INVALID;
        const int type = *nal & 31;
        if (type == 0 || type >= 24)
            return MLD_INVALID;
        *has_access_unit |= type >= 1 && type <= 5;
        *is_key |= type == 5;
        int result = register_parameter_set(codec, nal, (int)size);
        if (result != MLD_OK)
            return result;
        cursor += (int)size;
    }
    return format == MLD_TS ? ts_avcc(codec) : MLD_OK;
}

static unsigned asc_bits(const uint8_t *data, size_t size, size_t *offset, unsigned count)
{
    if (*offset > size * 8 || count > size * 8 - *offset)
        return UINT32_MAX;
    unsigned value = 0;
    for (unsigned i = 0; i < count; ++i, ++*offset)
        value = (value << 1) | ((data[*offset / 8] >> (7 - *offset % 8)) & 1);
    return value;
}

static unsigned asc_rate(const uint8_t *data, size_t size, size_t *offset)
{
    static const unsigned rates[] = {96000, 88200, 64000, 48000, 44100, 32000,
                                     24000, 22050, 16000, 12000, 11025, 8000, 7350};
    unsigned index = asc_bits(data, size, offset, 4);
    if (index == 15) {
        unsigned rate = asc_bits(data, size, offset, 24);
        return rate == UINT32_MAX ? 0 : rate;
    }
    return index < sizeof(rates) / sizeof(rates[0]) ? rates[index] : 0;
}

static int audio_config(MLDCodec *codec, const uint8_t *data, size_t size)
{
    if (!data || size < 2 || size > MAX_CONFIG_BYTES)
        return MLD_INVALID;
    if (codec->config)
        return set_config(codec, data, size);

    size_t bit = 0;
    unsigned object = asc_bits(data, size, &bit, 5);
    unsigned rate = asc_rate(data, size, &bit);
    unsigned channels = asc_bits(data, size, &bit, 4);
    if (!rate || channels == UINT32_MAX)
        return MLD_INVALID;
    if (object == 5 || object == 29) {
        if (!asc_rate(data, size, &bit))
            return MLD_INVALID;
        object = asc_bits(data, size, &bit, 5);
    }
    // Match AudioToolboxAudioDecoder's admitted core profiles and layouts.
    if ((object != 1 && object != 2) || channels < 1 || channels > 7)
        return MLD_UNSUPPORTED;
    unsigned short_frame = asc_bits(data, size, &bit, 1);
    unsigned depends_on_core = asc_bits(data, size, &bit, 1);
    if (short_frame > 1 || depends_on_core > 1 ||
        (depends_on_core && asc_bits(data, size, &bit, 14) == UINT32_MAX))
        return MLD_INVALID;
    codec->audio_duration = (short_frame ? 960.0 : 1024.0) / rate;
    return set_config(codec, data, size);
}

static int ts_audio_packet(MLDCodec *codec, const AVCodecParameters *par, AVPacket *packet)
{
    if (packet->size < AV_AAC_ADTS_HEADER_SIZE)
        return MLD_INVALID;
    const uint8_t *data = packet->data;
    uint32_t samples = 0;
    uint8_t blocks = 0;
    const int frame_size = ((data[3] & 3) << 11) | (data[4] << 3) | (data[5] >> 5);
    const int header_size = (data[1] & 1) ? 7 : 9;
    if (av_adts_header_parse(data, &samples, &blocks) < 0 || frame_size != packet->size ||
        header_size >= packet->size)
        return MLD_INVALID;
    if (blocks != 1 || samples != 1024)
        return MLD_UNSUPPORTED;

    const int object = (data[2] >> 6) + 1;
    const int rate_index = (data[2] >> 2) & 15;
    const int channel_config = ((data[2] & 1) << 2) | (data[3] >> 6);
    const uint8_t asc[] = {(object << 3) | (rate_index >> 1),
                           ((rate_index & 1) << 7) | (channel_config << 3)};
    int result = audio_config(codec, asc, sizeof(asc));
    if (result != MLD_OK)
        return result;

    if (!codec->adts_to_asc) {
        const AVBitStreamFilter *filter = av_bsf_get_by_name("aac_adtstoasc");
        if (!filter)
            return MLD_UNSUPPORTED;
        if (av_bsf_alloc(filter, &codec->adts_to_asc) < 0 ||
            avcodec_parameters_copy(codec->adts_to_asc->par_in, par) < 0 ||
            av_bsf_init(codec->adts_to_asc) < 0)
            return MLD_INVALID;
    }
    if (av_bsf_send_packet(codec->adts_to_asc, packet) < 0 ||
        av_bsf_receive_packet(codec->adts_to_asc, packet) < 0 || packet->size <= 0)
        return MLD_INVALID;
    size_t size = 0;
    data = av_packet_get_side_data(packet, AV_PKT_DATA_NEW_EXTRADATA, &size);
    return data ? audio_config(codec, data, size) : MLD_OK;
}

int mld_audio_packet(MLDCodec *codec, int format, const AVCodecParameters *par,
                     AVPacket *packet)
{
    if (format == MLD_TS)
        return ts_audio_packet(codec, par, packet);

    if (!codec->config) {
        if (par->extradata_size <= 0)
            return MLD_INVALID;
        int result = audio_config(codec, par->extradata, par->extradata_size);
        if (result != MLD_OK)
            return result;
    }
    size_t size = 0;
    const uint8_t *data = av_packet_get_side_data(packet, AV_PKT_DATA_NEW_EXTRADATA, &size);
    return data ? audio_config(codec, data, size) : MLD_OK;
}

void mld_codec_clear(MLDCodec *codec)
{
    av_bsf_free(&codec->adts_to_asc);
    av_free(codec->config);
    for (int i = 0; i < codec->set_count; ++i)
        av_free(codec->sets[i].data);
}
