/*
 * sacd_dsd - DSD/DST to raw DSD (DFF) or DoP PCM.
 *
 * This helper is intentionally small and dependency-free for uncompressed
 * DSF/DFF.  DST decoding is optional and uses libavformat/libavcodec when
 * available at build time.  It never reads a whole file for metadata; it only
 * seeks over the DSD/DST payload it is not asked to output.
 *
 * License: GPL-2.0-or-later
 */

#define _POSIX_C_SOURCE 200809L
#define _FILE_OFFSET_BITS 64

#include <errno.h>
#include <inttypes.h>
#include <math.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>

#ifdef HAVE_LIBAV
#include <libavcodec/avcodec.h>
#include <libavformat/avformat.h>
#include <libavutil/opt.h>
#include <libavutil/samplefmt.h>
#endif

#define DSD_SILENCE 0x69

typedef struct {
    const char *input;
    const char *mode;       /* native | dop */
    double start;
    double end;
    int have_start;
    int have_end;
    int probe;
    int selftest;
} Options;

typedef struct {
    const char *container;  /* dsf | dff */
    int is_dst;
    uint32_t fs;            /* DSD bit rate, e.g. 2822400 */
    int channels;
    uint64_t audio_offset;
    uint64_t audio_size;    /* interleaved raw DSD bytes, or DST chunk size */
    uint64_t raw_bytes;     /* decoded DSD bytes, interleaved */
    uint64_t dst_frames;
    uint32_t dst_rate;
    double duration;
    int lsb_first;
    uint64_t file_size;
} DsdInfo;

static uint8_t reverse_table[256];
static int reverse_ready = 0;

static void init_reverse(void) {
    int i;
    if (reverse_ready) return;
    for (i = 0; i < 256; ++i) {
        uint8_t v = (uint8_t)i;
        v = (uint8_t)(((v & 0x55) << 1) | ((v >> 1) & 0x55));
        v = (uint8_t)(((v & 0x33) << 2) | ((v >> 2) & 0x33));
        v = (uint8_t)(((v & 0x0F) << 4) | ((v >> 4) & 0x0F));
        reverse_table[i] = v;
    }
    reverse_ready = 1;
}

static uint32_t rd_u32be(const uint8_t *p) {
    return ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16) |
           ((uint32_t)p[2] << 8) | p[3];
}

static uint64_t rd_u64be(const uint8_t *p) {
    return ((uint64_t)p[0] << 56) | ((uint64_t)p[1] << 48) |
           ((uint64_t)p[2] << 40) | ((uint64_t)p[3] << 32) |
           ((uint64_t)p[4] << 24) | ((uint64_t)p[5] << 16) |
           ((uint64_t)p[6] << 8) | p[7];
}

static uint32_t rd_u32le(const uint8_t *p) {
    return ((uint32_t)p[3] << 24) | ((uint32_t)p[2] << 16) |
           ((uint32_t)p[1] << 8) | p[0];
}

static uint64_t rd_u64le(const uint8_t *p) {
    return ((uint64_t)p[7] << 56) | ((uint64_t)p[6] << 48) |
           ((uint64_t)p[5] << 40) | ((uint64_t)p[4] << 32) |
           ((uint64_t)p[3] << 24) | ((uint64_t)p[2] << 16) |
           ((uint64_t)p[1] << 8) | p[0];
}

static int read_exact(FILE *f, void *buf, size_t n) {
    size_t got = 0;
    while (got < n) {
        size_t r = fread((uint8_t *)buf + got, 1, n - got, f);
        if (r == 0) return 0;
        got += r;
    }
    return 1;
}

static int seek_to(FILE *f, uint64_t off) {
    if (off > (uint64_t)INT64_MAX) return 0;
    return fseeko(f, (off_t)off, SEEK_SET) == 0;
}

