# Helper binaries

Release packages contain static helpers for the supported platforms:

```text
Bin/x86_64-linux/sacd_dsd
Bin/aarch64-linux/sacd_dsd
Bin/armhf-linux/sacd_dsd
Bin/arm-linux/sacd_dsd
Bin/i386-linux/sacd_dsd
Bin/MSWin32-x64-multi-thread/sacd_dsd.exe
```

The LMS host needs no compiler. The plugin manager adds the matching
`Bin/<arch>` directory to `PATH`; `sacd_dsd` includes the vendored libdstdec
decoder and needs no libav runtime.

For a source checkout:

```sh
make bins          # build all supported architectures into Bin/
make -C helper/src # build only the host architecture
make verify-bins   # file/readelf sanity + QEMU/Wine --probe
```

`make dist` includes every binary already present under `Bin/`;
`make dist-all` builds all supported architectures first.
