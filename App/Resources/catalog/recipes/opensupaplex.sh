#!/bin/bash
# Frontport Recipe: OpenSupaplex (sergiou87/open-supaplex), a reimplementation of Supaplex in C.
# Contract: catalog/recipes/README.md. Invoked as `opensupaplex.sh fetch`, then `opensupaplex.sh build`.
#
# Upstream's macOS Release is an app whose zip dereferenced the links inside its frameworks, so they no longer
# sign. This builds the same app from source against static SDL2, SDL2_mixer and libxmp-lite (its music is XM).
# Nothing is patched to run sandboxed: upstream's src/apple/file.m reads the game's files from the bundle's
# Resources and writes its config, players, Hall of Fame and saves into ~/Library/Application Support/OpenSupaplex,
# which the App Sandbox puts in the container. The game's files are freeware and in the repository, so the app
# carries them, and there are no ROMs and no Build Assets.
set -euo pipefail

step=${1:?usage: opensupaplex.sh fetch|build}
src=$FRONTPORT_SRC
work=$(dirname "$src")                 # Builds/<port>: writable during build, kept between builds
deps=$src/deps
supaplex=$src/open-supaplex
prefix=$work/prefix                    # the static libraries, reused while their pins don't change
deployment_target=13.0
export MACOSX_DEPLOYMENT_TARGET=$deployment_target
export GIT_CEILING_DIRECTORIES=$work

# Commits of the tags this Recipe was tested against, so a moved tag fails the fetch.
known_commit() {
    case "$1" in
        v7.2.2) echo bad56a4e174e628643995284ea55d4c49af3137c ;;
    esac
}

dependencies="
sdl2 5f5993c530f084535c65a6879e9b26ad441169b3e25d789d83287040a9ca5165 https://github.com/libsdl-org/SDL/releases/download/release-2.32.10/SDL2-2.32.10.tar.gz
libxmp-lite e199da3f7552f5ac688a091b8d28ea3c9ffd2beb845d15aac17d4d264f851d71 https://github.com/libxmp/libxmp/releases/download/libxmp-4.7.3/libxmp-lite-4.7.3.tar.gz
sdl2-mixer 938dff531d00ace2296557a6599abe6f34599e2f34f0a4a08a397e2ccac8b8f7 https://github.com/libsdl-org/SDL_mixer/releases/download/release-2.8.2/SDL2_mixer-2.8.2.tar.gz
"

fail() {
    echo "error: $*" >&2
    exit 1
}

