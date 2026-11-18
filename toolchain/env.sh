# Source this file: `. toolchain/env.sh`
# Cross-compile environment for Raspberry Pi 5 (Cortex-A76, Raspberry Pi OS Trixie / arm64).

export CROSS_TRIPLE=aarch64-linux-gnu
export CROSS_PREFIX=${CROSS_TRIPLE}-
export CC=${CROSS_PREFIX}gcc
export CXX=${CROSS_PREFIX}g++
export AR=${CROSS_PREFIX}ar
export NM=${CROSS_PREFIX}nm
export RANLIB=${CROSS_PREFIX}ranlib
export STRIP=${CROSS_PREFIX}strip

export RPI5_CPU_FLAGS="-mcpu=cortex-a76"
export CFLAGS="${RPI5_CPU_FLAGS} -O2"
export CXXFLAGS="${CFLAGS}"

# Resolve .pc files from multiarch arm64 dev packages only, never the host's.
# POSIX sh can't tell a sourced file its own path; fall back to sourcing from the repo root.
for _dir in "$(dirname "${BASH_SOURCE:-$0}")" ./toolchain; do
    if [ -x "$_dir/${CROSS_TRIPLE}-pkg-config" ]; then
        export PKG_CONFIG="$(cd "$_dir" && pwd)/${CROSS_TRIPLE}-pkg-config"
        break
    fi
done
unset _dir
[ -n "${PKG_CONFIG:-}" ] || echo "env.sh: can't find ${CROSS_TRIPLE}-pkg-config; source this from the repo root" >&2
export PKG_CONFIG_LIBDIR=/usr/lib/${CROSS_TRIPLE}/pkgconfig:/usr/share/pkgconfig
unset PKG_CONFIG_PATH

# Lets qemu-aarch64 find the arm64 dynamic loader for running test binaries.
export QEMU_LD_PREFIX=/usr/${CROSS_TRIPLE}
