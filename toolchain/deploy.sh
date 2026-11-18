#!/bin/sh
# Deploys the staged FFmpeg and srtla builds (stage/$PREFIX) to a Raspberry Pi 5 over ssh.
#
# Usage: toolchain/deploy.sh [user@]host
#   PREFIX  install prefix; must match the one used by configure-ffmpeg.sh (default /usr/local)
#   SSH     extra ssh options, e.g. SSH="-p 2222 -i ~/.ssh/pi"
#   ALLOW_ANY_OS=1  deploy even if the Pi is not running trixie
#
# Requires on the Pi: ssh access and sudo. Installs the runtime library packages FFmpeg
# links against, copies the files into $PREFIX, runs ldconfig and smoke-tests the result.
set -eu

[ $# -eq 1 ] || { echo "usage: $0 [user@]host" >&2; exit 2; }
HOST=$1
TOP=$(cd "$(dirname "$0")/.." && pwd)
PREFIX=${PREFIX:-/usr/local}
STAGE=$TOP/stage$PREFIX
LIBDIR=$PREFIX/lib/aarch64-linux-gnu
REMOTE_TMP=/tmp/ffmpeg-rpi-deploy

# Runtime packages for the libraries the build links against (from readelf NEEDED, Trixie names).
PKGS="libdrm2 libepoxy0 libsrt1.5-gnutls libudev1 libx11-6 libx264-164 libxcb1 libxext6 libxv1"

[ -x "$STAGE/bin/ffmpeg" ] || {
    echo "No staged build in $STAGE. Run: make -C build/ffmpeg-arm64 install DESTDIR=$TOP/stage" >&2
    exit 1
}
for bin in srtla_send srtla_rec; do
    [ -x "$STAGE/bin/$bin" ] || { echo "No staged $bin in $STAGE/bin. Run: toolchain/build-srtla.sh" >&2; exit 1; }
done

# Share one connection so ssh asks for a password at most once.
CTL=$(mktemp -u "${TMPDIR:-/tmp}/ffmpeg-rpi-ssh.XXXXXX")
# ssh_pi [ssh options...] -- command
ssh_pi() {
    opts=
    while [ $# -gt 0 ] && [ "$1" != -- ]; do opts="$opts $1"; shift; done
    shift
    ssh -o ControlMaster=auto -o ControlPath="$CTL" -o ControlPersist=60 ${SSH:-} $opts "$HOST" "$@"
}
trap 'ssh -o ControlPath="$CTL" -O exit "$HOST" 2>/dev/null || true' EXIT

echo "==> Checking $HOST"
ssh_pi -- 'echo "$(uname -m) $(. /etc/os-release; echo $VERSION_CODENAME)"' | {
    read -r arch codename
    [ "$arch" = aarch64 ] || { echo "error: $HOST is $arch, not aarch64 (64-bit Pi OS required)" >&2; exit 1; }
    [ "$codename" = trixie ] || [ -n "${ALLOW_ANY_OS:-}" ] || {
        echo "error: $HOST runs '$codename'; this build targets trixie (glibc 2.41) and will not run on older releases. Set ALLOW_ANY_OS=1 to override." >&2
        exit 1
    }
}

echo "==> Copying $(du -sh "$STAGE" | cut -f1) to $HOST:$REMOTE_TMP"
tar -C "$STAGE" -cf - . | ssh_pi -- "rm -rf $REMOTE_TMP && mkdir -p $REMOTE_TMP/root && tar -C $REMOTE_TMP/root -xf -"

ssh_pi -- "cat > $REMOTE_TMP/install.sh" <<EOF
set -eu
echo "==> Installing runtime packages"
apt-get update -q
apt-get install -y --no-install-recommends $PKGS
echo "==> Installing into $PREFIX"
mkdir -p "$PREFIX"
cp -a $REMOTE_TMP/root/. "$PREFIX/"
case "$LIBDIR" in
    /usr/local/lib/aarch64-linux-gnu) ;;  # already in Debian's default linker path
    *) echo "$LIBDIR" > /etc/ld.so.conf.d/ffmpeg-rpi.conf ;;
esac
ldconfig
rm -rf $REMOTE_TMP
EOF

echo "==> Installing on $HOST (sudo may prompt for a password)"
ssh_pi -t -- "sudo sh $REMOTE_TMP/install.sh"

echo "==> Verifying"
ssh_pi -- "set -e
    missing=\$(ldd $PREFIX/bin/ffmpeg | grep 'not found' || true)
    [ -z \"\$missing\" ] || { echo \"error: unresolved libraries:\"; echo \"\$missing\"; exit 1; }
    $PREFIX/bin/ffmpeg -hide_banner -version | head -1
    echo \"hwaccels: \$($PREFIX/bin/ffmpeg -hide_banner -hwaccels | tail -n +2 | xargs)\"
    $PREFIX/bin/ffmpeg -hide_banner -encoders | grep -q libx264 && echo 'libx264: ok'
    $PREFIX/bin/ffmpeg -hide_banner -protocols | grep -qw srt && echo 'srt: ok'
    for bin in srtla_send srtla_rec; do echo \"\$bin: \$($PREFIX/bin/\$bin -v)\"; done
    resolved=\$(command -v ffmpeg || true)
    [ \"\$resolved\" = $PREFIX/bin/ffmpeg ] || echo \"warning: 'ffmpeg' on PATH is \$resolved; use $PREFIX/bin/ffmpeg\""

echo "==> Deployed to $HOST:$PREFIX"