static uint64_t file_size(FILE *f) {
    off_t cur = ftello(f);
    if (fseeko(f, 0, SEEK_END) != 0) return 0;
    off_t end = ftello(f);
    if (cur >= 0) fseeko(f, cur, SEEK_SET);
    return end > 0 ? (uint64_t)end : 0;
}

static int parse_dsf(FILE *f, DsdInfo *info) {
    uint8_t hdr[92];
    if (!seek_to(f, 0)) return 0;
    if (!read_exact(f, hdr, sizeof(hdr))) return 0;
    if (memcmp(hdr, "DSD ", 4) != 0) return 0;
    if (rd_u64le(hdr + 4) != 28) return 0;

    uint64_t total_size = rd_u64le(hdr + 12);
    uint64_t meta_off   = rd_u64le(hdr + 20);
    if (memcmp(hdr + 28, "fmt ", 4) != 0) return 0;
    if (rd_u64le(hdr + 32) != 52) return 0;

    uint32_t version = rd_u32le(hdr + 40);
    uint32_t format  = rd_u32le(hdr + 44);
    uint32_t chan_t  = rd_u32le(hdr + 48);
    uint32_t ch      = rd_u32le(hdr + 52);
    uint32_t fs      = rd_u32le(hdr + 56);
    uint32_t bits    = rd_u32le(hdr + 60);
    uint64_t samples = rd_u64le(hdr + 64);
    uint32_t block   = rd_u32le(hdr + 72);
    (void)chan_t;
    (void)block;

    if (version != 1 || format != 0 || ch == 0 || fs == 0 || bits != 1) return 0;
    if (memcmp(hdr + 80, "data", 4) != 0) return 0;
    uint64_t data_chunk = rd_u64le(hdr + 84);
    if (data_chunk < 12) return 0;

    info->container   = "dsf";
    info->is_dst      = 0;
    info->fs          = fs;
    info->channels    = (int)ch;
    info->audio_offset = 92;
    info->audio_size  = data_chunk - 12;
    info->raw_bytes   = info->audio_size;
    info->duration    = (double)samples / (double)fs;
    info->lsb_first   = 1;
    info->file_size   = file_size(f);
    if (meta_off > total_size) meta_off = 0;
    (void)meta_off;
    return 1;
}

static int parse_prop(FILE *f, uint64_t data_off, uint64_t size, DsdInfo *info) {
    uint8_t prop[4];
    if (!seek_to(f, data_off) || !read_exact(f, prop, 4)) return 0;
    if (memcmp(prop, "SND ", 4) != 0) return 0;

    uint64_t pos = data_off + 4;
    uint64_t end = data_off + size;
    while (pos + 12 <= end) {
        uint8_t h[12];
        if (!seek_to(f, pos) || !read_exact(f, h, 12)) return 0;
        uint64_t csize = rd_u64be(h + 4);
        uint64_t dpos  = pos + 12;
        if (dpos + csize > end + 1) return 0;

        if (memcmp(h, "FS  ", 4) == 0 && csize >= 4) {
            uint8_t v[4];
            if (!seek_to(f, dpos) || !read_exact(f, v, 4)) return 0;
            info->fs = rd_u32be(v);
        }
        else if (memcmp(h, "CHNL", 4) == 0 && csize >= 2) {
            uint8_t v[2];
            if (!seek_to(f, dpos) || !read_exact(f, v, 2)) return 0;
            info->channels = ((int)v[0] << 8) | v[1];
        }
        else if (memcmp(h, "CMPR", 4) == 0 && csize >= 4) {
            uint8_t v[4];
            if (!seek_to(f, dpos) || !read_exact(f, v, 4)) return 0;
            if (memcmp(v, "DST ", 4) == 0) info->is_dst = 1;
        }
        pos = dpos + csize + (csize & 1);
    }
    return 1;
}

