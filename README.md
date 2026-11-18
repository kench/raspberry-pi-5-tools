# FFmpeg for Raspberry Pi 5 (cross-compiled)

Cross-compiles FFmpeg 9.0.2 with the Raspberry Pi patch set (hardware HEVC decode via
V4L2 request API, DRM/EGL output) plus libx264 and libsrt, for a Raspberry Pi 5 running
**Raspberry Pi OS Trixie** (arm64), from a Debian 13 (trixie) x86_64 host.

Because the Pi and the host share the same Debian base (glibc 2.41), the toolchain uses the
host's Debian cross compiler plus multiarch `:arm64` packages; no separate sysroot is needed.
If the Pi runs Bookworm instead, this approach will produce binaries that fail with
`GLIBC_2.38 not found`; build against a Bookworm sysroot instead.

## Layout

```
toolchain/
  env.sh                       # `. toolchain/env.sh` – CC, CFLAGS, PKG_CONFIG for autotools/manual builds
  aarch64-linux-gnu-pkg-config # pkg-config wrapper that only sees arm64 .pc files
  aarch64-rpi5.meson           # meson cross file
  aarch64-rpi5.cmake           # CMake toolchain file
  verify.sh                    # builds test/hello.c and runs it under qemu
  configure-ffmpeg.sh          # configures FFmpeg for the Pi 5
  build-srtla.sh               # cross-compiles srtla_send/srtla_rec into stage/
  deploy.sh                    # installs the staged build on a Pi over ssh
test/                          # hello-world used to sanity-check the toolchain
patches/rpi-9.0.2/             # 38 Raspberry Pi patches exported against n9.0.2
src/ffmpeg/                    # FFmpeg git checkout (branch rpi-9.0.2-applied)
src/srtla/                     # BELABOX srtla checkout
build/ffmpeg-arm64/            # out-of-tree build directory
```

## 1. Install the host toolchain

Run in a regular terminal (sudo needs to prompt for a password):

```sh
sudo dpkg --add-architecture arm64
sudo apt update
sudo apt install -y crossbuild-essential-arm64 pkgconf qemu-user meson ninja-build cmake make git file
```

Debian trixie has **no** `pkg-config-aarch64-linux-gnu` package, and `pkgconf` doesn't install an
`aarch64-linux-gnu-pkg-config` wrapper either. That is why this repo ships its own wrapper in
`toolchain/aarch64-linux-gnu-pkg-config`.

Verify:

```sh
toolchain/verify.sh
# build/hello: ELF 64-bit LSB pie executable, ARM aarch64, ...
# hello from aarch64, glibc 2.41
```

Running arm64 binaries under qemu needs `-L /usr/aarch64-linux-gnu` (or `QEMU_LD_PREFIX`,
which `env.sh` sets) so it can find the arm64 dynamic loader. The meson and CMake files
already pass it.

## 2. Get FFmpeg and the Raspberry Pi patches

The Raspberry Pi patches live in `https://github.com/jc-kynesim/rpi-ffmpeg`, on branches
named `test/<version>/main`. `test/9.0.2/main` is based directly on the upstream `n9.0.2` tag.

```sh
mkdir -p src
git clone https://git.ffmpeg.org/ffmpeg.git src/ffmpeg
cd src/ffmpeg
git remote add rpi https://github.com/jc-kynesim/rpi-ffmpeg
git fetch rpi test/9.0.2/main
```

Do **not** use `--filter=blob:none` (a partial clone). git.ffmpeg.org doesn't support it.
Git then tries to lazily fetch rpi-only blobs from the FFmpeg server, which fails with
`not our ref` and produces incomplete patches.

Export the patch series and apply it to n9.0.2:

```sh
git format-patch -o ../../patches/rpi-9.0.2 n9.0.2..rpi/test/9.0.2/main   # 38 patches
git checkout -b rpi-9.0.2-applied n9.0.2
git am --keep-cr ../../patches/rpi-9.0.2/*.patch
git diff --quiet HEAD rpi/test/9.0.2/main && echo identical
cd ../..
```

Notes:
- The branch contains 39 commits; one is a merge of the `n9.0.2` tag, which `format-patch`
  skips. The 38 remaining patches reproduce the rpi branch tree exactly.
