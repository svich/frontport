#!/bin/bash
# Frontport Recipe: Arcanum Community Edition (alexbatalov/arcanum-ce), a re-implementation of Arcanum's engine.
# Contract: catalog/recipes/README.md. Invoked as `arcanum-ce.sh fetch`, then `arcanum-ce.sh build`.
#
# Upstream's macOS app plays from the folder it sits in (SDL's base path, which its Info.plist sets to the app's
# parent), beside arcanum1.dat, tig.dat, modules/ and data/, and writes arcanum.cfg and its saves there. A sandboxed
# app can't write beside itself, so fetch patches it to play from ~/Library/Application Support/Arcanum instead
# (inside the container under the App Sandbox), where Frontport Seeds the game's files. Upstream's CMake fetches
# SDL3, SDL3_mixer, zlib and fpattern with git at configure time; fetch downloads pinned archives of them instead,
# and build points FetchContent at those. All four link statically.
set -euo pipefail

step=${1:?usage: arcanum-ce.sh fetch|build}
src=$FRONTPORT_SRC
work=$(dirname "$src")
deps=$src/deps
arcanum=$src/arcanum-ce
deployment_target=13.0
export MACOSX_DEPLOYMENT_TARGET=$deployment_target
export GIT_CEILING_DIRECTORIES=$work

# name sha256 url: the releases upstream's third_party/*/CMakeLists.txt pin, and fpattern's v1.9.1 tag as a commit.
dependencies="
sdl3 e9fff7467fb60f037e6708da18b25560649e4c63edc2a69bb871b960d9cbfbba https://github.com/libsdl-org/SDL/releases/download/release-3.4.8/SDL3-3.4.8.tar.gz
sdl3_mixer cdb6d2a9f01bb3c1b98c957ee12109dd6ec1a1157682c9bc8523b0fe8ab2da1e https://github.com/libsdl-org/SDL_mixer/releases/download/release-3.2.2/SDL3_mixer-3.2.2.tar.gz
zlib bb329a0a2cd0274d05519d61c667c062e06990d72e125ee2dfa8de64f0119d16 https://github.com/madler/zlib/releases/download/v1.3.2/zlib-1.3.2.tar.gz
fpattern 7e98897e8dc96caf7340f7d3aa17d53aa9a9baec4039039c6e3416ba2a652df0 https://github.com/alexbatalov/fpattern/archive/992b9685380ebb6bfd037856ececec1da2e3742e.tar.gz
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
    echo "==> Cloning arcanum-ce $FRONTPORT_REF"
    git clone --quiet https://github.com/alexbatalov/arcanum-ce.git "$arcanum"
    git -C "$arcanum" -c advice.detachedHead=false checkout --quiet "$FRONTPORT_REF"
    # Upstream has no tags: the version is the commit's date, and its hash describes it.
    git -C "$arcanum" log -1 --format='%cs %H' >"$src/version"

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
    replace "$arcanum/src/main.c" '#if SDL_PLATFORM_MACOS
    chdir(SDL_GetBasePath());' '#if SDL_PLATFORM_MACOS
    // Frontport: play from ~/Library/Application Support/Arcanum, which SDL creates.
    chdir(SDL_GetPrefPath(NULL, "Arcanum"));'
}

build() {
    echo "==> Configuring arcanum-ce"
    rm -rf "$work/build"
    cmake -S "$arcanum" -B "$work/build" -G Ninja -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=$deployment_target \
        -DFETCHCONTENT_FULLY_DISCONNECTED=ON \
        -DFETCHCONTENT_SOURCE_DIR_SDL3="$deps/sdl3" \
        -DFETCHCONTENT_SOURCE_DIR_SDL3_MIXER="$deps/sdl3_mixer" \
        -DFETCHCONTENT_SOURCE_DIR_ZLIB="$deps/zlib" \
        -DFETCHCONTENT_SOURCE_DIR_FPATTERN="$deps/fpattern"

    echo "==> Building arcanum-ce"
    cmake --build "$work/build" -j "$FRONTPORT_JOBS"

    local app="$work/build/Arcanum Community Edition.app" plist date hash version
    [ -d "$app" ] || fail "the build made no app"
    plist=$app/Contents/Info.plist
    read -r date hash <"$src/version"                      # 2026-05-13 a7ff41b300ef…
    version=${date//-/}                                     # 20260513
    plutil -replace CFBundleShortVersionString -string "$version" "$plist"
    plutil -replace CFBundleVersion -string "$version" "$plist"
    plutil -replace CFBundleGetInfoString -string "$date-g${hash:0:7}" "$plist"
    plutil -replace LSMinimumSystemVersion -string "$deployment_target" "$plist"
    cp -R "$app" "$FRONTPORT_OUT/"
}

case "$step" in
    fetch) fetch ;;
    build) build ;;
    *) fail "unknown step $step" ;;
esac
