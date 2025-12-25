#!/bin/sh
################################################################################
# minidlna-arm-static.sh
#
# Raspberry Pi build script for a statically linked version of MiniDLNA media
# server, capable of running on any ARMv7 Linux device.
#
# MiniDLNA (also known as ReadyMedia) is a lightweight, simple-to-configure
# media server that implements the DLNA/UPnP-AV standard. It allows you to
# stream music, videos, and photos from a Linux-based device, such as a
# Raspberry Pi, to DLNA-compatible clients like smart TVs, game consoles, or
# media players.
#
# NOTE: Compiling MiniDLNA (and especially FFmpeg) on a Raspberry Pi can
# generate significant heat, often exceeding 80°C in stock cases. Upgrading to
# an aluminum case with copper shims and good thermal paste provides effective
# passive cooling that dramatically improves heat dissipation, keeping CPU
# temperatures below 50°C and preventing thermal throttling during long builds.
#
# Copyright (C) 2025 Richard Elwell
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <https://www.gnu.org/licenses/>.
#
################################################################################
PATH_CMD="$(readlink -f -- "$0")"
SCRIPT_DIR="$(dirname -- "$(readlink -f -- "$0")")"
PARENT_DIR="$(dirname -- "$(dirname -- "$(readlink -f -- "$0")")")"
set -e
set -x

################################################################################
# Checksum verification for downloaded file

check_sha256() {
    file="$1"
    expected="$2"

    if [ ! -f "$file" ]; then
        echo "ERROR: File not found: $file"
        return 1
    fi

    actual="$(sha256sum "$file" | awk '{print $1}')"

    if [ "$actual" != "$expected" ]; then
        echo "ERROR: SHA256 mismatch for $file"
        echo "Expected: $expected"
        echo "Actual:   $actual"
        return 1
    fi

    echo "SHA256 OK: $file"
    return 0
}

################################################################################
# Install the build environment, if it is not already installed

TOMATOWARE_URL="https://github.com/lancethepants/tomatoware/releases/download/v5.0/arm-soft-mmc.tgz"
TOMATOWARE_SHA256="ff490819a16f5ddb80ec095342ac005a444b6ebcd3ed982b8879134b2b036fcc"
TOMATOWARE_PKG="arm-soft-mmc-5.0.tgz"
TOMATOWARE_DIR="tomatoware-5.0"
TOMATOWARE_PATH="$PARENT_DIR/$TOMATOWARE_DIR"
TOMATOWARE_SYSROOT="/mmc" # or, whatever your tomatoware distribution uses for sysroot

# Check if Tomatoware exists and install it, if needed
if [ ! -d "$TOMATOWARE_PATH" ]; then
    echo "Tomatoware not found at $TOMATOWARE_PATH. Installing..."
    echo ""
    cd $PARENT_DIR
    if [ ! -f "$TOMATOWARE_PKG" ]; then
        PKG_TMP=$(mktemp "$TOMATOWARE_PKG.XXXXXX")
        trap '[ -n "$PKG_TMP" ] && rm -f "$PKG_TMP"' EXIT INT TERM
        wget -O "$PKG_TMP" "$TOMATOWARE_URL"
        mv -f "$PKG_TMP" "$TOMATOWARE_PKG"
        trap - EXIT INT TERM
    fi

    check_sha256 "$TOMATOWARE_PKG" "$TOMATOWARE_SHA256"

    DIR_TMP=$(mktemp -d "$TOMATOWARE_DIR.XXXXXX")
    trap '[ -n "$DIR_TMP" ] && rm -rf "$DIR_TMP"' EXIT INT TERM
    mkdir -p "$DIR_TMP"
    tar xzvf "$TOMATOWARE_PKG" -C "$DIR_TMP"
    mv -f "$DIR_TMP" "$TOMATOWARE_DIR"
    trap - EXIT INT TERM
fi

