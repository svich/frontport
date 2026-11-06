#!/bin/bash
# Frontport Recipe: ScummVM, the engine collection that plays classic adventure games on their original files.
# Contract: catalog/recipes/README.md. Invoked as `scummvm.sh fetch`, then `scummvm.sh build`.
#
# ScummVM's Mac app is published on scummvm.org, not as a GitHub Release asset, so this builds the same app from
# source with upstream's configure and its `bundle-pack` target, for the engines the Catalog's ScummVM Ports play
# (SCUMM, for LucasArts' games), against static SDL2, libogg, libvorbis, FreeType, libpng, libjpeg-turbo and
# libmad (the Special Edition's MP3 sounds).
# Each Port's game is a Runtime-Stage folder ROM Seeded into Library/Application Support/ScummVM/<game>; the entry's
# launch arguments point ScummVM at it (it expands ~ itself) and start the game. ScummVM already keeps its settings
# in ~/Library/Preferences and its saves in ~/Documents, the container's.
# configure and make can't take paths with spaces, and every Frontport build folder has one (Application Support),
# so ScummVM is configured and built in Builds/<port>/build with paths relative to it, and sdl2-config and
# freetype-config are small scripts that answer with those.
set -euo pipefail

step=${1:?usage: scummvm.sh fetch|build}
src=$FRONTPORT_SRC
work=$(dirname "$src")                 # Builds/<port>: writable during build, kept between builds
deps=$src/deps
scummvm=$src/scummvm
prefix=$work/prefix                    # the static libraries, reused while their pins don't change
deployment_target=13.0
export MACOSX_DEPLOYMENT_TARGET=$deployment_target
export GIT_CEILING_DIRECTORIES=$work
export CMAKE_POLICY_VERSION_MINIMUM=3.5 # vorbis still declares cmake_minimum_required(2.8.12)

# The commit each tag the Catalog may pin is known to be.
known_tags="
v2026.4.0 7d2709da5136866589f7602f5f5a7b17de03420e
"

dependencies="
sdl2 5f5993c530f084535c65a6879e9b26ad441169b3e25d789d83287040a9ca5165 https://github.com/libsdl-org/SDL/releases/download/release-2.32.10/SDL2-2.32.10.tar.gz
ogg 83e6704730683d004d20e21b8f7f55dcb3383cdf84c0daedf30bde175f774638 https://github.com/xiph/ogg/releases/download/v1.3.6/libogg-1.3.6.tar.gz
vorbis 0e982409a9c3fc82ee06e08205b1355e5c6aa4c36bca58146ef399621b0ce5ab https://github.com/xiph/vorbis/releases/download/v1.3.7/libvorbis-1.3.7.tar.gz
freetype 36bc4f1cc413335368ee656c42afca65c5a3987e8768cc28cf11ba775e785a5f https://download.savannah.gnu.org/releases/freetype/freetype-2.14.3.tar.xz
libpng d80dd2a38a37f803cb9b6ac7b14bd6e74ddc3b654780a8380bdf93523fdb4389 https://download.sourceforge.net/libpng/libpng-1.6.59.tar.xz
libjpeg-turbo c27ad72a68da151177929aa969ae773a2da5ac2af9ce946079314fdac8cece7f https://github.com/libjpeg-turbo/libjpeg-turbo/releases/download/3.2.1/libjpeg-turbo-3.2.1.tar.gz
libmad f4eb229452252600ce48f3c2704c9e6d97b789f81e31c37b0c67dd66f445ea35 https://codeberg.org/tenacityteam/libmad/archive/0.16.4.tar.gz
"

# The engines built: SCUMM, with its v7 and v8 games.
engines=scumm,scumm_7_8

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

download() {
    local file=$1 sha=$2 url=$3
    curl -fsSL --retry 3 -o "$file" "$url"
    echo "$sha  $file" | shasum -a 256 -c --status - || fail "$(basename "$file") doesn't match its pinned sha256"
}

