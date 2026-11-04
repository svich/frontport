#!/bin/bash
# Frontport Recipe: OpenTTD, the open-source remake of Transport Tycoon Deluxe.
# Contract: catalog/recipes/README.md. Invoked as `openttd.sh fetch`, then `openttd.sh build`.
#
# Upstream's macOS Release is a universal app signed and notarized by the OpenTTD team. This builds the same app
# from source with upstream's CMake, against static liblzma (its saved games) and libpng (screenshots and
# heightmaps), and the SDK's zlib and libcurl (online content and the server list). It puts the free base sets in
# the app's Resources/baseset, as upstream's installer would download them: OpenGFX's graphics, OpenSFX's sounds
# and OpenMSX's music, all GPL. So there are no ROMs and no Build Assets; the original game's files can be added
# to the Port's Data, where OpenTTD finds them too.
# OpenTTD reads the app's Resources itself (CocoaSetApplicationBundleDir) and keeps its settings, saved games,
# screenshots and downloaded content in ~/Documents/OpenTTD, which the App Sandbox puts in the container.
# fetch patches one race: OTTD2FS and FS2OTTD share one iconv handle between the Cocoa main thread and the game
# thread, which both look up files at launch, and macOS's iconv aborts when two threads convert at once
# (`tmpin > *in` in citrus_iconv_std.c). Each thread gets its own handle. Upstream's deployment target, 10.15, is
# raised to the libraries' 13.0.
set -euo pipefail

step=${1:?usage: openttd.sh fetch|build}
src=$FRONTPORT_SRC
work=$(dirname "$src")                 # Builds/<port>: writable during build, kept between builds
deps=$src/deps
basesets=$src/baseset
openttd=$src/OpenTTD
prefix=$work/prefix                    # the static libraries, reused while their pins don't change
deployment_target=13.0
export MACOSX_DEPLOYMENT_TARGET=$deployment_target
export GIT_CEILING_DIRECTORIES=$work

# Commits of the tags this Recipe was tested against, so a moved tag fails the fetch.
known_commit() {
    case "$1" in
        15.3) echo 14ec60f248547d4d062a1160f0fc26d742319888 ;;
    esac
}

dependencies="
xz 4ce24038fd4221e0d13bc1a2de7a4db56e90b92b3bf75321f6c14be73f65de4b https://github.com/tukaani-project/xz/releases/download/v5.8.4/xz-5.8.4.tar.xz
libpng d80dd2a38a37f803cb9b6ac7b14bd6e74ddc3b654780a8380bdf93523fdb4389 https://download.sourceforge.net/libpng/libpng-1.6.59.tar.xz
"

# The free base sets, each a zip of one tar.
basesets_list="
opengfx-8.0-all.zip 43a0c1dabf39cb865394f3a6cc36d4da5c10ecfaaf55652043104806810903be https://cdn.openttd.org/opengfx-releases/8.0/opengfx-8.0-all.zip
opensfx-1.0.3-all.zip e0a218b7dd9438e701503b0f84c25a97c1c11b7c2f025323fb19d6db16ef3759 https://cdn.openttd.org/opensfx-releases/1.0.3/opensfx-1.0.3-all.zip
openmsx-0.4.2-all.zip 5a4277a2e62d87f2952ea5020dc20fb2f6ffafdccf9913fbf35ad45ee30ec762 https://cdn.openttd.org/openmsx-releases/0.4.2/openmsx-0.4.2-all.zip
"

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
    echo "==> Cloning OpenTTD $FRONTPORT_REF"
    git -c advice.detachedHead=false clone --quiet --depth 1 --branch "$FRONTPORT_REF" \
        https://github.com/OpenTTD/OpenTTD.git "$openttd"
    local expected actual
    expected=$(known_commit "$FRONTPORT_REF")
    actual=$(git -C "$openttd" rev-parse HEAD)
    if [ -n "$expected" ] && [ "$actual" != "$expected" ]; then
        fail "$FRONTPORT_REF is $actual upstream, but this Recipe was tested with $expected"
    fi
    echo "$FRONTPORT_REF" >"$src/version"
    replace "$openttd/src/os/unix/unix.cpp" 'static const auto convd = OpenIconv(' \
        'static thread_local const auto convd = OpenIconv('
    # Upstream sets 10.15 over the cache, while the libraries are built for the Recipe's target.
    replace "$openttd/CMakeLists.txt" 'set(CMAKE_OSX_DEPLOYMENT_TARGET 10.15)' \
        "set(CMAKE_OSX_DEPLOYMENT_TARGET $deployment_target)"

    mkdir -p "$deps" "$basesets"
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
    while read -r name sha url; do
        [ -n "$name" ] || continue
        echo "==> Downloading $name"
        download "$deps/$name" "$sha" "$url"
        unzip -q -o "$deps/$name" -d "$basesets"
        rm "$deps/$name"
    done <<<"$basesets_list"
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
    cmake_static xz -DXZ_TOOL_XZ=OFF -DXZ_TOOL_XZDEC=OFF -DXZ_TOOL_LZMADEC=OFF -DXZ_TOOL_LZMAINFO=OFF \
        -DXZ_TOOL_SCRIPTS=OFF -DXZ_DOC=OFF -DXZ_NLS=OFF -DBUILD_TESTING=OFF
    cmake_static libpng -DPNG_SHARED=OFF -DPNG_STATIC=ON -DPNG_TESTS=OFF -DPNG_TOOLS=OFF -DPNG_FRAMEWORK=OFF
    echo "$wanted" >"$stamp"
}

