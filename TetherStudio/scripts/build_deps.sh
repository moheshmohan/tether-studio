#!/bin/bash
# Builds the C libraries the app bundles (libusb, libltdl and libgphoto2 with its PTP driver only)
# from source for macOS 13 and later, into .deps/prefix. Homebrew's own builds are made for the newest
# macOS only, so an app bundling them would not open on older systems.
#
# The source archives are taken from dist/sources/ (put them there yourself), or else from Homebrew's
# download cache (`brew fetch --build-from-source libgphoto2 libusb libtool`). The same archives are
# what make_dmg.sh attaches to a release, so the sources shipped are exactly the ones built.
#
#   scripts/build_deps.sh            then  scripts/make_app.sh  (uses .deps/prefix when it is there)
set -euo pipefail
cd "$(dirname "$0")/.."

export MACOSX_DEPLOYMENT_TARGET=13.0
DEPS="$PWD/.deps"
PREFIX="$DEPS/prefix"
SRC="$DEPS/src"
mkdir -p "$PREFIX" "$SRC" dist/sources
CACHE="$(brew --cache 2>/dev/null || echo "$HOME/Library/Caches/Homebrew")/downloads"

archive() {     # name → path of its source archive, copied into dist/sources/ under its plain name
    local name="$1" found
    found="$(ls dist/sources/"$name"-[0-9]*.tar.* 2>/dev/null | head -1 || true)"
    if [[ -z "$found" ]]; then
        found="$(ls "$CACHE"/*--"$name"-[0-9]*.tar.* 2>/dev/null | sort | tail -1 || true)"
        [[ -n "$found" ]] || { echo "error: no source archive for $name (brew fetch --build-from-source $name)" >&2; exit 1; }
        local plain; plain="$(basename "$found")"; plain="${plain#*--}"
        cp "$found" "dist/sources/$plain"
        found="dist/sources/$plain"
    fi
    echo "$PWD/$found"
}

unpack() {      # archive → its unpacked folder
    local a="$1" dir
    dir="$SRC/$(basename "$a" | sed -E 's/\.tar\.(gz|bz2|xz)$//')"
    rm -rf "$dir"
    tar -xf "$a" -C "$SRC"
    echo "$dir"
}

CFLAGS="-O2 -arch arm64 -mmacosx-version-min=$MACOSX_DEPLOYMENT_TARGET"
export CFLAGS LDFLAGS="-arch arm64 -mmacosx-version-min=$MACOSX_DEPLOYMENT_TARGET"
export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig"
JOBS="$(sysctl -n hw.ncpu)"

echo "==> libusb"
d="$(unpack "$(archive libusb)")"
(cd "$d" && ./configure --prefix="$PREFIX" --disable-static --quiet && make -s -j"$JOBS" && make -s install)

echo "==> libltdl (from libtool)"
d="$(unpack "$(archive libtool)")"
(cd "$d" && ./configure --prefix="$PREFIX" --enable-ltdl-install --disable-static --quiet && make -s -j"$JOBS" && make -s install)

echo "==> libgphoto2 (PTP driver; PTP/IP, USB and disk ports)"
d="$(unpack "$(archive libgphoto2)")"
(cd "$d" && ./configure --prefix="$PREFIX" --disable-static --disable-nls --quiet \
    --with-camlibs=ptp2 --with-libltdl-prefix="$PREFIX" \
    --without-libexif --without-jpeg --without-libxml-2.0 --without-libcurl --without-gdlib \
    LTDLINCL="-I$PREFIX/include" LIBLTDL="-L$PREFIX/lib -lltdl" \
    && make -s -j"$JOBS" && make -s install)

echo "==> built into $PREFIX for macOS $MACOSX_DEPLOYMENT_TARGET and later:"
ls "$PREFIX"/lib/*.dylib "$PREFIX"/lib/libgphoto2/*/*.so "$PREFIX"/lib/libgphoto2_port/*/*.so
