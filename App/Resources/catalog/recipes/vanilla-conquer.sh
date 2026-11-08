#!/bin/bash
# Frontport Recipe: Vanilla Conquer (TheAssemblyArmada/Vanilla-Conquer), Command & Conquer and Red Alert on the
# engine EA released as GPL source with the Remastered Collection.
# Contract: catalog/recipes/README.md. Invoked as `vanilla-conquer.sh fetch`, then `vanilla-conquer.sh build`.
#
# Upstream has no Releases, only a rolling build, so this builds a pinned commit with upstream's CMake against a
# static SDL2 and macOS's OpenAL, one game per Port: vanillatd.app for Command & Conquer, vanillara.app for Red
# Alert. The engine looks for each disc's files in a folder named for the disc (gdi, nod; allied, soviet) in
# ~/Library/Application Support/Vanilla-Conquer/<game>, where it also keeps its settings and saves, and where
# Frontport Seeds the discs, in the container. With no settings it opens a fullscreen window at the desktop's
# resolution. fetch patches it to:
#   - read its first files, the fonts, palettes and title screen it opens before choosing a disc (CCLOCAL.MIX,
#     UPDATE.MIX and UPDATEC.MIX; REDALERT.MIX), from the first disc folder there, as every disc has them.
#     Upstream expects them beside the folders, copied there by hand; without them the menu is black.
set -euo pipefail

step=${1:?usage: vanilla-conquer.sh fetch|build}
src=$FRONTPORT_SRC
work=$(dirname "$src")                 # Builds/<port>: writable during build, kept between builds
deps=$src/deps
vc=$src/Vanilla-Conquer
prefix=$work/prefix                    # the libraries, reused while their pins don't change
deployment_target=13.0
export MACOSX_DEPLOYMENT_TARGET=$deployment_target
export GIT_CEILING_DIRECTORIES=$work

fail() {
    echo "error: $*" >&2
    exit 1
}

# replace <file> <old> <new>: replaces text that must be there, so a changed upstream fails the fetch.
replace() {
    local file=$1 old=$2 new=$3
    grep -qF -- "$old" "$file" || fail "$file no longer contains: $old"
    OLD=$old NEW=$new perl -0pi -e 's/\Q$ENV{OLD}\E/$ENV{NEW}/g' "$file"
}

# disc_search <discs>: C++ that adds the first of the discs' folders to the search path, for the bootstrap mixfiles.
disc_search() {
    cat <<EOF
    // Frontport: every disc has the bootstrap mixfiles; read them from the first disc folder there is.
    {
        static const char* const discs[] = {$1};
        for (const char* disc : discs) {
            std::string path = Paths.Concatenate_Paths(Paths.User_Path(), disc);
            if (RawFileClass(path.c_str()).Is_Directory()) {
                path += PathsClass::SEP;
                CDFileClass::Refresh_Search_Drives();
                CDFileClass::Add_Search_Drive(path.c_str());
                break;
            }
        }
    }

EOF
}

case "$FRONTPORT_PORT" in
    vanilla-conquer-tiberian-dawn) game=vanillatd ;;
    vanilla-conquer-red-alert) game=vanillara ;;
    *) fail "no game for Port $FRONTPORT_PORT" ;;
esac

# name sha256 url.
dependencies="
sdl2 5f5993c530f084535c65a6879e9b26ad441169b3e25d789d83287040a9ca5165 https://github.com/libsdl-org/SDL/releases/download/release-2.32.10/SDL2-2.32.10.tar.gz
"

download() {
    local file=$1 sha=$2 url=$3
    curl -fsSL --retry 3 -o "$file" "$url"
    echo "$sha  $file" | shasum -a 256 -c --status - || fail "$(basename "$file") doesn't match its pinned sha256"
}

