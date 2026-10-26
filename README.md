# SACD for Lyrion Music Server

[中文说明](README.zh-CN.md)

The `SACD` plugin adds SACD-oriented DSF/DFF support to LMS 9.0+ (tested with 9.0.0 and 9.1.1):

- scans `.dsf` and `.dff` (including DST-compressed DSDIFF),
- reads tags/cover art from headers only, never by decoding the whole file,
- outputs **PCM/FLAC**, **DoP** (DSD over PCM), or **native DSD**,
- automatically falls back to PCM when the player or helper cannot do the
  selected mode.

The plugin mirrors the structure of
[plugin-DSDPlayer](https://github.com/LMS-Community/plugin-DSDPlayer), but adds
DST header parsing and a bounded tag reader.

## Requirements

- Lyrion Music Server **9.0+** (tested: 9.0.0 and 9.1.1).
- **FFmpeg 7.1+** for the PCM/FLAC path (the `ffmpeg` executable is enough).
  The official `lmscommunity/lyrionmusicserver` image does **not** include
  ffmpeg; PCM mode therefore needs ffmpeg installed, while native DFF/DoP DST
  works with the bundled helper alone.
- `Audio::Scan >= 0.94` (shipped with LMS 9.0+).
- For native DSD/DoP: build the small `sacd_dsd` helper in `helper/src`.
- DST native/DoP uses the vendored **libdstdec** decoder, so it does **not**
  require a special FFmpeg build. libdstdec handles DST at DSD64, DSD128 and
DSD256.

## Install

1. Use the packaged `dist/SACDPlayer` folder (or the release ZIP/tarball) and
   copy it to `Plugins/SACDPlayer` under the LMS installation. The source tree
   contains `install.xml.in` only; it is not directly installable before
   `make dist`.
2. Build the helper:
   ```sh
   sudo apt-get install build-essential
   make -C helper/src
   make -C helper/src install
   ```
   This installs `Bin/x86_64-linux/sacd_dsd` (or the matching arch). The
   helper includes libdstdec, so DST native/DoP is available without FFmpeg
   development headers.
3. Restart LMS. Enable the plugin under **Settings > Plugins**.
4. Open the plugin settings to check FFmpeg/helper status, then per-player
   settings to choose the output mode.

The helper can also be placed on `PATH`; the plugin settings page allows an
absolute path.

## Output modes

| Mode | Output | Notes |
|---|---|---|
| PCM | 24-bit FLAC via FFmpeg | Default. DSD64 → 352.8 kHz; higher DSD rates are reduced to at most 352.8 kHz and to a rate the player accepts. |
| DoP | 24-bit PCM WAV at DSD/16 | Bit-perfect DSD transport; DAC must support DoP. Default cap DSD128 (configurable DSD64/128/256). |
| Native | DFF (raw DSD) via helper | Player must report `dff` (the helper emits DFF). DST requires helper `dst_native=1`; otherwise PCM fallback. Recommended for Squeezelite and for Docker installs without ffmpeg. |

DoP is *not* the same as native DSD: it is DSD data carried in 24-bit PCM
samples with the DoP marker bytes. The helper wraps it in a WAV container so
LMS/players see the correct DSD/16 sample rate even on LMS 9.0/9.1, which have no
per-stream sample-rate hook.

The `SACD` plugin is a **decode-only** plugin: it turns DSD/DST into lossless FLAC
or raw PCM and never defines a final lossy profile (AAC/Ogg Vorbis/Opus). When
a lossy target is requested, `CodecSwitch` composes the pipeline
(`DSD -> FLAC/PCM -> target`) and `FFmpeg` performs the encoder step.

## Decode provider (CodecSwitch / FFmpeg integration)

An orchestration layer can ask the `SACD` plugin for its decode capabilities and for
a ready-to-use decode command through two optional methods. Both are safe to
call when CodecSwitch is not installed, and neither changes standalone
playback:

- `Plugins::SACDPlayer::Transcoder->codec_capabilities($client)` returns

  ```perl
  {
      provider => 'sacd',
      priority => 50,
      decode   => [
          { from => [qw(dff dsf)], to => ['flc'], scope => ['local'] },
          { from => [qw(dff dsf)], to => ['pcm'], scope => ['local'],
            pcm  => { sample_fmt => 's16le', rate => 44100, channels => 2 } },
      ],
      encode   => [],
  }
  ```

- `Plugins::SACDPlayer::Transcoder->decode_plan($client, $format, $opts)`
  returns `{ command, capabilities, format }`, or `undef` when the requested
  format is not a DSD decode target (for example `aac`, `ogg`, `ops`).
  - `$format = 'flc'` reuses the FFmpeg FLAC output command (`-f flac -`).
  - `$format = 'pcm'` returns raw little-endian PCM with no container.
    `$opts` accepts `sample_fmt` (`s16le` or `s24le`, default `s16le`),
    `rate` (default `44100`) and `channels` (default `2`).
  - `command` is an LMS profile-style command using the `$FILE$`, `$START$`,
    `$END$` and `$RESAMPLE$` placeholders; `capabilities` is an LMS capability
    hashref (`F`, `T`, `U`, `D`).

Example:

```perl
my $plan = Plugins::SACDPlayer::Transcoder->decode_plan(
    $client, 'pcm', { sample_fmt => 's16le', rate => 48000, channels => 2 },
);
my $command = $plan->{command} . ' | ' . $encoder_command;
```

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
The `SACD` plugin is the one that handles DST and provides the additional output
modes.

## Limitations

- **SACD ISO (`.iso`) is not supported.** It needs a virtual-track or
  extraction-cache design; see the project plan for the proposed phase 2.
- Native/DoP DST decoding uses the vendored **libdstdec** and currently
  supports **DSD64, DSD128 and DSD256 DST** (DSD64 is the SACD format).
  DSD256 uses the same 75 fps frame layout and libdstdec's 18816-byte frame
  limit; it has not been tested against a real DSD256 DST sample yet.
  See `THIRD_PARTY_NOTICES.md` for license/source details.
- Native DST seeking decodes from the beginning and discards; it is correct but
  not instant.
- Multi-channel output is passed through, but the player/DAC must support the
  channel count.
- Windows builds are not part of the initial verification; Linux is primary.

## Prebuilt / compiled folder

The plugin itself is Perl (LMS loads Perl modules), but the architecture-specific
helper is a native binary. To make a deployment folder that contains everything
needed on the LMS host:

```sh
make dist
```

This creates:

```text
dist/SACDPlayer/
├── install.xml
├── lib/                 # plugin Perl modules
├── HTML/                # settings pages
├── strings.txt
├── Bin/x86_64-linux/sacd_dsd   # plus aarch64/armhf/arm/i386/Windows
├── README.md
├── README.zh-CN.md
├── THIRD_PARTY_NOTICES.md
└── LICENSE
```

Copy the **whole** `SACDPlayer` folder into `<LMS>/Plugins/`:

```sh
cp -a dist/SACDPlayer /path/to/lms/Plugins/SACDPlayer
```

For the official Docker image (`lmscommunity/lyrionmusicserver`), the
third-party plugin directory is **`/config/cache/Plugins`**, not
`/config/Plugins`:

```sh
docker cp dist/SACDPlayer <container>:/config/cache/Plugins/SACDPlayer
```

or as a read-only mount:

```sh
-v /path/to/dist/SACDPlayer:/config/cache/Plugins/SACDPlayer:ro
```

No compiler or FFmpeg development headers are needed on the LMS host. The
default `make dist` helper is statically linked and contains the vendored
libdstdec decoder, so `dst_native=1` for DSD64/128/256 DST.

`make install PLUGINS_DIR=/path/to/lms/Plugins` copies the same folder directly.
`make bundle` creates a host-architecture archive; `make bundle-all` builds
all supported Linux architectures and creates `dist/SACDPlayer-<version>-all.tar.gz`.

### Supported helper architectures

```text
x86_64-linux
aarch64-linux
armhf-linux
arm-linux
i386-linux
MSWin32-x64-multi-thread
```

`make bins` builds all supported targets into `Bin/`; `make verify-bins`
checks them with `file` plus QEMU/Wine. On Debian the cross builds require
both the `gcc-*-linux-gnu`/MinGW compilers and the matching
`libc6-dev-*-cross` header packages (the compilers only *recommend* them). Release CI uses `bundle-all`, so the
package contains every target. macOS (`darwin`) is not supported.

## Versioning

`VERSION` is the single source of truth. The tracked files
`install.xml.in` and `repo.xml.in` contain only `@VERSION@` / `@RELEASE_URL@`
placeholders; the real XML is generated into `build/` for a release and is not
committed.

To bump everything at once:

```sh
make bump VERSION=0.3.1
```

`make dist` / `make bundle` render `build/install.xml` and `build/repo.xml`
from `VERSION`; the helper's `--probe` version is compiled from the same value.
CI passes the tag version as `VERSION=...`. The release URL base and tag prefix
are configurable with `RELEASE_BASE=...` and `RELEASE_TAG_PREFIX=...`
(defaults: this project's Forgejo and `v`).

To generate only the plugin-catalog file:

```sh
make repo
# -> build/repo.xml
```

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