static int parse_dst(FILE *f, uint64_t data_off, uint64_t size, DsdInfo *info) {
    uint64_t pos = data_off;
    uint64_t end = data_off + size;
    while (pos + 12 <= end) {
        uint8_t h[12];
        if (!seek_to(f, pos) || !read_exact(f, h, 12)) return 0;
        uint64_t csize = rd_u64be(h + 4);
        uint64_t dpos  = pos + 12;
        if (dpos + csize > end + 1) return 0;

        if (memcmp(h, "FRTE", 4) == 0 && csize >= 6) {
            uint8_t v[6];
            if (!seek_to(f, dpos) || !read_exact(f, v, 6)) return 0;
            info->dst_frames = rd_u32be(v);
            info->dst_rate   = ((uint32_t)v[4] << 8) | v[5];
            return info->dst_frames > 0;
        }
        pos = dpos + csize + (csize & 1);
    }
    return info->dst_frames > 0;
}

static int parse_dff(FILE *f, DsdInfo *info) {
    uint8_t hdr[16];
    if (!seek_to(f, 0) || !read_exact(f, hdr, 16)) return 0;
    if (memcmp(hdr, "FRM8", 4) != 0) return 0;
    uint64_t size = rd_u64be(hdr + 4);
    if (memcmp(hdr + 12, "DSD ", 4) && memcmp(hdr + 12, "DST ", 4)) return 0;
    if (memcmp(hdr + 12, "DST ", 4) == 0) info->is_dst = 1;

    uint64_t total_end = 12 + size;
    uint64_t fsize = file_size(f);
    if (total_end > fsize) total_end = fsize;

    uint64_t pos = 16;
    int have_audio = 0;
    while (pos + 12 <= total_end) {
        uint8_t h[12];
        if (!seek_to(f, pos) || !read_exact(f, h, 12)) break;
        uint64_t csize = rd_u64be(h + 4);
        uint64_t dpos  = pos + 12;
        if (dpos + csize > total_end + 1) break;

        if (memcmp(h, "PROP", 4) == 0) {
            parse_prop(f, dpos, csize, info);
        }
        else if (memcmp(h, "DSD ", 4) == 0) {
            info->audio_offset = dpos;
            info->audio_size   = csize;
            have_audio = 1;
        }
        else if (memcmp(h, "DST ", 4) == 0) {
            info->is_dst = 1;
            parse_dst(f, dpos, csize, info);
            have_audio = 1;
        }
        pos = dpos + csize + (csize & 1);
    }

    if (info->fs == 0 || info->channels <= 0 || !have_audio) return 0;
    info->container = "dff";
    info->lsb_first = 0;
    info->file_size = fsize;

    if (info->is_dst) {
        if (!info->dst_frames || !info->dst_rate) return 0;
        info->duration = (double)info->dst_frames / (double)info->dst_rate;
        info->raw_bytes = info->dst_frames * (info->fs / 600) * info->channels;
    }
    else {
        info->raw_bytes = info->audio_size;
        info->duration = (double)info->audio_size * 8.0 /
                         ((double)info->fs * (double)info->channels);
    }
    return 1;
}

static int parse_input(const char *path, DsdInfo *info) {
    FILE *f = fopen(path, "rb");
    if (!f) return 0;
    memset(info, 0, sizeof(*info));
    info->dst_rate = 75;

    uint8_t magic[4];
    if (!read_exact(f, magic, 4)) { fclose(f); return 0; }
    int ok;
    if (memcmp(magic, "DSD ", 4) == 0) {
        ok = parse_dsf(f, info);
    }
    else if (memcmp(magic, "FRM8", 4) == 0) {
        ok = parse_dff(f, info);
    }
    else {
        ok = 0;
    }
    fclose(f);
    return ok;
}

static uint64_t bytes_for_seconds(const DsdInfo *info, double start, double end) {
    double rate = (double)info->fs / 8.0; /* DSD bytes per channel per second */
    uint64_t s = start > 0 ? (uint64_t)llround(start * rate) : 0;
    uint64_t e = end > 0 ? (uint64_t)llround(end * rate) : (info->raw_bytes / info->channels);
    if (e < s) e = s;
    return (e - s) * info->channels;
}

