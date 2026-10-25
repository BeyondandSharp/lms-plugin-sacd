# SACDPlayer for Lyrion Music Server

`SACDPlayer` adds SACD-oriented DSF/DFF support to LMS 9.2+:

- scans `.dsf` and `.dff` (including DST-compressed DSDIFF),
- reads tags/cover art from headers only, never by decoding the whole file,
- outputs **PCM/FLAC**, **DoP** (DSD over PCM), or **native DSD**,
- automatically falls back to PCM when the player or helper cannot do the
  selected mode.

The plugin mirrors the structure of
[plugin-DSDPlayer](https://github.com/LMS-Community/plugin-DSDPlayer), but adds
DST header parsing and a bounded tag reader.

## Requirements

- Lyrion Music Server **9.2+**.
- **FFmpeg 7.1+** for the PCM/FLAC path (the `ffmpeg` executable is enough).
- `Audio::Scan >= 0.94` (shipped with LMS 9.2).
- For native DSD/DoP: build the small `sacd_dsd` helper in `helper/src`.
- For **native DST** output, the helper must be built against a libavcodec
  revision that exposes `AV_SAMPLE_FMT_DSD` (new FFmpeg master/8.x-era).
  Without it, DST still plays in PCM mode and native mode falls back to PCM.

## Install

1. Copy this directory to `Plugins/SACDPlayer` under the LMS installation
   (or use the plugin repository ZIP).
2. Build the helper:
   ```sh
   sudo apt-get install build-essential pkg-config \
        libavformat-dev libavcodec-dev libavutil-dev
   make -C helper/src
   make -C helper/src install
   ```
   This installs `Bin/x86_64-linux/sacd_dsd` (or the matching arch). If you do
   not have FFmpeg development headers, `make` still builds a helper for
   uncompressed DSF/DFF and DoP; only native DST is disabled.
3. Restart LMS. Enable the plugin under **Settings > Plugins**.
4. Open the plugin settings to check FFmpeg/helper status, then per-player
   settings to choose the output mode.

The helper can also be placed on `PATH`; the plugin settings page allows an
absolute path.

## Output modes

| Mode | Output | Notes |
|---|---|---|
| PCM | 24-bit FLAC via FFmpeg | Default. DSD64 → 352.8 kHz; higher DSD rates are reduced to at most 352.8 kHz and to a rate the player accepts. |
| DoP | 24-bit raw PCM at DSD/16 | Bit-perfect DSD transport; DAC must support DoP. Default cap DSD128 (configurable DSD64/128/256). |
| Native | DFF (raw DSD) via helper | Player must report `dff` (the helper emits DFF). DST requires helper `dst_native=1`; otherwise PCM fallback. |

DoP is *not* the same as native DSD: it is DSD data carried in 24-bit PCM
samples with the DoP marker bytes.

## Tag reading

- **DSF**: `Audio::Scan` reads the 80-byte header and seeks to the ID3 block.
  If Audio::Scan is unavailable, the plugin parses the header and ID3 itself.
- **DFF/DSD**: the plugin parses `FRM8`, `PROP`, `DIIN` and `ID3` chunks and
  seeks over the `DSD ` audio payload.
- **DFF/DST**: Audio::Scan rejects DST; the plugin parses `FRTE` for duration
  and `DSTF` headers are skipped, never read. ID3/DIIN tags are read from
  bounded chunks.
- `ffprobe` is only a fallback when header/metadata parsing fails. It is run
  with `-probesize 5000000 -analyzeduration 2000000`.

A unit test parses a synthetic DST file, reads its ID3 tags and derives the
duration from `FRTE`; the `DSTF` payload is skipped (see `t/01-tag.t`).

## Conflict with DSDPlayer

Both plugins replace the `dsf`/`dff` tag reader. Enable only one of them. If
both are enabled, the plugin logs a warning; the last loaded plugin wins.
`SACDPlayer` is the one that handles DST and provides the additional output
modes.

## Limitations

- **SACD ISO (`.iso`) is not supported in 0.1.0.** It needs a virtual-track or
  extraction-cache design; see the project plan for the proposed phase 2.
- DST native output depends on the optional libavcodec raw-DSD support.
- Native DST seeking decodes from the beginning and discards; it is correct but
  not instant.
- Multi-channel output is passed through, but the player/DAC must support the
  channel count.
- Windows builds are not part of the initial verification; Linux is primary.

## Development

```sh
make -C helper/src
prove -l -It/lib t
make -C helper/src test
```

The plugin modules live under `lib/Plugins/SACDPlayer/`; the helper source is
under `helper/src/`.

Key files:

- `lib/Plugins/SACDPlayer/TagReader.pm` – bounded metadata reader.
- `lib/Plugins/SACDPlayer/DFFParser.pm` – DSDIFF/DFF chunk walker (DST aware).
- `lib/Plugins/SACDPlayer/ID3.pm` – minimal ID3v2 parser/cover reader.
- `lib/Plugins/SACDPlayer/Transcoder.pm` – LMS command profiles.
- `lib/Plugins/SACDPlayer/Hooks.pm` – sampling-rate and format-selection hooks.
- `helper/src/sacd_dsd.c` – DoP packer and DFF writer.
