# AGENTS.md

Guidance for coding agents working in this repo. `README.md` has the full step-by-step
reproduction; this file covers the context, constraints and gotchas an agent needs.

## What this is

A cross-compilation setup that builds, on a Debian 13 (trixie) x86_64 host, for a
**Raspberry Pi 5 running Raspberry Pi OS Trixie (arm64)**:

- **FFmpeg 9.0.2 + Raspberry Pi patches**: hardware HEVC decode via V4L2 request API
  (`sand`, `v4l2-request`, `-hwaccel drm`), DRM/EGL output devices, plus `libx264` and `libsrt`.
- **srtla** (BELABOX): `srtla_send` / `srtla_rec`, for bonding several network links into one SRT stream.

Everything is staged into `stage/usr/local` and pushed to the Pi with `toolchain/deploy.sh`.

## Key decisions (don't undo without reason)

- **No sysroot.** The Pi and host share the same Debian base (glibc 2.41), so the toolchain is
  Debian's `crossbuild-essential-arm64` plus multiarch `:arm64` dev packages. Arm64 libraries
  are added with `sudo apt install <pkg>-dev:arm64`. If the Pi target ever changes to Bookworm,
  this approach breaks (`GLIBC_2.38 not found`) and a Bookworm sysroot is needed instead.
- **Own pkg-config wrapper.** Trixie has no `pkg-config-aarch64-linux-gnu` package and `pkgconf`
  installs no cross wrapper. `toolchain/aarch64-linux-gnu-pkg-config` sets `PKG_CONFIG_LIBDIR`
  to the arm64 `.pc` directories only, so host x86 libraries can never leak into the build.
- **CPU flags:** `-mcpu=cortex-a76` (Pi 5) everywhere. FFmpeg uses `--arch=aarch64 --cpu=cortex-a76`.
- **FFmpeg version:** 9.0.2 with patches from `jc-kynesim/rpi-ffmpeg` branch `test/9.0.2/main`.
  They apply cleanly to `n9.0.2` and to the `release/9.0` tip, but not to `master`
  (patch 5 conflicts in `tests/checkasm/checkasm.c`). Stay on the 9.0 release line.
- **libsrt variant:** `libsrt-gnutls`, matching Debian/Pi OS's own FFmpeg.
- **Install layout:** `--prefix=/usr/local`, libs in `/usr/local/lib/aarch64-linux-gnu`, which is
  already on Debian's linker path. The sonames (`libavcodec.so.63`, ...) differ from Pi OS's
  packaged FFmpeg, so both coexist.

## Layout

```
toolchain/
  env.sh                       # POSIX-sourceable env: CC, CFLAGS, PKG_CONFIG, QEMU_LD_PREFIX
  aarch64-linux-gnu-pkg-config # arm64-only pkg-config wrapper
  aarch64-rpi5.meson           # meson cross file (wrapper via @DIRNAME@; never hardcode absolute paths)
  aarch64-rpi5.cmake           # CMake toolchain file
  verify.sh                    # builds/runs test/hello.c under qemu
  configure-ffmpeg.sh          # configures FFmpeg into build/ffmpeg-arm64
  build-srtla.sh               # builds srtla into stage/usr/local/bin
  deploy.sh                    # ships stage/ to a Pi over ssh
.github/workflows/build.yml    # CI: lint + full build/patch-check/smoke-test in debian:trixie
patches/rpi-9.0.2/             # 38 rpi patches exported against n9.0.2
src/ffmpeg/                    # upstream FFmpeg clone, branch rpi-9.0.2-applied (+ remote `rpi`)
src/srtla/                     # BELABOX srtla clone (built at 37862da)
build/ffmpeg-arm64/            # out-of-tree FFmpeg build
stage/usr/local/               # install staging: bin/{ffmpeg,ffprobe,srtla_send,srtla_rec}, lib/, include/
```

## Commands

```sh
toolchain/verify.sh                                   # toolchain sanity check
toolchain/configure-ffmpeg.sh [extra configure args]  # PREFIX, BUILDDIR overridable
make -C build/ffmpeg-arm64 -j$(nproc)
make -C build/ffmpeg-arm64 install DESTDIR=$PWD/stage
toolchain/build-srtla.sh
toolchain/deploy.sh [user@]host                       # PREFIX, SSH, ALLOW_ANY_OS overridable
```

Test arm64 binaries on the host with qemu. Shared FFmpeg libs aren't installed on the host, so:

```sh
B=build/ffmpeg-arm64
qemu-aarch64 -L /usr/aarch64-linux-gnu -E LD_LIBRARY_PATH=$(ls -d $PWD/$B/lib* | paste -sd:) $B/ffmpeg -version
```

After configuring, confirm features in `build/ffmpeg-arm64/config_components.h` (encoders,
protocols, outdevs, hwaccels). Library-level flags are in `config.h`. Grepping only `config.h`
for e.g. `LIBX264_ENCODER` returns nothing, which looks like a failure but isn't.

## Gotchas learned the hard way