static void write_u32be(FILE *f, uint32_t v) {
    uint8_t b[4] = { (uint8_t)(v >> 24), (uint8_t)(v >> 16), (uint8_t)(v >> 8), (uint8_t)v };
    fwrite(b, 1, 4, f);
}

static void write_u64be(FILE *f, uint64_t v) {
    uint8_t b[8];
    int i;
    for (i = 0; i < 8; ++i) b[i] = (uint8_t)(v >> (56 - 8 * i));
    fwrite(b, 1, 8, f);
}

static void write_chunk_header(FILE *f, const char *id, uint64_t size) {
    fwrite(id, 1, 4, f);
    write_u64be(f, size);
}

static void channel_ids(int channels, char ids[][5]) {
    int i;
    const char *std2[] = { "SLFT", "SRGT" };
    const char *std5[] = { "MLFT", "MRGT", "C   ", "LS  ", "RS  " };
    const char *std6[] = { "MLFT", "MRGT", "C   ", "LFE ", "LS  ", "RS  " };
    if (channels == 2) {
        for (i = 0; i < 2; ++i) memcpy(ids[i], std2[i], 4);
    }
    else if (channels == 5) {
        for (i = 0; i < 5; ++i) memcpy(ids[i], std5[i], 4);
    }
    else if (channels == 6) {
        for (i = 0; i < 6; ++i) memcpy(ids[i], std6[i], 4);
    }
    else {
        for (i = 0; i < channels; ++i) snprintf(ids[i], 5, "C%03d", i);
    }
    for (i = 0; i < channels; ++i) ids[i][4] = 0;
}

static int write_dff_header(FILE *out, const DsdInfo *info, uint64_t data_bytes) {
    char ids[64][5];
    uint32_t ch = (uint32_t)info->channels;
    if (ch < 1 || ch > 64) return 0;
    channel_ids((int)ch, ids);

    uint64_t chnl_data  = 2 + 4 * (uint64_t)ch;
    uint64_t chnl_total = 12 + chnl_data + (chnl_data & 1);
    uint64_t cmpr_data  = 4 + 1 + 14; /* "DSD " + count + "not compressed" */
    uint64_t cmpr_total = 12 + cmpr_data + (cmpr_data & 1);
    uint64_t lsco_total = 14;
    uint64_t prop_data  = 4 + 16 + chnl_total + cmpr_total + lsco_total;
    uint64_t prop_total = 12 + prop_data;
    uint64_t dsd_total  = 12 + data_bytes + (data_bytes & 1);
    uint64_t frm8_data  = 4 + 16 + prop_total + dsd_total;

    write_chunk_header(out, "FRM8", frm8_data);
    fwrite("DSD ", 1, 4, out);

    write_chunk_header(out, "FVER", 4);
    write_u32be(out, 0x01050000);

    write_chunk_header(out, "PROP", prop_data);
    fwrite("SND ", 1, 4, out);

    write_chunk_header(out, "FS  ", 4);
    write_u32be(out, info->fs);

    write_chunk_header(out, "CHNL", chnl_data);
    {
        uint8_t b[2] = { (uint8_t)(ch >> 8), (uint8_t)ch };
        fwrite(b, 1, 2, out);
    }
    for (uint32_t i = 0; i < ch; ++i) fwrite(ids[i], 1, 4, out);
    if (chnl_data & 1) fputc(0, out);

    write_chunk_header(out, "CMPR", cmpr_data);
    fwrite("DSD ", 1, 4, out);
    {
        uint8_t n = 14;
        fwrite(&n, 1, 1, out);
    }
    fwrite("not compressed", 1, 14, out);
    if (cmpr_data & 1) fputc(0, out);

    write_chunk_header(out, "LSCO", 2);
    {
        uint16_t cfg = 65535;
        if (ch == 2) cfg = 0;
        else if (ch == 5) cfg = 3;
        else if (ch == 6) cfg = 4;
        uint8_t b[2] = { (uint8_t)(cfg >> 8), (uint8_t)cfg };
        fwrite(b, 1, 2, out);
    }

    write_chunk_header(out, "DSD ", data_bytes);
    return ferror(out) ? 0 : 1;
}