# Check if /mmc exists and is a symbolic link
if [ ! -L "$TOMATOWARE_SYSROOT" ] && ! grep -q " $TOMATOWARE_SYSROOT " /proc/mounts; then
    echo "Tomatoware $TOMATOWARE_SYSROOT is missing or is not a symbolic link."
    echo ""
    # try making a symlink
    if ! sudo ln -sfn "$TOMATOWARE_PATH" "$TOMATOWARE_SYSROOT"; then
        # otherwise, we are probably on a read-only filesystem and
        # the sysroot needs to be already baked into the firmware and
        # not in use by something else.
        # alternatively, you can figure out another sysroot to use.
        mount -o bind "$TOMATOWARE_PATH" "$TOMATOWARE_SYSROOT"
    fi
fi

# Check for required Tomatoware tools
if [ ! -x "$TOMATOWARE_SYSROOT/bin/gcc" ] || [ ! -x "$TOMATOWARE_SYSROOT/bin/make" ]; then
    echo "ERROR: Tomatoware installation appears incomplete."
    echo "Missing gcc or make in $TOMATOWARE_SYSROOT/bin."
    echo ""
    exit 1
fi

# Check shell
if [ "$BASH" != "$TOMATOWARE_SYSROOT/bin/bash" ]; then
    if [ -z "$TOMATOWARE_SHELL" ]; then
        export TOMATOWARE_SHELL=1
        exec "$TOMATOWARE_SYSROOT/bin/bash" "$PATH_CMD" "$@"
    else
        echo "ERROR: Not Tomatoware shell: $(readlink /proc/$$/exe)"
        echo ""
        exit 1
    fi
fi

# ---- From here down, you are running under /mmc/bin/bash ----
echo "Now running under: $(readlink /proc/$$/exe)"

################################################################################
# General

PKG_ROOT=minidlna
#REBUILD_ALL=1
SRC="$TOMATOWARE_SYSROOT/src/$PKG_ROOT"
mkdir -p "$SRC"
MAKE="make -j$(grep -c ^processor /proc/cpuinfo)" # parallelism
#MAKE="make -j1"                                  # one job at a time
export PATH="$TOMATOWARE_SYSROOT/usr/bin:$TOMATOWARE_SYSROOT/usr/local/sbin:$TOMATOWARE_SYSROOT/usr/local/bin:$TOMATOWARE_SYSROOT/usr/sbin:$TOMATOWARE_SYSROOT/sbin:$TOMATOWARE_SYSROOT/bin"
#export PKG_CONFIG_PATH="$TOMATOWARE_SYSROOT/lib/pkgconfig"
#export PKG_CONFIG="pkg-config --static"

# If Autoconf/configure fails due to missing libraries or undefined symbols, you
# immediately see all undefined references without having to manually search config.log
handle_configure_error() {
    local rc=$1
    #grep -R --include="config.log" --color=always "undefined reference" .
    find . -name "config.log" -exec grep -H "undefined reference" {} \;
    exit $rc
}

################################################################################
# libogg-1.3.6

PKG_MAIN=libogg
mkdir -p "$SRC/$PKG_MAIN" && cd "$SRC/$PKG_MAIN"
DL="libogg-1.3.6.tar.gz"
DL_SHA256="83e6704730683d004d20e21b8f7f55dcb3383cdf84c0daedf30bde175f774638"
FOLDER="${DL%.tar.gz*}"
URL="https://ftp.osuosl.org/pub/xiph/releases/ogg/$DL"

if [ "$REBUILD_ALL" == "1" ]; then
    if [ -f "$FOLDER/Makefile" ]; then
        cd "$FOLDER" && make uninstall && cd ..
    fi || true
    rm -rf "$FOLDER"
fi || true

if [ ! -f "$FOLDER/__package_installed" ]; then
    [ ! -f "$DL" ] && wget "$URL"

    check_sha256 "$DL" "$DL_SHA256"

    [ ! -d "$FOLDER" ] && tar xzvf "$DL"
    cd "$FOLDER"

    ./configure \
        --enable-static \
        --disable-shared \
        --prefix="$TOMATOWARE_SYSROOT" \
    || handle_configure_error $?

    $MAKE
    make install

    touch __package_installed
