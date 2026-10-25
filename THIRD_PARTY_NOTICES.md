# Third-party notices

## libdstdec

`helper/src/libdstdec/` is a vendored subset of the DST decoder from
[sacd-ripper](https://github.com/sacd-ripper/sacd-ripper), revision
`a3d981c935c3224217e2842cd492f9351106c81e`.

The libdstdec source files carry their original Philips / MPEG-4 Audio
notices.  The sacd-ripper project is distributed under GPL-2.0; see
`helper/src/libdstdec/COPYING`.  The decoder is compiled into `sacd_dsd`.

DSD64 is the SACD DST format; the helper decodes DSD64/128/256 DST frames to raw DSD for native
DFF and DoP output.

## FFmpeg

FFmpeg is not bundled.  It is used as an optional PCM decoder/encoder via the
`ffmpeg` executable.  The optional libav build path is only enabled when the
headers expose `AV_SAMPLE_FMT_DSD`; FFmpeg remains under its own license.
