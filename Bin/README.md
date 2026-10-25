# Helper binaries

A release folder produced by `make dist` already contains the native helper
under `Bin/<arch>-linux/sacd_dsd`; the LMS host needs no compiler.

For a source checkout, build and install it with:

```sh
make -C ../helper/src
make -C ../helper/src install
```

`make install` places `sacd_dsd` in `Bin/<arch>-linux/`. Prebuilt binaries are
not required for PCM/FLAC playback (FFmpeg is used), but native DSD/DoP need
the helper. Release builds statically link the helper, including the vendored
libdstdec decoder; no libav runtime library is required.
