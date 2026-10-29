#!/bin/bash
# Frontport Recipe: Dethrace (dethrace-labs/dethrace), a Carmageddon Decomp.
# Contract: catalog/recipes/README.md. Invoked as `dethrace.sh fetch`, then `dethrace.sh build`.
#
# Upstream's macOS Release loads SDL at run time from /Library/Frameworks or beside its executable and ships
# none, so this builds Deth Race.app against a static SDL2 instead. No Build Assets and no patches: with no
# dethrace.ini, no DETHRACE_ROOT_DIR and no DATA/GENERAL.TXT in the working directory, dethrace plays the game
# in ~/Library/Application Support/dethrace, which the App Sandbox puts in the container, where Frontport
# Seeds the game folder and dethrace keeps its options, key maps and saves.
set -euo pipefail

step=${1:?usage: dethrace.sh fetch|build}
src=$FRONTPORT_SRC
work=$(dirname "$src")                 # Builds/<port>: writable during build, kept between builds
deps=$src/deps
dethrace=$src/dethrace
prefix=$work/prefix                    # SDL2, reused while its pin doesn't change
deployment_target=13.0
export MACOSX_DEPLOYMENT_TARGET=$deployment_target
export GIT_CEILING_DIRECTORIES=$work

# Commits of the tags this Recipe was tested against, so a moved tag fails the fetch.
known_commit() {
    case "$1" in
        v0.10.1) echo 9fa3bb2b550e9ab8784134c2ba9781c28c50427b ;;
    esac
}

dependencies="
sdl2 5f5993c530f084535c65a6879e9b26ad441169b3e25d789d83287040a9ca5165 https://github.com/libsdl-org/SDL/releases/download/release-2.32.10/SDL2-2.32.10.tar.gz
"

fail() {
    echo "error: $*" >&2
    exit 1
}

fetch() {
    echo "==> Cloning dethrace $FRONTPORT_REF"
    git clone --quiet https://github.com/dethrace-labs/dethrace.git "$dethrace"
    git -C "$dethrace" -c advice.detachedHead=false checkout --quiet "$FRONTPORT_REF"
    local expected
    expected=$(known_commit "$FRONTPORT_REF")
    if [ -n "$expected" ] && [ "$(git -C "$dethrace" rev-parse HEAD)" != "$expected" ]; then
        fail "$FRONTPORT_REF no longer points at $expected"
    fi
    echo "==> Cloning BRender"
    git -C "$dethrace" submodule --quiet update --init --recursive

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

build_sdl2() {
    local stamp=$prefix/.frontport-libraries
    local wanted
    wanted=$(echo "$dependencies $deployment_target" | shasum -a 256 | cut -d' ' -f1)
    if [ -f "$stamp" ] && [ "$(cat "$stamp")" = "$wanted" ]; then
        echo "==> Reusing SDL2 in $prefix"
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
    build_sdl2

    echo "==> Building dethrace"
    # DETHRACE_INSTALL makes the target an app bundle; its install step, which would bundle SDL from
    # /Library/Frameworks, is never run.
    rm -rf "$work/build"
    cmake -S "$dethrace" -B "$work/build" -G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_ARCHITECTURES=arm64 \
        -DCMAKE_OSX_DEPLOYMENT_TARGET=$deployment_target -DCMAKE_PREFIX_PATH="$prefix" -DCMAKE_FIND_FRAMEWORK=NEVER \
        -DDETHRACE_INSTALL=ON -DDETHRACE_PLATFORM_SDL2=ON -DDETHRACE_PLATFORM_SDL_DYNAMIC=OFF -DBUILD_TESTS=OFF
    cmake --build "$work/build" -j "$FRONTPORT_JOBS"

    echo "==> Making Deth Race.app"
    local app=$FRONTPORT_OUT/Deth\ Race.app plist executable version
    cp -R "$work/build/Deth Race.app" "$app"
    plist=$app/Contents/Info.plist
    executable=$app/Contents/MacOS/Deth\ Race
    [ -x "$executable" ] || fail "the build made no Deth Race executable"
    if otool -L "$executable" | grep -q -i sdl; then
        fail "Deth Race links SDL dynamically"
    fi
    version=$(plutil -extract CFBundleShortVersionString raw "$plist")  # v0.10.1
    version=${version#v}
    plutil -replace CFBundleIdentifier -string "dev.frontport.port.$FRONTPORT_PORT" "$plist"
    plutil -replace CFBundleName -string "Deth Race" "$plist"
    plutil -replace CFBundleShortVersionString -string "$version" "$plist"
    plutil -replace CFBundleVersion -string "$version" "$plist"
    plutil -replace LSMinimumSystemVersion -string "$deployment_target" "$plist"
    plutil -replace LSApplicationCategoryType -string public.app-category.games "$plist"
    plutil -replace NSHighResolutionCapable -bool true "$plist"
}

case "$step" in
    fetch) fetch ;;
    build) build ;;
    *) fail "unknown step $step" ;;
esac
