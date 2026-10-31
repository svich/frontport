#!/bin/bash
# Frontport Recipe: perfect_dark (fgsfdsfgs/perfect_dark), a Perfect Dark port built from its decompilation.
# Contract: catalog/recipes/README.md. Invoked as `perfect-dark.sh fetch`, then `perfect-dark.sh build`.
#
# Upstream publishes only a rolling CI build, with SDL2.framework loose beside a bare executable, so this
# builds the `port` branch at a pinned commit against a static SDL2 and wraps it in a minimal app.
#
# Build Assets: the NTSC 1.1 ROM itself, left at $FRONTPORT_OUT/assets for the Catalog's buildAssets.path
# "Contents/Resources/data/pd.ntsc-final.z64". The port reads levels, models and sound from the ROM at run
# time. It looks for `data` in the folder SDL_GetBasePath names, which in an app bundle is
# Contents/Resources, and keeps pd.ini and saves where SDL_GetPrefPath("", "perfectdark") points,
# ~/Library/Application Support/perfectdark, which the App Sandbox puts in the container. So no patches.
set -euo pipefail

step=${1:?usage: perfect-dark.sh fetch|build}
src=$FRONTPORT_SRC
work=$(dirname "$src")
deps=$src/deps
pd=$src/perfect_dark
prefix=$work/prefix
deployment_target=13.0
export MACOSX_DEPLOYMENT_TARGET=$deployment_target
export GIT_CEILING_DIRECTORIES=$work

dependencies="
sdl2 5f5993c530f084535c65a6879e9b26ad441169b3e25d789d83287040a9ca5165 https://github.com/libsdl-org/SDL/releases/download/release-2.32.10/SDL2-2.32.10.tar.gz
"

fail() {
    echo "error: $*" >&2
    exit 1
}

fetch() {
    echo "==> Fetching perfect_dark $FRONTPORT_REF"
    # The ref is a commit; its tools/recomp submodule only builds the N64 ROM, so it's left out.
    git init --quiet "$pd"
    git -C "$pd" fetch --quiet --depth 1 https://github.com/fgsfdsfgs/perfect_dark.git "$FRONTPORT_REF"
    git -C "$pd" -c advice.detachedHead=false checkout --quiet FETCH_HEAD
    [ "$(git -C "$pd" rev-parse HEAD)" = "$FRONTPORT_REF" ] || fail "fetched $(git -C "$pd" rev-parse HEAD), not $FRONTPORT_REF"

    mkdir -p "$deps"
    local name sha url file
    while read -r name sha url; do
        [ -n "$name" ] || continue
        echo "==> Downloading $name"
        file=$deps/$name.download
        curl -fsSL --retry 3 -o "$file" "$url"
        echo "$sha  $file" | shasum -a 256 -c --status - || fail "$name doesn't match its pinned sha256"
        mkdir -p "$deps/$name"
        tar -xf "$file" -C "$deps/$name" --strip-components=1
        rm "$file"
    done <<<"$dependencies"
}

build_sdl2() {
    local stamp=$prefix/.frontport-libraries
    local wanted
    wanted=$(echo "$dependencies $deployment_target" | shasum -a 256 | cut -d' ' -f1)
    if [ -f "$stamp" ] && [ "$(cat "$stamp")" = "$wanted" ]; then
        echo "==> Reusing SDL2 in $prefix"
        return
    fi
    rm -rf "$prefix" "$work/sdl2-build"
    echo "==> Building SDL2"
    cmake -S "$deps/sdl2" -B "$work/sdl2-build" -G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_ARCHITECTURES=arm64 \
        -DCMAKE_OSX_DEPLOYMENT_TARGET=$deployment_target -DCMAKE_INSTALL_PREFIX="$prefix" \
        -DSDL_SHARED=OFF -DSDL_STATIC=ON -DSDL_TEST=OFF
    cmake --build "$work/sdl2-build" -j "$FRONTPORT_JOBS"
    cmake --install "$work/sdl2-build"
    echo "$wanted" >"$stamp"
}

