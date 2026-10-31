#!/bin/bash
# Frontport Recipe: dhewm3 (dhewm/dhewm3), a Doom 3 engine built on the GPL source release.
# Contract: catalog/recipes/README.md. Invoked as `dhewm3.sh fetch`, then `dhewm3.sh build`.
#
# One Recipe, one app for both Ports, dhewm3-doom-3 and dhewm3-resurrection-of-evil: dhewm3.app holds the engine
# and both game libraries, base.dylib and d3xp.dylib, in Contents/MacOS/base, where the engine looks inside its
# bundle; Resurrection of Evil is the same app run with `+set fs_game d3xp`. The engine never loads code from the
# game folders, so the Windows gamex86.dll and game0x.pk4 Seeded from Steam are ignored.
#
# Upstream publishes no macOS app. This builds it against a static SDL2 and a static OpenAL Soft (the engine needs
# its EFX and ALC_SOFT extensions, which macOS's OpenAL.framework lacks), with curl off (only multiplayer
# downloads use it). Inside an app, the engine already writes its configs, saves and dhewm3log.txt in
# ~/Library/Application Support/dhewm3, which the App Sandbox puts in the container, but reads the game from the
# folder holding the app. A patch makes that same folder its base path, where Frontport Seeds base/ and d3xp/.
set -euo pipefail

step=${1:?usage: dhewm3.sh fetch|build}
src=$FRONTPORT_SRC
work=$(dirname "$src")                 # Builds/<port>: writable during build, kept between builds
deps=$src/deps
dhewm3=$src/dhewm3
prefix=$work/prefix                    # the static libraries, reused while their pins don't change
deployment_target=13.0
export MACOSX_DEPLOYMENT_TARGET=$deployment_target
export GIT_CEILING_DIRECTORIES=$work

fail() {
    echo "error: $*" >&2
    exit 1
}

case "$FRONTPORT_PORT" in
    dhewm3-doom-3 | dhewm3-resurrection-of-evil) ;;
    *) fail "Port $FRONTPORT_PORT names no game this Recipe builds (dhewm3-doom-3, dhewm3-resurrection-of-evil)" ;;
esac

# Commits of the tags this Recipe was tested against, so a moved tag fails the fetch.
known_commit() {
    case "$1" in
        1.5.5) echo 455b88e8dff2be822f08eb498f51b383e851fa38 ;;
    esac
}

# name sha256 url. OpenAL Soft is the GitHub archive of its 1.25.2 tag's commit.
dependencies="
sdl2 5f5993c530f084535c65a6879e9b26ad441169b3e25d789d83287040a9ca5165 https://github.com/libsdl-org/SDL/releases/download/release-2.32.10/SDL2-2.32.10.tar.gz
openal-soft 6a3e5f80058ecf994a6885d7db5013629a259c659ab40a6f17db8963ceb211b2 https://github.com/kcat/openal-soft/archive/b2c48f7718ef3fcf67921a8b6534c4914e328970.tar.gz
"

# Replaces exactly the text given in a file, failing loudly when upstream changed it.
replace() {
    local file=$1 old=$2 new=$3
    grep -qF -- "$old" "$file" || fail "$file no longer contains: $old"
    OLD=$old NEW=$new perl -0pi -e 's/\Q$ENV{OLD}\E/$ENV{NEW}/g' "$file"
}

fetch() {
    echo "==> Cloning dhewm3 $FRONTPORT_REF"
    git clone --quiet https://github.com/dhewm/dhewm3.git "$dhewm3"
    git -C "$dhewm3" -c advice.detachedHead=false checkout --quiet "$FRONTPORT_REF"
    local expected actual
    expected=$(known_commit "$FRONTPORT_REF")
    actual=$(git -C "$dhewm3" rev-parse HEAD)
    if [ -n "$expected" ] && [ "$actual" != "$expected" ]; then
        fail "$FRONTPORT_REF is $actual upstream, but this Recipe was tested with $expected"
    fi
    git -C "$dhewm3" describe --tags --long >"$src/version" 2>/dev/null || echo "0-0-g$actual" >"$src/version"

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
    # Read the game from ~/Library/Application Support/dhewm3, the save path, instead of the folder holding the app.
    # With both paths the same, the engine searches that folder once, and its writes land beside the game's files,
    # in base/ or d3xp/: dhewm.cfg (it never reads Steam's DoomConfig.cfg), savegames/, screenshots/, the doomkey and
    # xpkey stubs.
    replace "$dhewm3/neo/sys/osx/DOOMController.mm" "	{
		char* snap;
		strncpy(base_path, exe_path, sizeof(base_path)-1);
		base_path[sizeof(base_path)-1] = '\0';
		snap = strrchr(base_path, '/');
		if (snap)
			*snap = '\0';
	}" "	// Frontport: the game is Seeded where the engine saves, in the App Sandbox container.
	strncpy(base_path, save_path, sizeof(base_path)-1);
	base_path[sizeof(base_path)-1] = '\0';"
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
    # Only the library, playing through CoreAudio, with its HRTF data built in. It turns on -Werror=function-effects
    # with -Wfunction-effects when the compiler takes it, and Xcode 27's clang then rejects its CoreAudio callbacks,
    # so it's told the compiler doesn't.
    cmake_static openal-soft -DLIBTYPE=STATIC -DHAVE_WFUNCTION_EFFECTS=OFF \
        -DALSOFT_UTILS=OFF -DALSOFT_EXAMPLES=OFF -DALSOFT_TESTS=OFF -DALSOFT_INSTALL_CONFIG=OFF \
        -DALSOFT_INSTALL_HRTF_DATA=OFF -DALSOFT_INSTALL_AMBDEC_PRESETS=OFF -DALSOFT_INSTALL_EXAMPLES=OFF \
        -DALSOFT_INSTALL_UTILS=OFF -DALSOFT_UPDATE_BUILD_VERSION=OFF \
        -DALSOFT_ENABLE_MODULES=OFF -DALSOFT_REQUIRE_COREAUDIO=ON -DALSOFT_BACKEND_PIPEWIRE=OFF \
        -DALSOFT_BACKEND_PULSEAUDIO=OFF -DALSOFT_BACKEND_JACK=OFF -DALSOFT_BACKEND_PORTAUDIO=OFF \
        -DALSOFT_BACKEND_WAVE=OFF
    echo "$wanted" >"$stamp"
}