fetch() {
    echo "==> Cloning Vanilla Conquer $FRONTPORT_REF"
    git clone --quiet https://github.com/TheAssemblyArmada/Vanilla-Conquer.git "$vc"
    git -C "$vc" -c advice.detachedHead=false checkout --quiet "$FRONTPORT_REF"
    git -C "$vc" log -1 --format=%cs >"$src/date"
    git -C "$vc" rev-parse --short=7 HEAD >"$src/commit"

    echo "==> Patching"
    local td_bootstrap='    CCDebugString("C&C95 - About to register CCLOCAL.MIX\n");'
    replace "$vc/tiberiandawn/init.cpp" "$td_bootstrap" "$(disc_search '"gdi", "nod", "covertops"')
$td_bootstrap"
    local ra_bootstrap='    int temp = RequiredCD;
    RequiredCD = -2;

#ifdef WOLAPI_INTEGRATION'
    replace "$vc/redalert/init.cpp" "$ra_bootstrap" "$(disc_search '"allied", "soviet", "counterstrike", "aftermath"')
$ra_bootstrap"
    replace "$vc/redalert/init.cpp" '#include "common/vqaconfig.h"' '#include "common/vqaconfig.h"
#include "common/paths.h"'

    mkdir -p "$deps"
    local name sha url file
    while read -r name sha url; do
        [ -n "$name" ] || continue
        echo "==> Downloading $name"
        file=$deps/$name.download
        download "$file" "$sha" "$url"
        mkdir -p "$deps/$name"
        tar -xf "$file" -C "$deps/$name" --strip-components=1
        rm "$file"
    done <<<"$dependencies"
}

build_libraries() {
    local stamp=$prefix/.frontport-libraries
    local wanted
    wanted=$(echo "$dependencies $deployment_target" | shasum -a 256 | cut -d' ' -f1)
    if [ -f "$stamp" ] && [ "$(cat "$stamp")" = "$wanted" ]; then
        echo "==> Reusing the libraries in $prefix"
        return
    fi
    rm -rf "$prefix" "$work/sdl2-build"
    echo "==> Building sdl2"
    cmake -S "$deps/sdl2" -B "$work/sdl2-build" -G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_ARCHITECTURES=arm64 \
        -DCMAKE_OSX_DEPLOYMENT_TARGET=$deployment_target -DCMAKE_INSTALL_PREFIX="$prefix" \
        -DSDL_SHARED=OFF -DSDL_STATIC=ON -DSDL_TEST=OFF
    cmake --build "$work/sdl2-build" -j "$FRONTPORT_JOBS"
    cmake --install "$work/sdl2-build"
    echo "$wanted" >"$stamp"
}

build() {
    build_libraries
    # What the static SDL2 itself links against, leaving out its own paths, which hold a space.
    local sdl_libs
    sdl_libs=$("$prefix/bin/sdl2-config" --static-libs | tr ' ' '\n' | grep -E '^-(l|Wl,)' | grep -v '^-lSDL2$' \
        | tr '\n' ';')

    local td=OFF ra=OFF
    [ "$game" = vanillatd ] && td=ON
    [ "$game" = vanillara ] && ra=ON
    echo "==> Configuring Vanilla Conquer"
    rm -rf "$work/build"
    cmake -S "$vc" -B "$work/build" -G Ninja -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=$deployment_target \
        -DBUILD_VANILLATD=$td -DBUILD_VANILLARA=$ra -DBUILD_REMASTERTD=OFF -DBUILD_REMASTERRA=OFF \
        -DBUILD_TOOLS=OFF -DBUILD_TESTS=OFF -DSDL2=ON -DSDL1=OFF -DOPENAL=ON -DMAKE_BUNDLE=ON \
        -DSDL2_INCLUDE_DIR="$prefix/include/SDL2" -DSDL2_LIBRARY="$prefix/lib/libSDL2.a;${sdl_libs%;}" \
        -DSDL2_SDLMAIN_LIBRARY="$prefix/lib/libSDL2main.a"

    echo "==> Building Vanilla Conquer"
    cmake --build "$work/build" -j "$FRONTPORT_JOBS"

    local app=$FRONTPORT_OUT/$game.app
    echo "==> Making $game.app"
    [ -d "$work/build/$game.app" ] || fail "the build made no $game.app"
    cp -R "$work/build/$game.app" "$FRONTPORT_OUT/"
    if otool -L "$app/Contents/MacOS/$game" | grep -qiE 'sdl|/opt/|/usr/local/'; then
        fail "$game links a library outside the system"
    fi

    local plist=$app/Contents/Info.plist version
    version="$(cat "$src/date")-$(cat "$src/commit")"   # upstream has no versions: the commit's date and hash
    plutil -replace CFBundleIdentifier -string "dev.frontport.port.$FRONTPORT_PORT" "$plist"
    plutil -replace CFBundleShortVersionString -string "$version" "$plist"
    plutil -replace CFBundleVersion -string "$version" "$plist"
    plutil -replace LSMinimumSystemVersion -string "$deployment_target" "$plist"
    plutil -replace LSApplicationCategoryType -string public.app-category.strategy-games "$plist"
}

case "$step" in
    fetch) fetch ;;
    build) build ;;
    *) fail "unknown step $step" ;;
esac