static int write_dop(FILE *out, const uint8_t *data, size_t bytes_per_ch,
                     int channels, int *marker, int lsb_first) {
    size_t frames = bytes_per_ch / 2;
    if (channels <= 0 || (channels > 1 && (channels & 1)) || (bytes_per_ch & 1))
        return 0;
    if (!frames) return 1;
    init_reverse();

    size_t out_len = frames * (size_t)channels * 3;
    uint8_t *buf = (uint8_t *)malloc(out_len);
    if (!buf) return 0;

    size_t o = 0;
    for (size_t i = 0; i < frames; ++i) {
        uint8_t mk = (*marker) ? 0xFA : 0x05;
        *marker = !*marker;
        size_t base = i * 2 * (size_t)channels;
        for (int ch = 0; ch < channels; ++ch) {
            uint8_t b0 = data[base + (size_t)ch];
            uint8_t b1 = data[base + (size_t)channels + (size_t)ch];
            if (lsb_first) {
                b0 = reverse_table[b0];
                b1 = reverse_table[b1];
            }
            buf[o++] = b0;
            buf[o++] = b1;
            buf[o++] = mk;
        }
    }

    int ok = fwrite(buf, 1, out_len, out) == out_len;
    free(buf);
    return ok;
}

static int copy_native(FILE *in, FILE *out, const DsdInfo *info,
                       uint64_t start_bytes, uint64_t data_bytes) {
    uint8_t buf[65536];
    uint64_t remaining = data_bytes;
    uint64_t offset = info->audio_offset + start_bytes * (uint64_t)info->channels;
    if (!seek_to(in, offset)) return 0;
    init_reverse();

    while (remaining > 0) {
        size_t want = remaining > sizeof(buf) ? sizeof(buf) : (size_t)remaining;
        size_t got = fread(buf, 1, want, in);
        if (got == 0) break;
        if (info->lsb_first) {
            for (size_t i = 0; i < got; ++i) buf[i] = reverse_table[buf[i]];
        }
        if (fwrite(buf, 1, got, out) != got) return 0;
        remaining -= got;
    }
    if (remaining > 0) {
        memset(buf, DSD_SILENCE, sizeof(buf));
        while (remaining > 0) {
            size_t want = remaining > sizeof(buf) ? sizeof(buf) : (size_t)remaining;
            if (fwrite(buf, 1, want, out) != want) return 0;
            remaining -= want;
        }
    }
    if (data_bytes & 1) fputc(0, out);
    return !ferror(out);
}

static int copy_dop(FILE *in, FILE *out, const DsdInfo *info,
                    uint64_t start_bytes, uint64_t data_bytes) {
    uint8_t buf[65536];
    uint64_t remaining = data_bytes;
    uint64_t offset = info->audio_offset + start_bytes * (uint64_t)info->channels;
    if (!seek_to(in, offset)) return 0;
    int marker = 0;

    while (remaining > 0) {
        size_t want = remaining > sizeof(buf) ? sizeof(buf) : (size_t)remaining;
        want -= want % ((size_t)info->channels * 2);
        if (want == 0) break;
        size_t got = fread(buf, 1, want, in);
        if (got == 0) break;
        got -= got % ((size_t)info->channels * 2);
        if (!write_dop(out, buf, got / (size_t)info->channels,
                       info->channels, &marker, info->lsb_first)) return 0;
        remaining -= got;
    }
    return !ferror(out);
}

#ifdef HAVE_LIBAV
static int write_raw(FILE *out, const uint8_t *data, size_t bytes) {
    return fwrite(data, 1, bytes, out) == bytes;
}