fetch() {
    echo "==> Cloning ScummVM $FRONTPORT_REF"
    git clone --quiet --filter=blob:none --no-checkout https://github.com/scummvm/scummvm.git "$scummvm"
    git -C "$scummvm" -c advice.detachedHead=false checkout --quiet "$FRONTPORT_REF"
    local tag commit head
    head=$(git -C "$scummvm" rev-parse HEAD)
    while read -r tag commit; do
        [ -n "$tag" ] || continue
        if [ "$FRONTPORT_REF" = "$tag" ] && [ "$head" != "$commit" ]; then
            fail "tag $tag is $head, not the expected $commit"
        fi
    done <<<"$known_tags"
    git -C "$scummvm" describe --tags --always >"$src/version"
    rm -rf "$scummvm/.git"

    echo "==> Patching"
    # Frontport signs the app; the bundle is left unsigned.
    replace "$scummvm/ports.mk" '	cp -r scummvm.docktileplugin $(bundle_name)/Contents/PlugIns/
endif
ifndef MACOSX_LEOPARD_OR_BELOW
	codesign -s - --deep --force $(bundle_name)
endif' '	cp -r scummvm.docktileplugin $(bundle_name)/Contents/PlugIns/
endif'
    # Fullscreen by default, which ScummVM's SDL backend makes a fullscreen window at the desktop's resolution; a
    # player's own setting still wins.
    replace "$scummvm/base/commandLine.cpp" '	ConfMan.registerDefault("fullscreen", false);' \
        '	ConfMan.registerDefault("fullscreen", true); // Frontport: a fullscreen window by default'

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

# cmake_static <name> [options…]: builds a fetched dependency into the prefix as a static library.
cmake_static() {
    local name=$1
    shift
    echo "==> Building $name"
    cmake -S "$deps/$name" -B "$work/libraries-build/$name" -G Ninja -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=$deployment_target \
        -DCMAKE_INSTALL_PREFIX="$prefix" -DCMAKE_PREFIX_PATH="$prefix" -DCMAKE_FIND_FRAMEWORK=LAST \
        -DCMAKE_INSTALL_LIBDIR=lib -DBUILD_SHARED_LIBS=OFF "$@"
    cmake --build "$work/libraries-build/$name" -j "$FRONTPORT_JOBS"
    cmake --install "$work/libraries-build/$name"
}

build_libraries() {
    local stamp=$prefix/.frontport-libraries
    local wanted
    wanted=$(echo "$dependencies $deployment_target" | shasum -a 256 | cut -d' ' -f1)
    if [ -f "$stamp" ] && [ "$(cat "$stamp")" = "$wanted" ]; then
        echo "==> Reusing the libraries in $prefix"
        return
    fi
    rm -rf "$prefix" "$work/libraries-build"
    cmake_static sdl2 -DSDL_SHARED=OFF -DSDL_STATIC=ON -DSDL_TEST=OFF
    cmake_static ogg -DINSTALL_DOCS=OFF -DBUILD_TESTING=OFF
    cmake_static vorbis -DBUILD_TESTING=OFF
    cmake_static freetype -DFT_DISABLE_BZIP2=ON -DFT_DISABLE_PNG=ON -DFT_DISABLE_HARFBUZZ=ON \
        -DFT_DISABLE_BROTLI=ON -DFT_REQUIRE_ZLIB=ON
    cmake_static libpng -DPNG_SHARED=OFF -DPNG_STATIC=ON -DPNG_FRAMEWORK=OFF -DPNG_TESTS=OFF -DPNG_TOOLS=OFF
    cmake_static libjpeg-turbo -DENABLE_SHARED=OFF -DENABLE_STATIC=ON -DWITH_TURBOJPEG=OFF -DWITH_TOOLS=OFF \
        -DWITH_TESTS=OFF
    cmake_static libmad -DEXAMPLE=OFF

    rm -rf "$work/libraries-build"
    echo "$wanted" >"$stamp"
}

build() {
    build_libraries

    # ScummVM is configured and made in $work/build, which sees the source and the prefix at these paths.
    local build=$work/build rel_src=../src/scummvm rel_prefix=../prefix tools=$work/tools sdl_version
    sdl_version=$(sed -n 's/^Version: //p' "$prefix/lib/pkgconfig/sdl2.pc")
    rm -rf "$build" "$tools"
    mkdir -p "$build" "$tools"
    [ "$(cd "$build/$rel_src" && pwd -P)" = "$(cd "$scummvm" && pwd -P)" ] || fail "the source isn't at $rel_src"

    # sdl2-config and freetype-config that name the static libraries by the relative paths.
    local frameworks="-framework Cocoa -framework IOKit -framework CoreAudio -framework AudioToolbox"
    frameworks+=" -framework ForceFeedback -framework Carbon -framework CoreVideo -framework GameController"
    frameworks+=" -framework CoreHaptics -framework Metal -framework QuartzCore -framework AVFoundation"
    frameworks+=" -framework CoreFoundation -framework CoreGraphics -framework UniformTypeIdentifiers"
    frameworks+=" -weak_framework CoreHaptics -lc++ -liconv -lm"
    cat >"$tools/sdl2-config" <<EOF
#!/bin/sh
for arg in "\$@"; do
    case "\$arg" in
        --prefix*) echo "$rel_prefix" ;;
        --version) echo "$sdl_version" ;;
        --cflags) echo "-I$rel_prefix/include/SDL2 -D_THREAD_SAFE" ;;
        --libs|--static-libs) echo "$rel_prefix/lib/libSDL2.a $frameworks" ;;
    esac
