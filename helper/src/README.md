# sacd_dsd

Small C helper used by the LMS SACDPlayer plugin.

## Build

```sh
make
make test
make install
```

`pkg-config` is used to detect libavformat/libavcodec/libavutil. When they are
available, DST decoding is enabled if the headers also provide
`AV_SAMPLE_FMT_DSD`. When they are not available, the helper still supports:

- uncompressed DSF/DFF → native DFF,
- uncompressed DSF/DFF → DoP 24-bit PCM.

## Modes

```sh
sacd_dsd --probe
sacd_dsd --selftest
sacd_dsd --mode native --input FILE [--start SEC] [--end SEC]
sacd_dsd --mode dop    --input FILE [--start SEC] [--end SEC]
```

- `native` writes a valid DSDIFF (`FRM8`/`PROP`/`DSD `) stream. DSF LSB-first
  bytes are reversed to DFF MSB-first.
- `dop` writes raw interleaved 24-bit little-endian PCM. Each sample is
  `marker << 16 | dsd_byte_0 << 8 | dsd_byte_1`; the marker alternates
  `0x05`/`0xFA`.
- `--start/--end` are seconds. DST decoding starts at the beginning and
  discards until `--start` (DST frame-level seeking is not implemented).

## License

GPL-2.0-or-later.
