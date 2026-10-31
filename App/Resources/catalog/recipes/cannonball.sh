#!/bin/bash
# Frontport Recipe: Cannonball (djyt/cannonball), the enhanced OutRun engine, ported from the arcade's 68000 code.
# Contract: catalog/recipes/README.md. Invoked as `cannonball.sh fetch`, then `cannonball.sh build`.
#
# Upstream publishes Windows builds only. Its CMake project builds a bare executable for Linux, so this builds the
# same sources with OpenGL against static SDL2 and Boost's headers (property_tree), and wraps it in an app. Cannonball
# reads config.xml, roms/ and res/ from the working folder and writes its scores there, so fetch patches it to play
# from ~/Library/Application Support/Cannonball instead (inside the container under the App Sandbox), where Frontport
# Seeds the ROMs into roms/ and the first launch copies upstream's config.xml, and to read res/ from the app. It
# also asks for the OpenGL context its renderer needs on macOS, and drops its Apple-only colour shuffle.
set -euo pipefail

step=${1:?usage: cannonball.sh fetch|build}
src=$FRONTPORT_SRC
work=$(dirname "$src")                 # Builds/<port>: writable during build, kept between builds
deps=$src/deps
cannonball=$src/cannonball
prefix=$work/prefix                    # static SDL2, reused while its pin doesn't change
deployment_target=13.0
export MACOSX_DEPLOYMENT_TARGET=$deployment_target
export GIT_CEILING_DIRECTORIES=$work
export CMAKE_POLICY_VERSION_MINIMUM=3.5   # upstream declares 3.3.2

# name sha256 url. Boost only for its headers: fetch keeps boost/ and drops the rest.
dependencies="
sdl2 5f5993c530f084535c65a6879e9b26ad441169b3e25d789d83287040a9ca5165 https://github.com/libsdl-org/SDL/releases/download/release-2.32.10/SDL2-2.32.10.tar.gz
boost 46d9d2c06637b219270877c9e16155cbd015b6dc84349af064c088e9b5b12f7b https://archives.boost.io/release/1.88.0/source/boost_1_88_0.tar.bz2
"

fail() {
    echo "error: $*" >&2
    exit 1
}

replace() {
    local file=$1 old=$2 new=$3
    grep -qF -- "$old" "$file" || fail "$file no longer contains: $old"
    OLD=$old NEW=$new perl -0pi -e 's/\Q$ENV{OLD}\E/$ENV{NEW}/g' "$file"
}