fetch() {
    echo "==> Cloning OpenSupaplex $FRONTPORT_REF"
    git -c advice.detachedHead=false clone --quiet --depth 1 --branch "$FRONTPORT_REF" \
        https://github.com/sergiou87/open-supaplex.git "$supaplex"
    local expected actual
    expected=$(known_commit "$FRONTPORT_REF")
    actual=$(git -C "$supaplex" rev-parse HEAD)
    if [ -n "$expected" ] && [ "$actual" != "$expected" ]; then
        fail "$FRONTPORT_REF is $actual upstream, but this Recipe was tested with $expected"
    fi
    echo "$FRONTPORT_REF" >"$src/version"

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

# cmake_static <name> [options…]: builds a fetched dependency into the prefix as a static library.
cmake_static() {
    local name=$1
    shift
    echo "==> Building $name"
    cmake -S "$deps/$name" -B "$work/$name-build" -G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_ARCHITECTURES=arm64 \
        -DCMAKE_OSX_DEPLOYMENT_TARGET=$deployment_target -DCMAKE_INSTALL_PREFIX="$prefix" \
        -DCMAKE_PREFIX_PATH="$prefix" -DCMAKE_FIND_FRAMEWORK=LAST -DBUILD_SHARED_LIBS=OFF "$@"
    cmake --build "$work/$name-build" -j "$FRONTPORT_JOBS"
    cmake --install "$work/$name-build"
}

build_libraries() {
    local stamp=$prefix/.frontport-libraries
    local wanted
    wanted=$(echo "$dependencies $deployment_target" | shasum -a 256 | cut -d' ' -f1)
    if [ -f "$stamp" ] && [ "$(cat "$stamp")" = "$wanted" ]; then
        echo "==> Reusing the libraries in $prefix"
        return
    fi
    rm -rf "$prefix" "$work"/*-build
    cmake_static sdl2 -DSDL_SHARED=OFF -DSDL_STATIC=ON -DSDL_TEST=OFF
    cmake_static libxmp-lite -DBUILD_SHARED=OFF -DBUILD_STATIC=ON
    # Only what the game plays: WAV sound effects, which SDL2_mixer reads itself, and XM music through libxmp-lite.
    cmake_static sdl2-mixer -DSDL2MIXER_VENDORED=OFF -DSDL2MIXER_SAMPLES=OFF -DSDL2MIXER_CMD=OFF \
        -DSDL2MIXER_FLAC=OFF -DSDL2MIXER_GME=OFF -DSDL2MIXER_MIDI=OFF -DSDL2MIXER_MP3=OFF -DSDL2MIXER_OGG=OFF \
        -DSDL2MIXER_OPUS=OFF -DSDL2MIXER_WAVPACK=OFF -DSDL2MIXER_WAVE=ON \
        -DSDL2MIXER_MOD=ON -DSDL2MIXER_MOD_MODPLUG=OFF -DSDL2MIXER_MOD_XMP=ON -DSDL2MIXER_MOD_XMP_LITE=ON \
        -DSDL2MIXER_MOD_XMP_SHARED=OFF
    echo "$wanted" >"$stamp"
}

build() {
    build_libraries

    echo "==> Building OpenSupaplex"
    # Upstream's Xcode target: the shared sources, SDL 2's, the null virtual keyboard and the Apple file layer.
    # Its audio.c includes <SDL2_mixer/SDL_mixer.h> on Apple, the framework's path, so a shim leads there.
    local objects=$work/objects shim=$work/shim
    rm -rf "$objects" "$shim"
    mkdir -p "$objects" "$shim/SDL2_mixer"
    echo '#include <SDL_mixer.h>' >"$shim/SDL2_mixer/SDL_mixer.h"
    local flags=(-arch arm64 -mmacosx-version-min=$deployment_target -O2 -DHAVE_SDL2
        -I"$prefix/include/SDL2" -I"$prefix/include" -I"$shim")
    local file sources=()
    for file in "$supaplex"/src/*.c "$supaplex"/src/sdl2/*.c "$supaplex"/src/sdl_common/*.c \
        "$supaplex"/src/lib/ini/ini.c "$supaplex"/src/null/virtualKeyboard.c; do
        [ "$file" = "$supaplex/src/file.c" ] && continue    # replaced by src/apple/file.m
        sources+=("$file")
    done
    for file in "${sources[@]}"; do
        clang "${flags[@]}" -c "$file" -o "$objects/$(basename "${file%.c}").o"
    done
    clang "${flags[@]}" -I"$supaplex/src" -fobjc-arc -fmodules -fmodules-cache-path="$TMPDIR/modules" \
        -c "$supaplex/src/apple/file.m" -o "$objects/file.o"

    local app=$FRONTPORT_OUT/OpenSupaplex.app plist version
    plist=$app/Contents/Info.plist
    version=$(sed 's/^v//' "$src/version")
    mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
    # sdl2-config names the prefix, which is under "Application Support", so it's passed quoted as -L instead, and
    # only the system libraries and frameworks are split from its output. The prefix holds only static libraries.
    local sdl_libs
    sdl_libs=$("$prefix/bin/sdl2-config" --static-libs)
    sdl_libs=${sdl_libs//-L$prefix\/lib/}
    sdl_libs=-lSDL2${sdl_libs//$prefix\/lib\/libSDL2.a/}
    # shellcheck disable=SC2086 # sdl2-config's flags are meant to be split
    clang "${flags[@]}" -o "$app/Contents/MacOS/OpenSupaplex" "$objects"/*.o -L"$prefix/lib" -lSDL2_mixer -lxmp-lite \
        $sdl_libs -framework Foundation

    echo "==> Making OpenSupaplex.app"
    cp -R "$supaplex/resources/" "$app/Contents/Resources/"
    make_icon "$supaplex/macos/OpenSupaplex/Assets.xcassets/AppIcon.appiconset" "$app/Contents/Resources/OpenSupaplex.icns"
    plutil -create xml1 "$plist"
    plutil -insert CFBundleExecutable -string OpenSupaplex "$plist"
    plutil -insert CFBundleIdentifier -string "dev.frontport.port.$FRONTPORT_PORT" "$plist"
    plutil -insert CFBundleName -string OpenSupaplex "$plist"
    plutil -insert CFBundlePackageType -string APPL "$plist"
    plutil -insert CFBundleInfoDictionaryVersion -string 6.0 "$plist"
    plutil -insert CFBundleShortVersionString -string "$version" "$plist"
    plutil -insert CFBundleVersion -string "$version" "$plist"
    plutil -insert CFBundleIconFile -string OpenSupaplex "$plist"
    plutil -insert LSMinimumSystemVersion -string "$deployment_target" "$plist"
    plutil -insert LSApplicationCategoryType -string public.app-category.puzzle-games "$plist"
    plutil -insert NSHighResolutionCapable -bool true "$plist"
    plutil -insert NSPrincipalClass -string NSApplication "$plist"
}

# make_icon <appiconset> <icns>: an icns from upstream's square Murphy PNGs, which an icns holds as they are.
make_icon() {
    python3 - "$1" "$2" <<'EOF'
import struct, sys
types = {32: [b"ic11"], 64: [b"ic12"], 128: [b"ic07"], 256: [b"ic08", b"ic13"], 512: [b"ic09", b"ic14"],
         1024: [b"ic10"]}
entries = b""
for size, kinds in types.items():
    png = open(f"{sys.argv[1]}/murphy-{size}.png", "rb").read()
    assert png[:8] == b"\x89PNG\r\n\x1a\n" and struct.unpack(">II", png[16:24]) == (size, size), f"unusable icon {size}"
    entries += b"".join(kind + struct.pack(">I", len(png) + 8) + png for kind in kinds)
open(sys.argv[2], "wb").write(b"icns" + struct.pack(">I", len(entries) + 8) + entries)
EOF
}

case "$step" in
    fetch) fetch ;;
    build) build ;;
    *) fail "unknown step $step" ;;
esac