static int decode_dst(FILE *out, const char *path, const DsdInfo *info,
                      int dop, double start, uint64_t limit_bytes,
                      uint64_t *written_out) {
    AVFormatContext *fmt = NULL;
    AVCodecContext *dec = NULL;
    AVPacket *pkt = NULL;
    AVFrame *frame = NULL;
    const AVCodec *codec = NULL;
    int stream = -1, ret = 0, marker = 0;
    uint64_t skip = 0, written = 0;
    double rate = (double)info->fs / 8.0;

    if (start > 0) {
        skip = (uint64_t)llround(start * rate) * (uint64_t)info->channels;
    }

    if (avformat_open_input(&fmt, path, NULL, NULL) < 0) return 0;
    if (avformat_find_stream_info(fmt, NULL) < 0) goto fail;
    stream = av_find_best_stream(fmt, AVMEDIA_TYPE_AUDIO, -1, -1, &codec, 0);
    if (stream < 0 || !codec) goto fail;

    dec = avcodec_alloc_context3(codec);
    if (!dec) goto fail;
    if (avcodec_parameters_to_context(dec, fmt->streams[stream]->codecpar) < 0)
        goto fail;
#ifdef HAVE_DSD_SAMPLE_FMT
    dec->request_sample_fmt = AV_SAMPLE_FMT_DSD;
#else
    goto fail;
#endif
    if (avcodec_open2(dec, codec, NULL) < 0) goto fail;

    pkt = av_packet_alloc();
    frame = av_frame_alloc();
    if (!pkt || !frame) goto fail;

    for (;;) {
        ret = av_read_frame(fmt, pkt);
        if (ret < 0) break;
        if (pkt->stream_index != stream) {
            av_packet_unref(pkt);
            continue;
        }
        if (avcodec_send_packet(dec, pkt) < 0) {
            av_packet_unref(pkt);
            continue;
        }
        av_packet_unref(pkt);

        for (;;) {
            ret = avcodec_receive_frame(dec, frame);
            if (ret < 0) break;
            size_t bytes_per_ch = (size_t)frame->nb_samples;
            size_t total = bytes_per_ch * (size_t)info->channels;
            uint8_t *data = frame->data[0];
            if (!data || !total) {
                av_frame_unref(frame);
                continue;
            }
            if (skip) {
                if (total <= skip) {
                    skip -= total;
                    av_frame_unref(frame);
                    continue;
                }
                size_t off = (size_t)(skip - (skip % (uint64_t)info->channels));
                data += off;
                total -= off;
                bytes_per_ch -= off / (size_t)info->channels;
                skip = 0;
            }
            if (limit_bytes && written + total > limit_bytes) {
                total = (size_t)(limit_bytes - written);
                total -= total % ((size_t)info->channels * (dop ? 2 : 1));
                bytes_per_ch = total / (size_t)info->channels;
            }
            if (total) {
                if (dop) {
                    if (!write_dop(out, data, bytes_per_ch, info->channels,
                                   &marker, 0)) {
                        av_frame_unref(frame);
                        goto fail;
                    }
                }
                else {
                    if (!write_raw(out, data, total)) {
                        av_frame_unref(frame);
                        goto fail;
                    }
                }
                written += total;
            }
            av_frame_unref(frame);
            if (limit_bytes && written >= limit_bytes) break;
        }
        if (limit_bytes && written >= limit_bytes) break;
    }

    /* Flush the decoder. */
    avcodec_send_packet(dec, NULL);
    for (;;) {
        ret = avcodec_receive_frame(dec, frame);
        if (ret < 0) break;
        size_t bytes_per_ch = (size_t)frame->nb_samples;
        size_t total = bytes_per_ch * (size_t)info->channels;
        uint8_t *data = frame->data[0];
        if (skip && total) {
            if (total <= skip) { skip -= total; av_frame_unref(frame); continue; }
            size_t off = (size_t)(skip - (skip % (uint64_t)info->channels));
            data += off;
            total -= off;
            bytes_per_ch -= off / (size_t)info->channels;
            skip = 0;
        }
        if (limit_bytes && written + total > limit_bytes) {
            total = (size_t)(limit_bytes - written);
            total -= total % ((size_t)info->channels * (dop ? 2 : 1));
            bytes_per_ch = total / (size_t)info->channels;
        }
        if (total) {
            if (dop) {
                if (!write_dop(out, data, bytes_per_ch, info->channels,
                               &marker, 0)) { av_frame_unref(frame); goto fail; }
            }
            else if (!write_raw(out, data, total)) {
                av_frame_unref(frame);
                goto fail;
            }
            written += total;
        }
        av_frame_unref(frame);
        if (limit_bytes && written >= limit_bytes) break;
    }

    *written_out = written;
    av_frame_free(&frame);
    av_packet_free(&pkt);
    avcodec_free_context(&dec);
    avformat_close_input(&fmt);
    return 1;

fail:
    if (frame) av_frame_free(&frame);
    if (pkt) av_packet_free(&pkt);
    if (dec) avcodec_free_context(&dec);
    if (fmt) avformat_close_input(&fmt);
    return 0;
}
#endif