fi

################################################################################
# libvorbis-1.3.7

PKG_MAIN=libvorbis
mkdir -p "$SRC/$PKG_MAIN" && cd "$SRC/$PKG_MAIN"
DL="libvorbis-1.3.7.tar.gz"
DL_SHA256="0e982409a9c3fc82ee06e08205b1355e5c6aa4c36bca58146ef399621b0ce5ab"
FOLDER="${DL%.tar.gz*}"
URL="https://ftp.osuosl.org/pub/xiph/releases/vorbis/libvorbis-1.3.7.tar.gz"

if [ "$REBUILD_ALL" == "1" ]; then
    if [ -f "$FOLDER/Makefile" ]; then
        cd "$FOLDER" && make uninstall && cd ..
    fi || true
    rm -rf "$FOLDER"
fi || true

if [ ! -f "$FOLDER/__package_installed" ]; then
    [ ! -f "$DL" ] && wget "$URL"

    check_sha256 "$DL" "$DL_SHA256"

    [ ! -d "$FOLDER" ] && tar xzvf "$DL"
    cd "$FOLDER"

    ./configure \
        --enable-static \
        --disable-shared \
        --disable-oggtest \
        --prefix="$TOMATOWARE_SYSROOT" \
    || handle_configure_error $?

    $MAKE
    make install

    touch __package_installed
fi

################################################################################
# flac-1.5.0

PKG_MAIN=flac
mkdir -p "$SRC/$PKG_MAIN" && cd "$SRC/$PKG_MAIN"
DL="flac-1.5.0.tar.xz"
DL_SHA256="f2c1c76592a82ffff8413ba3c4a1299b6c7ab06c734dee03fd88630485c2b920"
FOLDER="${DL%.tar.xz*}"
URL="https://ftp.osuosl.org/pub/xiph/releases/flac/$DL"

if [ "$REBUILD_ALL" == "1" ]; then
    if [ -f "$FOLDER/Makefile" ]; then
        cd "$FOLDER" && make uninstall && cd ..
    fi || true
    rm -rf "$FOLDER"
fi || true

if [ ! -f "$FOLDER/__package_installed" ]; then
    [ ! -f "$DL" ] && wget "$URL"

    check_sha256 "$DL" "$DL_SHA256"

    [ ! -d "$FOLDER" ] && tar xJvf "$DL"
    cd "$FOLDER"

    ./configure \
        --enable-static \
        --disable-shared \
        --disable-rpath \
        --disable-doxygen-docs \
        --disable-cpplibs \
        --disable-avx \
        --disable-stack-smash-protection \
        --disable-oggtest \
        --disable-examples \
        --without-libiconv-prefix \
        --prefix="$TOMATOWARE_SYSROOT" \
    || handle_configure_error $?

    $MAKE
    make install

    touch __package_installed
fi

################################################################################
# libid3tag-0.15.1b

PKG_MAIN=libid3tag
mkdir -p "$SRC/$PKG_MAIN" && cd "$SRC/$PKG_MAIN"
DL="libid3tag-0.15.1b.tar.gz"
DL_SHA256="63da4f6e7997278f8a3fef4c6a372d342f705051d1eeb6a46a86b03610e26151"
FOLDER="libid3tag-0.15.1b"
URL="https://downloads.sourceforge.net/project/mad/libid3tag/0.15.1b/$DL"

if [ "$REBUILD_ALL" == "1" ]; then
    if [ -f "$FOLDER/Makefile" ]; then
        cd "$FOLDER" && make uninstall && cd ..
    fi || true
    rm -rf "$FOLDER"
fi || true

