#!/bin/bash
# Frontport Recipe: Yamagi Quake II (yquake2/yquake2), Quake II built on the GPL source release.
# Contract: catalog/recipes/README.md. Invoked as `yquake2.sh fetch`, then `yquake2.sh build`.
#
# Upstream publishes no macOS app and its macOS build wants Homebrew's SDL3 and OpenAL Soft. This builds both from
# pinned sources with upstream's CMake and wraps the result in Yamagi Quake II.app:
# - Contents/MacOS holds the quake2 executable, its renderers (ref_gl3, the default on OpenGL 3.2, ref_gl1 and
#   ref_soft; the GLES ones need a GLES driver macOS lacks) and baseq2/game.dylib, the game code, all of which the
#   engine loads from its own folder.
# - SDL3 and OpenAL Soft (the engine uses its EFX underwater effects) are dylibs in Contents/Frameworks: the
#   executable and each renderer use SDL, so a static one would be a separate copy in each, and the engine dlopens
#   OpenAL. curl is off (only multiplayer downloads use it).
# The engine reads the game from its own folder and the folder it's started in, and writes to ~/.local/share/
# YamagiQ2. A patch makes that ~/Library/Application Support/YamagiQ2 instead, where the App Sandbox puts the
# container and Frontport Seeds the game's baseq2 folder; config.cfg, saves and screenshots go into that baseq2 too.
# Another patch starts it in a fullscreen window at the display's resolution: the game's default.cfg asks for a
# display mode switch to 640x480, which macOS letterboxes off-center on today's displays.
set -euo pipefail

step=${1:?usage: yquake2.sh fetch|build}
src=$FRONTPORT_SRC
work=$(dirname "$src")                 # Builds/<port>: writable during build, kept between builds
deps=$src/deps
yquake2=$src/yquake2
prefix=$work/prefix                    # the libraries, reused while their pins don't change
deployment_target=13.0
export MACOSX_DEPLOYMENT_TARGET=$deployment_target
export GIT_CEILING_DIRECTORIES=$work

fail() {
    echo "error: $*" >&2
    exit 1
}

# Commits of the tags this Recipe was tested against, so a moved tag fails the fetch.
known_commit() {
    case "$1" in
        QUAKE2_8_70) echo 76e81f9f3fc3ed859006d81904bfeb6cb33fb525 ;;
    esac
}

# name sha256 url. OpenAL Soft is the GitHub archive of its 1.25.2 tag's commit.
dependencies="
sdl3 f3bb06f55bed9557227a700af2ea62e49497ebdf58037732a731a5fb3ef8581f https://github.com/libsdl-org/SDL/releases/download/release-3.4.20/SDL3-3.4.20.tar.gz
openal-soft 6a3e5f80058ecf994a6885d7db5013629a259c659ab40a6f17db8963ceb211b2 https://github.com/kcat/openal-soft/archive/b2c48f7718ef3fcf67921a8b6534c4914e328970.tar.gz
"

# Replaces exactly the text given in a file, failing loudly when upstream changed it.
replace() {
    local file=$1 old=$2 new=$3
    grep -qF -- "$old" "$file" || fail "$file no longer contains: $old"
    OLD=$old NEW=$new perl -0pi -e 's/\Q$ENV{OLD}\E/$ENV{NEW}/g' "$file"
}

fetch() {
    echo "==> Cloning Yamagi Quake II $FRONTPORT_REF"
    git clone --quiet https://github.com/yquake2/yquake2.git "$yquake2"
    git -C "$yquake2" -c advice.detachedHead=false checkout --quiet "$FRONTPORT_REF"
    local expected actual
    expected=$(known_commit "$FRONTPORT_REF")
    actual=$(git -C "$yquake2" rev-parse HEAD)
    if [ -n "$expected" ] && [ "$actual" != "$expected" ]; then
        fail "$FRONTPORT_REF is $actual upstream, but this Recipe was tested with $expected"
    fi

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

    echo "==> Patching"
    # The home folder, where the engine writes and reads first: ~/Library/Application Support/YamagiQ2.
    replace "$yquake2/src/backends/unix/system.c" '		if (!home) {
			// uh-oh
			return NULL;
		}
' '		if (!home) {
			// uh-oh
			return NULL;
		}

#ifdef __APPLE__
		// Frontport: the game is Seeded where the engine writes, in the App Sandbox container.
		Com_sprintf(dir, MAX_OSPATH, "%s/Library/Application Support/%s/", home, cfgdir);
		Sys_Mkdir(dir);
		return dir;
#endif
'
    # A fullscreen window at the display's resolution, over what the game's own configs ask for: the demo's
    # default.cfg a switch to 640x480, Steam's config.cfg a 640x480 window. It's set once, after the configs and before
    # the command line, then marked in config.cfg by an archived cvar, so the player's own settings win from then on.
    replace "$yquake2/src/common/frame.c" '	Cbuf_AddText("exec autoexec.cfg\n");