build() {
    build_sdl2

    echo "==> Building perfect_dark"
    # Upstream's FindSDL2 links SDL2 with Cocoa alone, which a static SDL2 isn't enough for, so it gets
    # the library and the system libraries and frameworks sdl2-config lists. Only the -l and -Wl, flags
    # are kept: the -L path has a space in it ("Application Support") and splits.
    local sdl_libs=$prefix/lib/libSDL2.a flag
    for flag in $("$prefix/bin/sdl2-config" --static-libs); do
        case "$flag" in
            -lSDL2) ;;
            -l* | -Wl,*) sdl_libs+=";$flag" ;;
        esac
    done
    cmake -S "$pd" -B "$work/build" -G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_ARCHITECTURES=arm64 \
        -DCMAKE_OSX_DEPLOYMENT_TARGET=$deployment_target -DROMID=ntsc-final \
        -DSDL2_INCLUDE_DIR="$prefix/include/SDL2" -DSDL2_LIBRARY="$sdl_libs"
    cmake --build "$work/build" --target pd -j "$FRONTPORT_JOBS"

    echo "==> Making Perfect Dark.app"
    local app="$FRONTPORT_OUT/Perfect Dark.app" plist build
    plist=$app/Contents/Info.plist
    build=$(git -C "$pd" rev-parse --short HEAD)
    mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources/data"
    cp "$work/build/pd.arm64" "$app/Contents/MacOS/pd"
    make_icns "$pd/dist/linux/io.github.perfect_dark_pc_port.perfect_dark.png" "$app/Contents/Resources/pd.icns"
    cp "$pd/dist/nswitch/gamecontrollerdb.txt" "$app/Contents/Resources/gamecontrollerdb.txt"
    plutil -create xml1 "$plist"
    plutil -insert CFBundleExecutable -string pd "$plist"
    plutil -insert CFBundleIdentifier -string "dev.frontport.port.$FRONTPORT_PORT" "$plist"
    plutil -insert CFBundleName -string "Perfect Dark" "$plist"
    plutil -insert CFBundleIconFile -string pd "$plist"
    plutil -insert CFBundlePackageType -string APPL "$plist"
    plutil -insert CFBundleInfoDictionaryVersion -string 6.0 "$plist"
    plutil -insert CFBundleShortVersionString -string 0.0 "$plist"
    plutil -insert CFBundleVersion -string 0.0 "$plist"
    plutil -insert CFBundleGetInfoString -string "port ($build)" "$plist"
    plutil -insert LSMinimumSystemVersion -string "$deployment_target" "$plist"
    plutil -insert LSApplicationCategoryType -string public.app-category.games "$plist"
    plutil -insert NSHighResolutionCapable -bool true "$plist"

    copy_rom
}

# make_icns <square png> <icns>: an icon holding the PNG as is; macOS scales it for smaller sizes.
make_icns() {
    python3 - "$1" "$2" <<'EOF'
import struct, sys
png = open(sys.argv[1], "rb").read()
width, height = struct.unpack(">II", png[16:24])
types = {128: [b"ic07"], 256: [b"ic08", b"ic13"], 512: [b"ic09", b"ic14"], 1024: [b"ic10"]}
assert png[:8] == b"\x89PNG\r\n\x1a\n" and width == height and width in types, f"unusable icon {width}x{height}"
entries = b"".join(kind + struct.pack(">I", len(png) + 8) + png for kind in types[width])
open(sys.argv[2], "wb").write(b"icns" + struct.pack(">I", len(entries) + 8) + entries)
EOF
}

# The ROM among the Build-Stage ROMs, which the port reads as it is; nothing when there is none.
copy_rom() {
    local rom
    for rom in "$FRONTPORT_ROMS"/*.z64; do
        [ -e "$rom" ] || continue
        echo "==> Copying $(basename "$rom")"
        cp "$rom" "$FRONTPORT_OUT/assets"
        return
    done
    echo "==> No ROM given: skipping assets"
}

case "$step" in
    fetch) fetch ;;
    build) build ;;
    *) fail "unknown step $step" ;;
esac