if [ ! -f "$FOLDER/__package_installed" ]; then
    [ ! -f "$DL" ] && wget "$URL"

    check_sha256 "$DL" "$DL_SHA256"

    [ ! -d "$FOLDER" ] && tar xzvf "$DL"
    cd "$FOLDER"

    ./configure \
        --enable-static \
        --disable-shared \
        --disable-rpath \
        --disable-debugging \
        --disable-profiling \
        --disable-dependency-tracking \
        --prefix="$TOMATOWARE_SYSROOT" \
    || handle_configure_error $?

    $MAKE
    make install

    touch __package_installed
fi

################################################################################
# libexif-0.6.25

PKG_MAIN=libexif
mkdir -p "$SRC/$PKG_MAIN" && cd "$SRC/$PKG_MAIN"
DL="libexif-0.6.25.tar.gz"
DL_SHA256="16fdfa59cf9d301a9ccd5c1bc2fe05c78ee0ee2bf96e39640039e3dc0fd593cb"
FOLDER="${DL%.tar.gz*}"
URL="https://github.com/libexif/libexif/releases/download/v0.6.25/$DL"

if [ "$REBUILD_ALL" == "1" ]; then
    if [ -f "$FOLDER/Makefile" ]; then
        cd "$FOLDER" && make uninstall && cd ..
    fi || true
    rm -rf "$FOLDER"
fi || true

if [ ! -f "$FOLDER/__package_installed" ]; then
    [ ! -f "$DL" ] && wget "$URL"

    check_sha256 "$DL" "$DL_SHA256"

    [ ! -d "$FOLDER" ] && tar xzvf "$DL"
    cd "$FOLDER"

    ./configure \
        --enable-static \
        --disable-shared \
        --disable-nls \
        --disable-docs \
        --disable-rpath \
        --without-libiconv-prefix \
        --without-libintl-prefix \
        --prefix="$TOMATOWARE_SYSROOT" \
    || handle_configure_error $?

    $MAKE
    make install

    touch __package_installed
fi

################################################################################
# jpeg-9f

PKG_MAIN=jpeg
mkdir -p "$SRC/$PKG_MAIN" && cd "$SRC/$PKG_MAIN"
DL="jpegsrc.v9f.tar.gz"
DL_SHA256="04705c110cb2469caa79fb71fba3d7bf834914706e9641a4589485c1f832565b"
FOLDER="jpeg-9f"
URL="https://www.ijg.org/files/$DL"

if [ "$REBUILD_ALL" == "1" ]; then
    if [ -f "$FOLDER/Makefile" ]; then
        cd "$FOLDER" && make uninstall && cd ..
    fi || true
    rm -rf "$FOLDER"
fi || true

if [ ! -f "$FOLDER/__package_installed" ]; then
    [ ! -f "$DL" ] && wget "$URL"

    check_sha256 "$DL" "$DL_SHA256"

    [ ! -d "$FOLDER" ] && tar xzvf "$DL"
    cd "$FOLDER"

    ./configure \
        --enable-static \
        --disable-shared \
        --enable-maxmem=1 \
        --prefix="$TOMATOWARE_SYSROOT" \
    || handle_configure_error $?

    $MAKE
    make install

    touch __package_installed
fi

################################################################################
# ffmpeg-6.1.2

PKG_MAIN=ffmpeg
mkdir -p "$SRC/$PKG_MAIN" && cd "$SRC/$PKG_MAIN"
DL="ffmpeg-6.1.2.tar.gz"
DL_SHA256="def310d21e40c39e6971a6bcd07fba78ca3ce39cc01ffda4dca382599dc06312"
FOLDER="${DL%.tar.gz*}"
URL="https://ffmpeg.org/releases/$DL"

ffmpeg_options() {
    local name="$1"
    local values="$2"
    for value in $values; do
        printf "%s=%s " $name $value
    done
    #printf "\n"
}

if [ "$REBUILD_ALL" == "1" ]; then
    if [ -f "$FOLDER/Makefile" ]; then
        cd "$FOLDER" && make uninstall && cd ..
    fi || true
    rm -rf "$FOLDER"