build() {
    build_libraries

    echo "==> Building OpenTTD"
    # Only the libraries above and the SDK's: no LZO (saved games from before 0.3), no FluidSynth or Opus, and no
    # crash reporter.
    local build=$work/openttd-build
    cmake -S "$openttd" -B "$build" -G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_ARCHITECTURES=arm64 \
        -DCMAKE_OSX_DEPLOYMENT_TARGET=$deployment_target -DCMAKE_PREFIX_PATH="$prefix" -DCMAKE_FIND_FRAMEWORK=LAST \
        -DCMAKE_DISABLE_FIND_PACKAGE_LZO=ON -DCMAKE_DISABLE_FIND_PACKAGE_OpusFile=ON \
        -DCMAKE_DISABLE_FIND_PACKAGE_unofficial-breakpad=ON -DCMAKE_DISABLE_FIND_PACKAGE_Grfcodec=ON \
        -DCMAKE_DISABLE_FIND_PACKAGE_Pandoc=ON -DCMAKE_DISABLE_FIND_PACKAGE_Doxygen=ON \
        -DOPTION_USE_ASSERTS=OFF -DOPTION_INSTALL_FHS=OFF
    cmake --build "$build" -j "$FRONTPORT_JOBS" --target openttd

    echo "==> Making OpenTTD.app"
    local app=$FRONTPORT_OUT/OpenTTD.app plist version resources
    plist=$app/Contents/Info.plist
    resources=$app/Contents/Resources
    version=$(cat "$src/version")
    mkdir -p "$app/Contents/MacOS" "$resources"
    cp "$build/openttd" "$app/Contents/MacOS/openttd"
    # What upstream's install puts beside the game: languages, the base sets' metadata, AI and game script
    # libraries, and the documents its in-game viewer shows.
    cp -R "$build/lang" "$build/baseset" "$build/ai" "$build/game" "$openttd/bin/scripts" "$resources/"
    find "$resources/ai" -mindepth 1 -type d -prune -exec rm -rf {} +
    # Graphics and sounds load from their tars; music sets can't, so OpenMSX is unpacked into its folder.
    cp "$basesets"/opengfx-*.tar "$basesets"/opensfx-*.tar "$resources/baseset/"
    tar -xf "$basesets"/openmsx-*.tar -C "$resources/baseset/"
    cp "$openttd"/{COPYING,README,CREDITS,CONTRIBUTING,changelog,known-bugs}.md "$resources/"
    cp "$openttd/os/macosx/openttd.icns" "$resources/OpenTTD.icns"
    plutil -create xml1 "$plist"
    plutil -insert CFBundleExecutable -string openttd "$plist"
    plutil -insert CFBundleIdentifier -string "dev.frontport.port.$FRONTPORT_PORT" "$plist"
    plutil -insert CFBundleName -string OpenTTD "$plist"
    plutil -insert CFBundleDisplayName -string OpenTTD "$plist"
    plutil -insert CFBundlePackageType -string APPL "$plist"
    plutil -insert CFBundleInfoDictionaryVersion -string 6.0 "$plist"
    plutil -insert CFBundleShortVersionString -string "$version" "$plist"
    plutil -insert CFBundleVersion -string "$version" "$plist"
    plutil -insert CFBundleIconFile -string OpenTTD.icns "$plist"
    plutil -insert LSMinimumSystemVersion -string "$deployment_target" "$plist"
    plutil -insert LSApplicationCategoryType -string public.app-category.simulation-games "$plist"
    plutil -insert NSHighResolutionCapable -bool true "$plist"
    plutil -insert NSPrincipalClass -string NSApplication "$plist"
}

case "$step" in
    fetch) fetch ;;
    build) build ;;
    *) fail "unknown step $step" ;;
esac
