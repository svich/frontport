#!/bin/bash
# Frontport Recipe: Fallout 2 Community Edition (alexbatalov/fallout2-ce), a re-implementation of Fallout 2's engine.
# Contract: catalog/recipes/README.md. Invoked as `fallout2-ce.sh fetch`, then `fallout2-ce.sh build`.
#
# Upstream's macOS app plays from the folder it sits in, beside master.dat, critter.dat, patch000.dat, data/ and
# sound/, and writes fallout2.cfg and its saves there. A sandboxed app can't write beside itself, so fetch patches it
# to play from ~/Library/Application Support/Fallout 2 instead (inside the container under the App Sandbox), where
# Frontport Seeds the game's files. Upstream's CMake fetches SDL2, zlib and fpattern with git at configure time;
# fetch downloads pinned archives of them instead, and build points FetchContent at those.
set -euo pipefail

step=${1:?usage: fallout2-ce.sh fetch|build}
src=$FRONTPORT_SRC
work=$(dirname "$src")
deps=$src/deps
fallout=$src/fallout2-ce
deployment_target=13.0
export MACOSX_DEPLOYMENT_TARGET=$deployment_target
export GIT_CEILING_DIRECTORIES=$work

# name sha256 url. zlib and fpattern are the versions upstream's third_party/*/CMakeLists.txt pin. SDL2 is newer
# than upstream's 2.26.1, for current macOS.
dependencies="
sdl2 5f5993c530f084535c65a6879e9b26ad441169b3e25d789d83287040a9ca5165 https://github.com/libsdl-org/SDL/releases/download/release-2.32.10/SDL2-2.32.10.tar.gz
zlib 9a93b2b7dfdac77ceba5a558a580e74667dd6fede4585b91eefb60f03b72df23 https://github.com/madler/zlib/releases/download/v1.3.1/zlib-1.3.1.tar.gz
fpattern 20718b12387482ca0f8fdb9da129b8c876dd9cd5086ba4ed1d45e5ef57c06bfc https://github.com/alexbatalov/fpattern/archive/8523173ec252c3b796fcdfca0fcc6329642fbbe3.tar.gz
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
    echo "==> Cloning fallout2-ce $FRONTPORT_REF"
    git clone --quiet https://github.com/alexbatalov/fallout2-ce.git "$fallout"
    git -C "$fallout" -c advice.detachedHead=false checkout --quiet "$FRONTPORT_REF"
    git -C "$fallout" describe --tags --long >"$src/version" 2>/dev/null || echo "v0-0-g$FRONTPORT_REF" >"$src/version"

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
    replace "$fallout/src/win32.cc" '#if __APPLE__ && TARGET_OS_OSX
    char* basePath = SDL_GetBasePath();' '#if __APPLE__ && TARGET_OS_OSX
    // Frontport: play from ~/Library/Application Support/Fallout 2, which SDL creates.
    char* basePath = SDL_GetPrefPath(NULL, "Fallout 2");'
}

build() {
    echo "==> Configuring fallout2-ce"
    rm -rf "$work/build"
    cmake -S "$fallout" -B "$work/build" -G Ninja -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=$deployment_target \
        -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
        -DFETCHCONTENT_FULLY_DISCONNECTED=ON \
        -DFETCHCONTENT_SOURCE_DIR_SDL2="$deps/sdl2" \
        -DFETCHCONTENT_SOURCE_DIR_ZLIB="$deps/zlib" \
        -DFETCHCONTENT_SOURCE_DIR_FPATTERN="$deps/fpattern"

    echo "==> Building fallout2-ce"
    cmake --build "$work/build" -j "$FRONTPORT_JOBS"

    local app="$work/build/Fallout II Community Edition.app" plist describe version
    [ -d "$app" ] || fail "the build made no app"
    plist=$app/Contents/Info.plist
    describe=$(cat "$src/version")                        # v1.3.0-59-ge97087b
    version=$(echo "$describe" | sed -E 's/^v?([0-9.]+)-([0-9]+)-g.*$/\1.\2/')
    plutil -replace CFBundleShortVersionString -string "$version" "$plist"
    plutil -replace CFBundleVersion -string "$version" "$plist"
    plutil -replace CFBundleGetInfoString -string "$describe" "$plist"
    plutil -replace LSMinimumSystemVersion -string "$deployment_target" "$plist"
    cp -R "$app" "$FRONTPORT_OUT/"
}

case "$step" in
    fetch) fetch ;;
    build) build ;;
    *) fail "unknown step $step" ;;
esac
