#!/bin/sh
# Builds test/hello.c for the Pi 5 and runs it under qemu.
set -eu
cd "$(dirname "$0")/.."
. toolchain/env.sh
mkdir -p build
$CC $CFLAGS -o build/hello test/hello.c
file build/hello
qemu-aarch64 build/hello