fi || true

if [ ! -f "$FOLDER/__package_installed" ]; then
    [ ! -f "$DL" ] && wget "$URL"

    check_sha256 "$DL" "$DL_SHA256"

    [ ! -d "$FOLDER" ] && tar xzvf "$DL"
    cd "$FOLDER"

    FFMPEG_DECODERS="aac ac3 atrac3 h264 jpegls mp3 mpeg1video mpeg2video mpeg4 mpegvideo png wmav1 wmav2 svq3"
    FFMPEG_PARSERS="aac ac3 h264 mpeg4video mpegaudio mpegvideo"
    FFMPEG_PROTOCOLS="file"
    FFMPEG_DISABLED_DEMUXERS="amr apc ape ass bethsoftvid bfi c93 daud dnxhd dsicin dxa gsm gxf idcin iff image2 image2pipe ingenient ipmovie lmlm4 mm mmf msnwc_tcp mtv mxf nsv nut oma pva rawvideo rl2 roq rpl segafilm shorten siff smacker sol str thp tiertexseq tta txd vmd voc wc3 wsaud wsvqa xa yuv4mpegpipe"

    ./configure \
        --arch=arm --cpu=cortex-a9 --disable-neon --disable-vfp --target-os=linux \
        --enable-static --disable-shared --disable-doc \
        --enable-gpl --enable-version3 --enable-nonfree \
        --enable-pthreads --enable-small --disable-encoders --disable-filters \
        --disable-muxers --disable-devices --disable-ffmpeg --disable-ffplay \
        --disable-ffprobe --disable-avdevice --disable-swscale \
        --disable-hwaccels --disable-network --disable-bsfs \
        --enable-demuxers $(ffmpeg_options "--disable-demuxer" "$FFMPEG_DISABLED_DEMUXERS") \
        --disable-decoders $(ffmpeg_options "--enable-decoder" "$FFMPEG_DECODERS") \
        --disable-parsers $(ffmpeg_options "--enable-parser" "$FFMPEG_PARSERS") \
        --disable-protocols $(ffmpeg_options "--enable-protocol" "$FFMPEG_PROTOCOLS") \
        --disable-avfilter \
        --enable-zlib --disable-debug \
        --disable-rpath \
        --prefix="$TOMATOWARE_SYSROOT" \
    || handle_configure_error $?

    $MAKE
    make install

    touch __package_installed
fi

################################################################################
# minidlna-1.3.3

PKG_MAIN=minidlna
mkdir -p "$SRC/$PKG_MAIN" && cd "$SRC/$PKG_MAIN"
DL="minidlna-1.3.3.tar.gz"
DL_SHA256="39026c6d4a139b9180192d1c37225aa3376fdf4f1a74d7debbdbb693d996afa4"
FOLDER="${DL%.tar.gz*}"
URL="https://downloads.sourceforge.net/project/minidlna/minidlna/1.3.3/$DL"

if [ "$REBUILD_ALL" == "1" ]; then
    if [ -f "$FOLDER/Makefile" ]; then
        cd "$FOLDER" && make uninstall && cd ..
    fi || true
    rm -rf "$FOLDER"
fi || true

if [ ! -f "$FOLDER/__package_installed" ]; then
    [ ! -f "$DL" ] && wget "$URL"

    check_sha256 "$DL" "$DL_SHA256"

    [ ! -d "$FOLDER" ] && tar xzvf "$DL"
    cd "$FOLDER"

    LIBS="-lbz2" \
    ./configure \
        --enable-static \
        --disable-rpath \
        --disable-nls \
        --disable-silent-rules \
        --prefix="$TOMATOWARE_SYSROOT" \
    || handle_configure_error $?

    $MAKE
    make install

    # Strip removes debug symbols and other metadata
    [ -f "$TOMATOWARE_SYSROOT/sbin/minidlnad" ] && strip "$TOMATOWARE_SYSROOT/sbin/minidlnad"

    touch __package_installed
fi

