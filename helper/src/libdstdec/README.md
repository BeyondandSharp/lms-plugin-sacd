# libdstdec (vendored)

Source: <https://github.com/sacd-ripper/sacd-ripper/tree/master/libs/libdstdec>

Vendored revision: `a3d981c935c3224217e2842cd492f9351106c81e` (2023-01-14).

The helper only compiles the low-level decoder files:

- `dst_init.c/h`
- `dst_fram.c/h`
- `dst_ac.c/h`
- `dst_data.c/h`
- `ccp_calc.c/h`
- `unpack_dst.c/h`
- `types.h`, `conststr.h`

The threaded `dst_decoder.c`, `yarn.c`, `buffer_pool.c` are not used; the
helper drives `DST_InitDecoder`/`DST_FramDSTDecode` sequentially.

SACD DST is DSD64 (2,822,400 bit/s); each `DSTF` frame decodes to 4,704 bytes
per channel. Higher-rate DST is rejected and falls back to PCM.

License: GPL-2.0 (see `COPYING`); the original Philips/MPEG-4 notices in each
source file are retained.