- `--keep-cr` is needed because four test-data files under `pi-util/` have CRLF line endings.
  Without it the tree differs from the rpi branch in those files only (no code is affected).

### Patch compatibility (checked 2026-11-16)

| Upstream target              | Result                                                        |
|------------------------------|---------------------------------------------------------------|
| `n9.0.2` (latest release)    | Applies cleanly, 38/38                                        |
| `release/9.0` tip            | Applies cleanly, 38/38 (57 commits past n9.0.2)               |
| `master`                     | Fails at patch 5 (`checkasm: Add tests for rpi_sand sand30 fns`), conflict in `tests/checkasm/checkasm.c` |

## 3. Install arm64 build dependencies

```sh
sudo apt install -y libx264-dev:arm64 libsrt-gnutls-dev:arm64 libdrm-dev:arm64 libudev-dev:arm64 \
    libepoxy-dev:arm64 libx11-dev:arm64 libxext-dev:arm64 libxv-dev:arm64
```

Why each one is needed:
- `libx264-dev`, `libsrt-gnutls-dev`: x264 encoding and SRT streaming. The GnuTLS variant of
  libsrt matches what Debian and Pi OS build their FFmpeg against.
- `libdrm-dev`, `libudev-dev`: required by `--enable-v4l2-request` (hardware HEVC decode).
- `libepoxy-dev`, `libx11-dev`, `libxext-dev`, `libxv-dev`: required by the `vout_egl` output device.

## 4. Configure

```sh
toolchain/configure-ffmpeg.sh
```

This configures FFmpeg in `build/ffmpeg-arm64` for `--arch=aarch64 --cpu=cortex-a76`, using
the cross pkg-config wrapper. It enables the same Pi features as the upstream
`pi-util/conf_native.sh` (`sand`, `v4l2-request`, `libdrm`, `vout-drm`, `vout-egl`), plus
`--enable-gpl --enable-libx264 --enable-libsrt`. It builds shared libraries only, installed
under `$PREFIX/lib/aarch64-linux-gnu`.

Environment overrides: `PREFIX` (default `/usr/local`) and `BUILDDIR` (default
`build/ffmpeg-arm64`). Extra arguments are passed through to `configure`.

Check that the important components were enabled:

```sh
grep -E '#define CONFIG_(LIBX264_ENCODER|LIBSRT_PROTOCOL|HEVC_V4L2REQUEST_HWACCEL|VOUT_(DRM|EGL)_OUTDEV) ' \
    build/ffmpeg-arm64/config_components.h
```

All five should be `1`. Component flags are in `config_components.h`; library-level flags
(`CONFIG_LIBX264`, `CONFIG_SAND`, ...) are in `config.h`.

## 5. Build and stage

```sh
make -C build/ffmpeg-arm64 -j$(nproc)
make -C build/ffmpeg-arm64 install DESTDIR=$PWD/stage
```

`stage/usr/local/...` then holds the binaries, libraries and headers to copy to the Pi (about 32 MB).
The version string is `n9.0.2-38-g<hash>-rpi`.

### Test on the host under qemu

The shared libraries aren't installed system-wide on the host, so point qemu at the build tree:

```sh
B=build/ffmpeg-arm64
Q="qemu-aarch64 -L /usr/aarch64-linux-gnu -E LD_LIBRARY_PATH=$(ls -d $PWD/$B/lib* | paste -sd:)"
$Q $B/ffmpeg -hide_banner -encoders | grep libx264    # libx264, libx264rgb
$Q $B/ffmpeg -hide_banner -protocols | grep -w srt    # srt
$Q $B/ffmpeg -hide_banner -devices | grep vout        # vout_drm, vout_egl
$Q $B/ffmpeg -f lavfi -i testsrc2=size=640x360:rate=30 -t 2 -c:v libx264 out.mp4
```

qemu can only test software paths. Hardware decode (`v4l2-request`, `v4l2m2m`) and the
DRM/EGL outputs need the real Pi.

## 6. Build srtla