' '	Cbuf_AddText("exec autoexec.cfg\n");

#ifdef __APPLE__
	// Frontport: a fullscreen window at the desktop resolution, not a display mode switch, until the player picks.
	Cbuf_Execute();
	if (Cvar_VariableString("frontport_display")[0] == '"'\\0'"')
	{
		Cbuf_AddText("set vid_fullscreen 2\nset r_mode -2\n");
	}
	Cvar_Get("frontport_display", "1", CVAR_ARCHIVE);
#endif
'
    # OpenAL Soft from the app's Frameworks folder, which dlopen doesn't search for a bare file name.
    replace "$yquake2/src/client/sound/qal.c" '	Sys_LoadLibrary(al_driver->string, NULL, &handle);' '	{
		// Frontport: OpenAL Soft ships in the app, in Contents/Frameworks.
		char al_path[MAX_OSPATH];
		Com_sprintf(al_path, sizeof(al_path), "%s../Frameworks/%s", Sys_GetBinaryDir(), al_driver->string);
		Sys_LoadLibrary(al_path, NULL, &handle);
	}'
}

# cmake_lib <name> [options…]: builds a fetched dependency into the prefix.
cmake_lib() {
    local name=$1
    shift
    echo "==> Building $name"
    cmake -S "$deps/$name" -B "$work/$name-build" -G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_ARCHITECTURES=arm64 \
        -DCMAKE_OSX_DEPLOYMENT_TARGET=$deployment_target -DCMAKE_INSTALL_PREFIX="$prefix" \
        -DCMAKE_PREFIX_PATH="$prefix" -DCMAKE_FIND_FRAMEWORK=LAST "$@"
    cmake --build "$work/$name-build" -j "$FRONTPORT_JOBS"
    cmake --install "$work/$name-build"
}