fetch() {
    echo "==> Cloning Cannonball $FRONTPORT_REF"
    git clone --quiet https://github.com/djyt/cannonball.git "$cannonball"
    git -C "$cannonball" -c advice.detachedHead=false checkout --quiet "$FRONTPORT_REF"
    git -C "$cannonball" describe --tags --long >"$src/version" 2>/dev/null || echo "v0-0-g$FRONTPORT_REF" >"$src/version"

    mkdir -p "$deps"
    local name sha url file
    while read -r name sha url; do
        [ -n "$name" ] || continue
        echo "==> Downloading $name"
        file=$deps/$name.download
        curl -fsSL --retry 3 -o "$file" "$url"
        echo "$sha  $file" | shasum -a 256 -c --status - || fail "$name doesn't match its pinned sha256"
        mkdir -p "$deps/$name"
        if [ "$name" = boost ]; then
            tar -xf "$file" -C "$deps/$name" --strip-components=1 boost_1_88_0/boost
        else
            tar -xf "$file" -C "$deps/$name" --strip-components=1
        fi
        rm "$file"
    done <<<"$dependencies"

    echo "==> Patching"
    replace "$cannonball/src/main/main.cpp" '#include <SDL.h>' '#include <SDL.h>
#include <fstream>
#include <unistd.h>'
    replace "$cannonball/src/main/main.cpp" 'int main(int argc, char* argv[])
{' 'int main(int argc, char* argv[])
{
    // Frontport: play from ~/Library/Application Support/Cannonball, which SDL creates, and start it with a copy of
    // the config.xml the app carries.
    char* prefPath = SDL_GetPrefPath(NULL, "Cannonball");
    if (prefPath == NULL || chdir(prefPath) != 0)
    {
        std::cerr << "Unable to use the data folder: " << SDL_GetError() << std::endl;
        return 1;
    }
    SDL_free(prefPath);
    if (!std::ifstream("config.xml"))
    {
        char* basePath = SDL_GetBasePath();
        std::ifstream defaults(std::string(basePath ? basePath : "") + "config.xml", std::ios::binary);
        std::ofstream("config.xml", std::ios::binary) << defaults.rdbuf();
        SDL_free(basePath);
    }
'
    # The renderer draws with display lists and glBegin, which a core profile lacks. macOS has no 2.1 core profile and
    # answers the request with a 4.1 core one, where all of it draws nothing, so ask for the legacy 2.1 context.
    replace "$cannonball/src/main/sdl2/rendergl.cpp" \
        'SDL_GL_SetAttribute(SDL_GL_CONTEXT_PROFILE_MASK, SDL_GL_CONTEXT_PROFILE_CORE);' \
        'SDL_GL_SetAttribute(SDL_GL_CONTEXT_PROFILE_MASK, SDL_GL_CONTEXT_PROFILE_COMPATIBILITY);'
    # Its Apple-only channel shuffle, for an old SDL, moves red into the alpha byte of the BGRA texture, which tints
    # everything cyan. The surface's own shifts already match that texture.
    replace "$cannonball/src/main/sdl2/rendergl.cpp" '    // This hack is necessary to fix an Apple OpenGL with SDL issue
    #ifdef __APPLE__' '    // Frontport: the surface'"'"'s own shifts match the BGRA texture on current macOS.
    #if 0'
    replace "$cannonball/src/main/frontend/config.cpp" '#include <boost/version.hpp>' '#include <boost/version.hpp>
#include <SDL.h>'
    replace "$cannonball/src/main/frontend/config.cpp" \
        '    data.res_path         = pt_config.get("data.respath", "res/");   // Path to ROMs' \
        '    // Frontport: res/ is in the app'"'"'s Resources, whatever config.xml says.
    char* basePath        = SDL_GetBasePath();
    data.res_path         = std::string(basePath ? basePath : "") + "res/";
    SDL_free(basePath);'

    # The platform file upstream's cmake/CMakeLists.txt includes for -DTARGET=macos.cmake.
    cat >"$cannonball/cmake/macos.cmake" <<'EOF'
# Frontport: OpenGL rendering, as for Linux, with the frameworks static SDL2 needs coming from its CMake target.
set(OPENGL 1)
find_package(OpenGL REQUIRED)
set(platform_link_libs ${OPENGL_LIBRARIES})
EOF
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
    echo "==> Building SDL2"
    cmake -S "$deps/sdl2" -B "$work/sdl2-build" -G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_ARCHITECTURES=arm64 \
        -DCMAKE_OSX_DEPLOYMENT_TARGET=$deployment_target -DCMAKE_INSTALL_PREFIX="$prefix" \
        -DSDL_SHARED=OFF -DSDL_STATIC=ON -DSDL_TEST=OFF
    cmake --build "$work/sdl2-build" -j "$FRONTPORT_JOBS"
    cmake --install "$work/sdl2-build"
    echo "$wanted" >"$stamp"
}

build() {
    build_libraries

    echo "==> Configuring Cannonball"
    rm -rf "$work/build"
    cmake -S "$cannonball/cmake" -B "$work/build" -G Ninja -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=$deployment_target \
        -DCMAKE_FIND_FRAMEWORK=LAST -DTARGET=macos.cmake \
        -Dsdl2_dir="$prefix/lib/cmake/SDL2" -Dboost_dir="$deps/boost" \
        -DCMAKE_CXX_FLAGS="-DGL_SILENCE_DEPRECATION -Wno-deprecated-declarations"

    echo "==> Building Cannonball"
    cmake --build "$work/build" -j "$FRONTPORT_JOBS"
    [ -x "$work/build/cannonball" ] || fail "the build made no cannonball"

    echo "==> Making Cannonball.app"
    local app=$FRONTPORT_OUT/Cannonball.app plist describe version
    plist=$app/Contents/Info.plist
    describe=$(cat "$src/version")                        # v0.34-19-g27493eb
    version=$(echo "$describe" | sed -E 's/^v?([0-9.]+)-([0-9]+)-g.*$/\1.\2/')
    mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources/res"
    cp "$work/build/cannonball" "$app/Contents/MacOS/Cannonball"
    cp "$cannonball/res/config.xml" "$app/Contents/Resources/"
    cp "$cannonball/res/tilemap.bin" "$cannonball/res/tilepatch.bin" "$cannonball/res/gamecontrollerdb.txt" \
        "$app/Contents/Resources/res/"
    cp "$cannonball/docs/license.txt" "$app/Contents/Resources/"
    make_icon "$cannonball/res/icon.png" "$app/Contents/Resources/Cannonball.icns"
    plutil -create xml1 "$plist"
    plutil -insert CFBundleExecutable -string Cannonball "$plist"
    plutil -insert CFBundleIdentifier -string "dev.frontport.port.$FRONTPORT_PORT" "$plist"
    plutil -insert CFBundleName -string Cannonball "$plist"
    plutil -insert CFBundlePackageType -string APPL "$plist"
    plutil -insert CFBundleInfoDictionaryVersion -string 6.0 "$plist"
    plutil -insert CFBundleShortVersionString -string "$version" "$plist"
    plutil -insert CFBundleVersion -string "$version" "$plist"
    plutil -insert CFBundleGetInfoString -string "$describe" "$plist"
    plutil -insert CFBundleIconFile -string Cannonball "$plist"
    plutil -insert LSMinimumSystemVersion -string "$deployment_target" "$plist"
    plutil -insert LSApplicationCategoryType -string public.app-category.racing-games "$plist"
    plutil -insert NSHighResolutionCapable -bool true "$plist"
    plutil -insert NSPrincipalClass -string NSApplication "$plist"
}

# make_icon <png> <icns>: an icns holding upstream's 256×256 PNG as it is.
make_icon() {
    python3 - "$1" "$2" <<'EOF'
import struct, sys
png = open(sys.argv[1], "rb").read()
assert png[:8] == b"\x89PNG\r\n\x1a\n" and struct.unpack(">II", png[16:24]) == (256, 256), "unusable icon"
entries = b"".join(kind + struct.pack(">I", len(png) + 8) + png for kind in (b"ic08", b"ic13"))
open(sys.argv[2], "wb").write(b"icns" + struct.pack(">I", len(entries) + 8) + entries)
EOF
}

case "$step" in
    fetch) fetch ;;
    build) build ;;
    *) fail "unknown step $step" ;;
esac
