#!/bin/sh
# Cross-compiles BELABOX srtla (srtla_send, srtla_rec) for the Raspberry Pi 5 and installs
# both binaries into stage/$PREFIX/bin alongside the FFmpeg build, ready for deploy.sh.
#
# Usage: toolchain/build-srtla.sh
#   PREFIX  install prefix; must match deploy.sh (default /usr/local)
set -eu

TOP=$(cd "$(dirname "$0")/.." && pwd)
SRC=$TOP/src/srtla
PREFIX=${PREFIX:-/usr/local}
BINDIR=$TOP/stage$PREFIX/bin

[ -f "$SRC/Makefile" ] || {
    echo "srtla source not found. Run: git clone https://github.com/BELABOX/srtla $SRC" >&2
    exit 1
}

. "$TOP/toolchain/env.sh"

# srtla's Makefile hardcodes CFLAGS (including -DVERSION from the git hash), so override it
# on the command line and keep VERSION; $(VERSION) is expanded by make, not the shell.
make -C "$SRC" clean
make -C "$SRC" CC="$CC" CFLAGS="$CFLAGS -g -Wall -DVERSION=\\\"\$(VERSION)\\\"" srtla_send srtla_rec

mkdir -p "$BINDIR"
for bin in srtla_send srtla_rec; do
    $STRIP -o "$BINDIR/$bin" "$SRC/$bin"
    echo "installed $BINDIR/$bin"
done