static void usage(void) {
    fprintf(stderr,
        "usage: sacd_dsd --probe\n"
        "       sacd_dsd --mode native|dop --input FILE [--start SEC] [--end SEC]\n"
        "       sacd_dsd --selftest\n");
}

static int selftest(void) {
    uint8_t dsd[4] = { 0x12, 0xAB, 0x34, 0xCD };
    uint8_t out[6];
    int marker = 0;
    FILE *f = tmpfile();
    if (!f) { fprintf(stderr, "selftest: tmpfile failed\n"); return 1; }
    if (!write_dop(f, dsd, 2, 2, &marker, 0)) {
        fclose(f);
        fprintf(stderr, "selftest: write failed\n");
        return 1;
    }
    fflush(f);
    rewind(f);
    if (fread(out, 1, sizeof(out), f) != sizeof(out)) {
        fclose(f);
        fprintf(stderr, "selftest: read failed\n");
        return 1;
    }
    fclose(f);
    /* frame 0: marker 0x05, ch0 = 0x12 0x34, ch1 = 0xAB 0xCD
       frame 1 (second sample) would use 0xFA, but only one frame exists. */
    if (out[0] != 0x12 || out[1] != 0x34 || out[2] != 0x05 ||
        out[3] != 0xAB || out[4] != 0xCD || out[5] != 0x05) {
        fprintf(stderr, "selftest: unexpected DoP bytes\n");
        return 1;
    }
    printf("selftest=ok\n");
    return 0;
}