[srtla](https://github.com/BELABOX/srtla) bonds several network links (e.g. multiple modems)
into one SRT stream. `srtla_send` runs on the sending side; `srtla_rec` reassembles the
stream and forwards it to an SRT listener.

```sh
git clone https://github.com/BELABOX/srtla src/srtla   # built and tested at 37862da
toolchain/build-srtla.sh
```

This builds with the cross compiler and `-mcpu=cortex-a76`, then installs stripped
`srtla_send` and `srtla_rec` into `stage/usr/local/bin`. srtla's Makefile hardcodes
`CFLAGS`, so the script overrides it on the make command line and keeps the
`-DVERSION=<git hash>` that `-v` prints. srtla only depends on libc, so it adds no runtime
packages on the Pi.

Check them under qemu:

```sh
qemu-aarch64 -L /usr/aarch64-linux-gnu stage/usr/local/bin/srtla_send -v   # 37862da
qemu-aarch64 -L /usr/aarch64-linux-gnu stage/usr/local/bin/srtla_rec -v    # 37862da
```

## 7. Deploy to the Pi

```sh
toolchain/deploy.sh pi@raspberrypi.local
```

This script:
1. Checks the Pi is aarch64 running Trixie. It refuses Bookworm and older, because their
   glibc is too old for this build (override with `ALLOW_ANY_OS=1`).
2. Copies `stage/usr/local` to the Pi with tar over ssh, so rsync isn't needed on the Pi.
3. Runs `apt-get update` and installs the runtime libraries the build links against:
   `libdrm2 libepoxy0 libsrt1.5-gnutls libudev1 libx11-6 libx264-164 libxcb1 libxext6 libxv1`.
4. Copies the files into `/usr/local` and runs `ldconfig`. `/usr/local/lib/aarch64-linux-gnu`
   is already on Debian's default linker path. For other prefixes the script writes
   `/etc/ld.so.conf.d/ffmpeg-rpi.conf`.
5. Checks every library resolves, then prints the FFmpeg version, hwaccels, libx264/srt
   status, and the `srtla_send`/`srtla_rec` versions. It warns if a different `ffmpeg` comes
   first on `PATH`.

The script refuses to run unless both the FFmpeg build and the srtla binaries are staged.

It uses one shared ssh connection, so you're prompted at most once for the ssh password and
once for sudo. Options: `PREFIX` (must match the one used at configure time) and `SSH` for
extra ssh options, e.g. `SSH="-p 2222 -i ~/.ssh/pi"`.

The build's libraries have different sonames (`libavcodec.so.63`, ...) from Pi OS's own
FFmpeg packages, so the two can be installed side by side.

### Hardware decode test (on the Pi)

```sh
/usr/local/bin/ffmpeg -hwaccel drm -i input-hevc.mkv -f null -
```

The Pi 5 has a hardware **HEVC decoder** only. It has no hardware H.264 decoder and no
hardware encoders, so `h264_v4l2m2m` and the other `*_v4l2m2m` encoders are built but have
no device to use on a Pi 5. Encode with `libx264` instead.

## Using the toolchain for other projects

- Autotools/manual: `. toolchain/env.sh`, then `./configure --host=aarch64-linux-gnu`.
- Meson: `meson setup build --cross-file toolchain/aarch64-rpi5.meson`.
  (The cross file finds the pkg-config wrapper via `@DIRNAME@`, the cross file's own
  directory, so it works from any clone location.)
- CMake: `cmake -DCMAKE_TOOLCHAIN_FILE=toolchain/aarch64-rpi5.cmake ...`.
- Arm64 libraries: `sudo apt install <name>-dev:arm64`.

## License

The files written for this project (`toolchain/`, `test/`, `README.md`, `AGENTS.md`,
`.gitignore`) are released under [CC0 1.0 Universal](LICENSE), a public domain dedication.

The CC0 dedication does **not** cover third-party material:

- `patches/rpi-9.0.2/` contains Raspberry Pi's patches to FFmpeg, exported unchanged from
  `jc-kynesim/rpi-ffmpeg`. They remain under FFmpeg's licenses: LGPL 2.1 or later, with some
  files GPL 2.0 (see the license headers inside the patches).
- FFmpeg and srtla (`src/`, not committed) keep their own licenses: FFmpeg is LGPL/GPL, and
  srtla is AGPL 3.0.
- Binaries built by these scripts are GPL 2.0 or later, because they are configured with
  `--enable-gpl` and link libx264. Distributing them carries GPL obligations, including
  offering the corresponding source.