build_libraries() {
    local stamp=$prefix/.frontport-libraries
    local wanted
    wanted=$(echo "$dependencies $deployment_target shared" | shasum -a 256 | cut -d' ' -f1)
    if [ -f "$stamp" ] && [ "$(cat "$stamp")" = "$wanted" ]; then
        echo "==> Reusing the libraries in $prefix"
        return
    fi
    rm -rf "$prefix" "$work"/*-build
    cmake_lib sdl3 -DSDL_SHARED=ON -DSDL_STATIC=OFF -DSDL_TEST_LIBRARY=OFF -DSDL_TESTS=OFF -DSDL_EXAMPLES=OFF
    # Only the library, playing through CoreAudio, with its HRTF data built in. It turns on -Werror=function-effects
    # with -Wfunction-effects when the compiler takes it, and Xcode 27's clang then rejects its CoreAudio callbacks,
    # so it's told the compiler doesn't.
    cmake_lib openal-soft -DLIBTYPE=SHARED -DHAVE_WFUNCTION_EFFECTS=OFF \
        -DALSOFT_UTILS=OFF -DALSOFT_EXAMPLES=OFF -DALSOFT_TESTS=OFF -DALSOFT_INSTALL_CONFIG=OFF \
        -DALSOFT_INSTALL_HRTF_DATA=OFF -DALSOFT_INSTALL_AMBDEC_PRESETS=OFF -DALSOFT_INSTALL_EXAMPLES=OFF \
        -DALSOFT_INSTALL_UTILS=OFF -DALSOFT_UPDATE_BUILD_VERSION=OFF \
        -DALSOFT_ENABLE_MODULES=OFF -DALSOFT_REQUIRE_COREAUDIO=ON -DALSOFT_BACKEND_PIPEWIRE=OFF \
        -DALSOFT_BACKEND_PULSEAUDIO=OFF -DALSOFT_BACKEND_JACK=OFF -DALSOFT_BACKEND_PORTAUDIO=OFF \
        -DALSOFT_BACKEND_WAVE=OFF
    # Named as the engine loads it, from the app's Frameworks.
    local openal
    openal=$(realpath "$prefix/lib/libopenal.dylib")
    rm "$prefix/lib/libopenal.dylib"
    mv "$openal" "$prefix/lib/libopenal.dylib"
    install_name_tool -id @rpath/libopenal.dylib "$prefix/lib/libopenal.dylib"
    rm -rf "$work"/*-build
    echo "$wanted" >"$stamp"
}

build() {
    build_libraries

    echo "==> Configuring Yamagi Quake II"
    rm -rf "$work/build"
    cmake -S "$yquake2" -B "$work/build" -G Ninja -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=$deployment_target \
        -DCMAKE_PREFIX_PATH="$prefix" -DCMAKE_FIND_FRAMEWORK=LAST -DCMAKE_SKIP_RPATH=ON \
        -DCMAKE_EXE_LINKER_FLAGS="-Wl,-rpath,@executable_path/../Frameworks" \
        -DCMAKE_MODULE_LINKER_FLAGS="-Wl,-rpath,@loader_path/../Frameworks" \
        -DSDL3_SUPPORT=ON -DOPENAL_SUPPORT=ON -DCURL_SUPPORT=OFF -DSYSTEMWIDE_SUPPORT=OFF \
        -DGL1_RENDERER=ON -DGL3_RENDERER=ON -DSOFT_RENDERER=ON -DGLES1_RENDERER=OFF -DGLES3_RENDERER=OFF \
        -DOPENAL_INCLUDE_DIR="$prefix/include" -DOPENAL_LIBRARY="$prefix/lib/libopenal.dylib"

    echo "==> Building Yamagi Quake II"
    cmake --build "$work/build" -j "$FRONTPORT_JOBS"

    echo "==> Making Yamagi Quake II.app"
    local release=$work/build/release
    local app="$FRONTPORT_OUT/Yamagi Quake II.app"
    local macos=$app/Contents/MacOS lib
    [ -x "$release/quake2" ] || fail "the build made no quake2 executable"
    mkdir -p "$macos/baseq2" "$app/Contents/Resources" "$app/Contents/Frameworks"
    cp "$release/quake2" "$macos/"
    for lib in ref_gl1 ref_gl3 ref_soft; do
        [ -f "$release/$lib.dylib" ] || fail "the build made no $lib.dylib"
        cp "$release/$lib.dylib" "$macos/"
    done
    [ -f "$release/baseq2/game.dylib" ] || fail "the build made no baseq2/game.dylib"
    cp "$release/baseq2/game.dylib" "$macos/baseq2/"
    cp "$prefix/lib/libopenal.dylib" "$app/Contents/Frameworks/"
    cp "$(realpath "$prefix/lib/libSDL3.0.dylib")" "$app/Contents/Frameworks/libSDL3.0.dylib"
    local file
    for file in "$macos/quake2" "$macos"/*.dylib "$macos/baseq2/game.dylib"; do
        if otool -L "$file" | tail -n +2 | grep -vE '@rpath/lib(SDL3\.0|openal)\.dylib' \
            | grep -qvE '^[[:space:]]+/(usr/lib|System/Library)/'; then
            fail "${file##*/} links a library outside the system and the app"
        fi
    done
    make_icon "$yquake2/stuff/icon/Quake2.png" "$app/Contents/Resources/Quake2.icns"

    local version
    version=$(sed -nE 's/^#define[[:space:]]+YQ2VERSION[[:space:]]+"([0-9.]+)".*/\1/p' \
        "$yquake2/src/common/header/common.h")
    [ -n "$version" ] || fail "no YQ2VERSION in common.h"
    local plist=$app/Contents/Info.plist
    plutil -create xml1 "$plist"
    plutil -insert CFBundleExecutable -string quake2 "$plist"
    plutil -insert CFBundleIdentifier -string "dev.frontport.port.$FRONTPORT_PORT" "$plist"
    plutil -insert CFBundleName -string "Yamagi Quake II" "$plist"
    plutil -insert CFBundleDisplayName -string "Yamagi Quake II" "$plist"
    plutil -insert CFBundlePackageType -string APPL "$plist"
    plutil -insert CFBundleInfoDictionaryVersion -string 6.0 "$plist"
    plutil -insert CFBundleShortVersionString -string "$version" "$plist"
    plutil -insert CFBundleVersion -string "$version" "$plist"
    plutil -insert CFBundleIconFile -string Quake2 "$plist"
    plutil -insert LSMinimumSystemVersion -string "$deployment_target" "$plist"
    plutil -insert LSApplicationCategoryType -string public.app-category.action-games "$plist"
    plutil -insert NSHighResolutionCapable -bool true "$plist"
    plutil -insert NSPrincipalClass -string NSApplication "$plist"
}

# make_icon <png> <icns>: an icns holding upstream's square PNG as it is, when it's a size an icns takes.
make_icon() {
    python3 -I - "$1" "$2" <<'EOF'
import struct, sys
png = open(sys.argv[1], "rb").read()
assert png[:8] == b"\x89PNG\r\n\x1a\n", "not a PNG"
width, height = struct.unpack(">II", png[16:24])
kinds = {32: b"ic11", 64: b"ic12", 128: b"ic07", 256: b"ic08", 512: b"ic09", 1024: b"ic10"}
assert width == height and width in kinds, f"unusable icon {width}x{height}"
entry = kinds[width] + struct.pack(">I", len(png) + 8) + png
open(sys.argv[2], "wb").write(b"icns" + struct.pack(">I", len(entry) + 8) + entry)
EOF
}

case "$step" in
    fetch) fetch ;;
    build) build ;;
    *) fail "unknown step $step" ;;
esac
