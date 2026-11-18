#!/bin/sh
# Configures the rpi-patched FFmpeg tree for a Raspberry Pi 5 (Pi OS Trixie, arm64) cross build.
# Mirrors pi-util/conf_native.sh's Pi feature set, plus libx264 and libsrt.
#
# Usage: toolchain/configure-ffmpeg.sh [extra configure args...]
#   PREFIX   install prefix on the Pi (default /usr/local)
#   BUILDDIR out-of-tree build directory (default build/ffmpeg-arm64)
# Then: make -C "$BUILDDIR" -j$(nproc) && make -C "$BUILDDIR" install DESTDIR=$PWD/stage
set -eu

TOP=$(cd "$(dirname "$0")/.." && pwd)
SRC=$TOP/src/ffmpeg
PREFIX=${PREFIX:-/usr/local}
BUILDDIR=${BUILDDIR:-$TOP/build/ffmpeg-arm64}
CROSS=aarch64-linux-gnu

mkdir -p "$BUILDDIR"
cd "$BUILDDIR"

"$SRC/configure" \
    --enable-cross-compile \
    --target-os=linux \
    --arch=aarch64 \
    --cpu=cortex-a76 \
    --cross-prefix=$CROSS- \
    --pkg-config="$TOP/toolchain/$CROSS-pkg-config" \
    --prefix="$PREFIX" \
    --libdir="$PREFIX/lib/$CROSS" \
    --incdir="$PREFIX/include/$CROSS" \
    --enable-shared \
    --disable-static \
    --enable-gpl \
    --enable-sand \
    --enable-v4l2-request \
    --enable-libdrm \
    --enable-libudev \
    --enable-epoxy \
    --enable-xlib \
    --enable-vout-drm \
    --enable-vout-egl \
    --enable-libx264 \
    --enable-libsrt \
    --extra-version=rpi \
    "$@"