- **sudo needs a password and a real terminal.** Agents can't run `sudo`, and `! sudo ...` in
  Claude Code fails too. Give the user a single-line command to run in a separate terminal,
  then verify the result with `dpkg -s <pkg>:arm64` rather than trusting "done".
- **No partial clones of FFmpeg.** git.ffmpeg.org doesn't support `--filter=blob:none`. With a
  second remote (`rpi`) git lazily fetches missing blobs from the wrong server (`not our ref`)
  and `format-patch` output is silently incomplete. Use full clones and fetches.
- **`git am --keep-cr`** is required for the rpi patches. Otherwise four `pi-util/` test-data
  files lose their CRLFs and the tree no longer matches the rpi branch.
- **The rpi branch has 39 commits but 38 patches.** One is a merge of tag `n9.0.2`, which
  `format-patch` skips. Verify with `git diff --quiet HEAD rpi/test/9.0.2/main`.
- **qemu needs the arm64 loader path:** `-L /usr/aarch64-linux-gnu` or `QEMU_LD_PREFIX`. The
  meson `exe_wrapper` and CMake `CROSSCOMPILING_EMULATOR` pass it explicitly. Without it,
  meson setup fails with "Executables created by c compiler ... are not runnable".
- **`env.sh` must stay POSIX.** It's sourced by `/bin/sh` scripts. Use `${BASH_SOURCE:-$0}`,
  not `${BASH_SOURCE[0]}`, which gives dash a "Bad substitution". Plain `sh` can't locate a
  sourced file, so it falls back to `./toolchain` (source it from the repo root).
- **srtla's Makefile hardcodes `CFLAGS`.** Override it on the make command line and keep
  `-DVERSION=\"$(VERSION)\"`, which `-v` prints.
- **Never `cmd | grep -q` under `pipefail`** (GitHub Actions' bash default). `grep -q` exits
  on the first match, ffmpeg gets SIGPIPE, and the step fails with 141, intermittently.
  Capture the output into a variable first, then match.
- **Shallow clones are fine; partial clones aren't.** CI uses `--depth 1` clones and by-SHA
  fetches, which GitHub supports, for FFmpeg, rpi-ffmpeg and srtla.
- **`deploy.sh` ssh options go before the host.** `ssh_pi [opts] -- command` exists for this.
  `-t` after the hostname becomes the remote command.

## CI

`.github/workflows/build.yml` reproduces the full pipeline in a `debian:trixie` container
(as root, so no sudo) and uploads `stage/` as a tarball artifact. Pinned inputs live in its
`env:` block: `FFMPEG_TAG`, `RPI_FFMPEG_SHA` (the rpi-ffmpeg commit `patches/` was exported
from) and `SRTLA_SHA`. Changing the FFmpeg version means re-exporting `patches/` **and**
bumping these, or the tree-identity check fails. Smoke tests check the staged install, not
`build/`.

## Pi 5 hardware facts

- Hardware **HEVC decode only**. No hardware H.264 decode and no hardware encoders, so the
  `*_v4l2m2m` encoders build but have no device on a Pi 5. Encode with `libx264`.
- Hardware decode test (on the Pi): `/usr/local/bin/ffmpeg -hwaccel drm -i in-hevc.mkv -f null -`

## Status (2026-11-17)

Verified on the host:
- Toolchain: gcc 14.2 cross compiler; plain gcc, meson and CMake builds all run under qemu (glibc 2.41).
- FFmpeg `n9.0.2-38-g8317055f0b9-rpi`: libx264, srt, `drm` hwaccel, vout_drm/egl present.
  A real libx264 test encode works under qemu.
- srtla `37862da`: both binaries build, depend only on libc, and `-v` works under qemu.
- `deploy.sh`: argument/stage guards, unreachable host, and arch/OS checks (via a fake ssh).

**Not yet verified:** an actual deploy to a Pi, hardware HEVC decode, the DRM/EGL output
devices, and srtla running on real links. The CI workflow hasn't run on GitHub yet. Its
fetch/patch, feature-check, smoke-test and package steps were run locally, but the shellcheck
job was never run (shellcheck isn't installed on the dev host).

## Conventions

- Shell scripts are POSIX `sh` with `set -eu`, run from anywhere (they resolve `TOP` from
  their own path), with environment-variable overrides documented in the header comment.
- Keep `README.md` in sync when changing steps. Mark anything not actually run as unverified.
- Tracked files: `README.md`, `AGENTS.md`, `LICENSE` (CC0 1.0), `.gitignore`, `.github/`, `toolchain/`, `test/`, and
  `patches/rpi-9.0.2/`. `.gitignore` excludes `src/` (downloaded) and the generated `build/`,
  `build-meson/`, `build-cmake/` and `stage/` directories. Don't commit inside `src/` unless asked.
- Nothing committed may contain machine-specific absolute paths. Scripts resolve paths from
  their own location, and the meson cross file uses `@DIRNAME@`.
- Licensing: this project's own files are CC0 1.0 (`LICENSE`, verbatim from creativecommons.org,
  never edit it). `patches/` stays under FFmpeg's LGPL/GPL. Built binaries are GPL (`--enable-gpl`
  + libx264). Don't add third-party code to CC0-covered paths.