build() {
    build_libraries
    # What the static SDL2 itself links against: its system libraries and frameworks, leaving out its own paths,
    # which hold a space (Application Support).
    local sdl_libs
    sdl_libs=$("$prefix/bin/sdl2-config" --static-libs | tr ' ' '\n' | grep -E '^-(l|Wl,)' | grep -v '^-lSDL2$' \
        | tr '\n' ';')
    local openal_libs="$prefix/lib/libopenal.a;-framework AudioToolbox;-framework AudioUnit;-framework CoreAudio"
    openal_libs+=";-framework ApplicationServices;-framework CoreFoundation"

    echo "==> Configuring dhewm3"
    rm -rf "$work/build"
    cmake -S "$dhewm3/neo" -B "$work/build" -G Ninja -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=$deployment_target \
        -DCMAKE_FIND_FRAMEWORK=LAST -DCMAKE_DISABLE_FIND_PACKAGE_CURL=ON \
        -DCORE=ON -DBASE=ON -DD3XP=ON -DDEDICATED=OFF -DSDL2=ON -DSDL3=OFF -DIMGUI=ON \
        -DSDL2_INCLUDE_DIR="$prefix/include/SDL2" -DSDL2_LIBRARY_TEMP="$prefix/lib/libSDL2.a;${sdl_libs%;}" \
        -DOPENAL_INCLUDE_DIR="$prefix/include" -DOPENAL_LIBRARY="$openal_libs"

    echo "==> Building dhewm3"
    cmake --build "$work/build" -j "$FRONTPORT_JOBS"

    echo "==> Making dhewm3.app"
    local app=$FRONTPORT_OUT/dhewm3.app lib
    [ -d "$work/build/dhewm3.app" ] || fail "the build made no app"
    cp -R "$work/build/dhewm3.app" "$FRONTPORT_OUT/"
    mkdir -p "$app/Contents/MacOS/base"
    for lib in base d3xp; do
        [ -f "$work/build/$lib.dylib" ] || fail "the build made no $lib.dylib"
        cp "$work/build/$lib.dylib" "$app/Contents/MacOS/base/"
    done
    if otool -L "$app/Contents/MacOS/dhewm3" | grep -qiE 'sdl|openal|curl|/opt/|/usr/local/'; then
        fail "dhewm3 links a library outside the system"
    fi

    local plist=$app/Contents/Info.plist describe version
    describe=$(cat "$src/version")                        # 1.5.5-0-g455b88e
    version=$(sed -nE 's/^#define[[:space:]]+ENGINE_VERSION[[:space:]]+"dhewm3 ([0-9.]+)".*/\1/p' \
        "$dhewm3/neo/framework/Licensee.h")
    [ -n "$version" ] || fail "no ENGINE_VERSION in Licensee.h"
    plutil -replace CFBundleIdentifier -string "dev.frontport.port.$FRONTPORT_PORT" "$plist"
    plutil -replace CFBundleName -string dhewm3 "$plist"
    plutil -replace CFBundleShortVersionString -string "$version" "$plist"
    plutil -replace CFBundleVersion -string "$version" "$plist"
    plutil -replace CFBundleGetInfoString -string "$describe" "$plist"
    plutil -replace LSMinimumSystemVersion -string "$deployment_target" "$plist"
    plutil -replace LSApplicationCategoryType -string public.app-category.action-games "$plist"
    plutil -remove NSMainNibFile "$plist"                 # there is none: SDLMain.m builds the menu itself
}

case "$step" in
    fetch) fetch ;;
    build) build ;;
    *) fail "unknown step $step" ;;
esac
