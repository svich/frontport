#!/bin/bash
# Frontport Recipe: Fallout Community Edition (alexbatalov/fallout1-ce), a re-implementation of Fallout's engine.
# Contract: catalog/recipes/README.md. Invoked as `fallout-ce.sh fetch`, then `fallout-ce.sh build`.
#
# Upstream's macOS app plays from the folder it sits in, beside master.dat, critter.dat and data/, and writes
# fallout.cfg and its saves there. A sandboxed app can't write beside itself, so fetch patches it to play from
# ~/Library/Application Support/Fallout instead (inside the container under the App Sandbox), where Frontport
# Seeds the game's files, and to look for music where the CD keeps it too. Upstream's CMake fetches SDL2, adecode
# and fpattern with git at configure time; fetch downloads pinned archives of them instead, and build points
# FetchContent at those.
set -euo pipefail

step=${1:?usage: fallout-ce.sh fetch|build}
src=$FRONTPORT_SRC
work=$(dirname "$src")
deps=$src/deps
fallout=$src/fallout1-ce
deployment_target=13.0
export MACOSX_DEPLOYMENT_TARGET=$deployment_target
export GIT_CEILING_DIRECTORIES=$work

# name sha256 url. adecode and fpattern are the commits upstream's third_party/*/CMakeLists.txt pin. SDL2 is newer
# than upstream's 2.26.1, for current macOS.
dependencies="
sdl2 5f5993c530f084535c65a6879e9b26ad441169b3e25d789d83287040a9ca5165 https://github.com/libsdl-org/SDL/releases/download/release-2.32.10/SDL2-2.32.10.tar.gz
adecode 9b532446543ae6f39370688c90a4df0951828573f1082f5004f76f76d278c081 https://github.com/alexbatalov/adecode/archive/e4a8b0f3b66826e0b7779a25d79df8497f8f8087.tar.gz
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
    echo "==> Cloning fallout1-ce $FRONTPORT_REF"
    git clone --quiet https://github.com/alexbatalov/fallout1-ce.git "$fallout"
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
    replace "$fallout/src/plib/gnw/winmain.cc" '    char* basePath = SDL_GetBasePath();
    chdir(basePath);' '    // Frontport: play from ~/Library/Application Support/Fallout, which SDL creates.
    char* basePath = SDL_GetPrefPath(NULL, "Fallout");
    chdir(basePath);'
    # Music is looked up in music_path1, then music_path2, both sound\music\ by default. The CD keeps it in
    # DATA\SOUND\MUSIC\, where its installer pointed music_path2, so make that the default for the second. Level
    # music found only there is copied into music_path1 first, as from a CD to the hard disk, which fails when that
    # folder doesn't exist, so play it where it is instead.
    replace "$fallout/src/game/gconfig.cc" \
        'GAME_CONFIG_MUSIC_PATH2_KEY, "sound\\music\\");' 'GAME_CONFIG_MUSIC_PATH2_KEY, "data\\sound\\music\\");'
    replace "$fallout/src/game/gsound.cc" \
        'rc = gsound_background_find_with_copy(path, fileName);' 'rc = gsound_background_find_dont_copy(path, fileName);'
}

build() {
    echo "==> Configuring fallout1-ce"
    rm -rf "$work/build"
    cmake -S "$fallout" -B "$work/build" -G Ninja -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=$deployment_target \
        -DFETCHCONTENT_FULLY_DISCONNECTED=ON \
        -DFETCHCONTENT_SOURCE_DIR_SDL2="$deps/sdl2" \
        -DFETCHCONTENT_SOURCE_DIR_ADECODE="$deps/adecode" \
        -DFETCHCONTENT_SOURCE_DIR_FPATTERN="$deps/fpattern"

    echo "==> Building fallout1-ce"
    cmake --build "$work/build" -j "$FRONTPORT_JOBS"

    local app="$work/build/Fallout Community Edition.app" plist describe version
    [ -d "$app" ] || fail "the build made no app"
    plist=$app/Contents/Info.plist
    describe=$(cat "$src/version")                        # v1.1.0-7-g0609bcf
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
