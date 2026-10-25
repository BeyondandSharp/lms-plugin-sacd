# Helper binaries

Build the helper for the local architecture:

```sh
make -C ../helper/src
make -C ../helper/src install
```

`make install` places `sacd_dsd` in `Bin/<arch>-linux/`. Prebuilt binaries are
not required for PCM/FLAC playback (FFmpeg is used), but native DSD/DoP need
the helper. If you distribute binaries, build them on a compatible libc and
document the FFmpeg/libav version used.