done
EOF
    cat >"$tools/freetype-config" <<EOF
#!/bin/sh
for arg in "\$@"; do
    case "\$arg" in
        --cflags) echo "-I$rel_prefix/include/freetype2" ;;
        --libs) echo "$rel_prefix/lib/libfreetype.a -lz" ;;
        --version) echo 2.14.3 ;;
    esac
done
EOF
    chmod +x "$tools/sdl2-config" "$tools/freetype-config"

    echo "==> Configuring ScummVM"
    cd "$build"
    # No pkg-config on the PATH, so configure takes every library from the prefixes it's given.
    CC=clang CXX=clang++ "$rel_src/configure" --enable-release --disable-debug \
        --disable-all-engines --enable-engine="$engines" --disable-detection-full \
        --with-staticlib-prefix="$rel_prefix" --with-sdl-prefix="../tools" \
        --with-vorbis-prefix="$rel_prefix" --with-ogg-prefix="$rel_prefix" \
        --with-png-prefix="$rel_prefix" --with-jpeg-prefix="$rel_prefix" --with-mad-prefix="$rel_prefix" \
        --with-freetype2-prefix=../tools \
        --enable-freetype2 --enable-vorbis --disable-theoradec --enable-png --enable-jpeg --enable-mad \
        --disable-tremor --disable-flac --disable-mpeg2 --disable-a52 --disable-faad --disable-gif --disable-vpx \
        --disable-fribidi --disable-fluidsynth --disable-fluidlite --disable-mikmod --disable-openmpt \
        --disable-libcurl --disable-sdlnet --disable-cloud --disable-enet --disable-discord --disable-sparkle \
        --disable-updates --disable-libunity --disable-readline --disable-tts --disable-mpcdec --disable-retrowave \
        --disable-sonivox
    echo "==> Building ScummVM"
    PATH=$tools:$PATH make -j "$FRONTPORT_JOBS" scummvm

    echo "==> Making ScummVM.app"
    cp scummvm scummvm-static
    # Without the Dock tile plugin, which only shows the running game's icon and isn't built by `make scummvm`.
    PATH=$tools:$PATH make bundle-pack STRIP=strip USE_DOCKTILEPLUGIN=
    local app=$FRONTPORT_OUT/ScummVM.app plist version
    mv ScummVM.app "$app"
    plist=$app/Contents/Info.plist
    version=$(cat "$src/version")
    version=${version#v}
    plutil -replace CFBundleIdentifier -string "dev.frontport.port.$FRONTPORT_PORT" "$plist"
    plutil -replace CFBundleShortVersionString -string "${version%%-*}" "$plist"
    plutil -replace CFBundleVersion -string "${version%%-*}" "$plist"
    plutil -replace LSMinimumSystemVersion -string "$deployment_target" "$plist"
    otool -L "$app/Contents/MacOS/scummvm" | grep -E '^\s' | grep -vE '/System/Library/|/usr/lib/' \
        && fail "ScummVM links libraries outside the system"
    return 0
}

case "$step" in
    fetch) fetch ;;
    build) build ;;
    *) fail "unknown step $step" ;;
esac