int main(int argc, char **argv) {
    Options o;
    memset(&o, 0, sizeof(o));
    o.mode = "native";

    for (int i = 1; i < argc; ++i) {
        const char *a = argv[i];
        if (!strcmp(a, "--probe")) o.probe = 1;
        else if (!strcmp(a, "--selftest")) o.selftest = 1;
        else if (!strcmp(a, "--mode") && i + 1 < argc) o.mode = argv[++i];
        else if (!strncmp(a, "--mode=", 7)) o.mode = a + 7;
        else if (!strcmp(a, "--input") && i + 1 < argc) o.input = argv[++i];
        else if (!strncmp(a, "--input=", 8)) o.input = a + 8;
        else if (!strcmp(a, "--start") && i + 1 < argc) {
            o.start = atof(argv[++i]); o.have_start = 1;
        }
        else if (!strncmp(a, "--start=", 8)) {
            o.start = atof(a + 8); o.have_start = 1;
        }
        else if (!strcmp(a, "--end") && i + 1 < argc) {
            o.end = atof(argv[++i]); o.have_end = 1;
        }
        else if (!strncmp(a, "--end=", 6)) {
            o.end = atof(a + 6); o.have_end = 1;
        }
        else {
            fprintf(stderr, "sacd_dsd: unknown argument: %s\n", a);
            usage();
            return 2;
        }
    }

    signal(SIGPIPE, SIG_IGN);
    setvbuf(stdout, NULL, _IOFBF, 1 << 20);

    if (o.selftest) return selftest();
    if (o.probe) {
        printf("version=0.1.0\n");
        printf("native=1\n");
        printf("dop=1\n");
#ifdef HAVE_DSD_SAMPLE_FMT
        printf("dst_native=1\n");
#else
        printf("dst_native=0\n");
#endif
        return 0;
    }

    if (!o.input) {
        usage();
        return 2;
    }
    if (strcmp(o.mode, "native") && strcmp(o.mode, "dop")) {
        fprintf(stderr, "sacd_dsd: invalid mode: %s\n", o.mode);
        return 2;
    }

    DsdInfo info;
    if (!parse_input(o.input, &info)) {
        fprintf(stderr, "sacd_dsd: unsupported or corrupt input\n");
        return 3;
    }

    double start = o.have_start ? o.start : 0.0;
    double end = o.have_end ? o.end : 0.0;
    if (start < 0) start = 0;
    if (end > 0 && end <= start) {
        fprintf(stderr, "sacd_dsd: end must be greater than start\n");
        return 2;
    }

    int dop = !strcmp(o.mode, "dop");
    if (info.is_dst && o.have_start) {
        /* DST starts are handled by decoding and discarding below. */
    }

    FILE *in = fopen(o.input, "rb");
    if (!in) {
        fprintf(stderr, "sacd_dsd: cannot open input\n");
        return 2;
    }

    if (info.is_dst) {
#ifdef HAVE_LIBAV
        uint64_t data_bytes = bytes_for_seconds(&info, start, end);
        if (dop) {
            data_bytes -= data_bytes % ((uint64_t)info.channels * 2);
        }
        else {
            if (!write_dff_header(stdout, &info, data_bytes)) {
                fclose(in);
                return 4;
            }
        }
        uint64_t written = 0;
        if (!decode_dst(stdout, o.input, &info, dop, start,
                        data_bytes, &written)) {
            fclose(in);
            return 4;
        }
        if (!dop && written < data_bytes) {
            uint8_t pad[4096];
            memset(pad, DSD_SILENCE, sizeof(pad));
            uint64_t remaining = data_bytes - written;
            while (remaining > 0) {
                size_t n = remaining > sizeof(pad) ? sizeof(pad) : (size_t)remaining;
                if (fwrite(pad, 1, n, stdout) != n) { fclose(in); return 4; }
                remaining -= n;
            }
        }
        if (!dop && (data_bytes & 1)) fputc(0, stdout);
        fclose(in);
        return ferror(stdout) ? 4 : 0;
#else
        fclose(in);
        fprintf(stderr, "sacd_dsd: DST decoding is not available in this build\n");
        return 3;
#endif
    }

    if (!info.is_dst) {
        uint64_t start_bytes = 0;
        uint64_t data_bytes;
        if (o.have_start || o.have_end) {
            uint64_t total = bytes_for_seconds(&info, start, end);
            uint64_t skip = bytes_for_seconds(&info, 0, start);
            start_bytes = skip / (uint64_t)info.channels;
            data_bytes = total;
        }
        else {
            data_bytes = info.raw_bytes;
        }
        if (dop) {
            start_bytes -= start_bytes % 2;
            data_bytes -= data_bytes % ((uint64_t)info.channels * 2);
            if (!copy_dop(in, stdout, &info, start_bytes, data_bytes)) {
                fclose(in);
                return 4;
            }
        }
        else {
            if (!write_dff_header(stdout, &info, data_bytes)) {
                fclose(in);
                return 4;
            }
            if (!copy_native(in, stdout, &info, start_bytes, data_bytes)) {
                fclose(in);
                return 4;
            }
        }
    }

    fclose(in);
    return 0;
}
