# sacd_dsd

Small C helper used by the LMS SACD plugin.

## Build

```sh
make
make test
make install
```

The helper bundles **libdstdec** under `libdstdec/` for DST decoding at
DSD64, DSD128 and DSD256. It is always compiled in, so DST native/DoP does not need FFmpeg
development headers or `AV_SAMPLE_FMT_DSD`.

The helper also supports:

- uncompressed DSF/DFF → native DFF,
- uncompressed DSF/DFF → DoP 24-bit PCM WAV,
- DST (DSD64/DSD128/DSD256) → native DFF or DoP via libdstdec.

`pkg-config`/libav is still probed as an optional future backend for
higher-rate DST; it is not required, and the current streaming path uses
libdstdec.

## Modes

```sh
sacd_dsd --probe
sacd_dsd --selftest
sacd_dsd --mode native --input FILE [--start SEC] [--end SEC]
sacd_dsd --mode dop    --input FILE [--start SEC] [--end SEC] [--wav]
```

- `native` writes a valid DSDIFF (`FRM8`/`PROP`/`DSD `) stream. DSF LSB-first
  bytes are reversed to DFF MSB-first.
- `dop` writes interleaved 24-bit little-endian PCM. Each sample is
  `marker << 16 | dsd_byte_0 << 8 | dsd_byte_1`; the marker alternates
  `0x05`/`0xFA`. With `--wav`, a PCM WAV header is written first so the
  DSD/16 sample rate is carried in the stream.
- `--start/--end` are seconds. DST decoding starts at the beginning and
  discards until `--start` (DST frame-level seeking is not implemented).
- `--probe` reports `dst_native=1` and `dst_native_max_fs=256` when libdstdec
  is compiled in.

## License

GPL-2.0-or-later.
