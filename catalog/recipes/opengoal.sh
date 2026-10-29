#!/bin/bash
# Frontport Recipe: OpenGOAL (open-goal/jak-project), the Jak games' Decomp.
# Contract: catalog/recipes/README.md. Invoked as `opengoal.sh fetch`, then `opengoal.sh build`.
#
# One Recipe for one Port per game: the Port id names the game (opengoal-jak1, opengoal-jak2, opengoal-jak3),
# and each build makes an app for that game alone.
#
# Upstream's macOS Release is bare command-line tools. So this builds gk and extractor from source, patches
# gk to boot this Port's game when started with no arguments, and wraps gk in OpenGOAL.app with the data/
# folder upstream's release script assembles. gk finds data/ next to its executable, so Contents/MacOS/data
# links to Contents/Resources/data. gk writes its logs into data/log, inside the signed, sandboxed bundle;
# the Catalog's Redirect leads Contents/Resources/data/log to Library/Application Support/OpenGOAL/log in
# the container, beside the settings and saves gk already keeps there, so data/ ships no log folder.
#
# Build Assets: data/out/<game>, the game extractor decompiles and recompiles from the Build-Stage disc
# image, left at $FRONTPORT_OUT/assets for the Catalog's buildAssets.path
# "Contents/Resources/data/out/<game>".
set -euo pipefail

step=${1:?usage: opengoal.sh fetch|build}
src=$FRONTPORT_SRC
work=$(dirname "$src")
jak=$src/jak-project
game=${FRONTPORT_PORT#opengoal-}
deployment_target=13.0
export MACOSX_DEPLOYMENT_TARGET=$deployment_target
export CMAKE_POLICY_VERSION_MINIMUM=3.5
export GIT_CEILING_DIRECTORIES=$work

# Commits of the tags this Recipe was tested against, so a moved tag fails the fetch.
known_commit() {
    case "$1" in
        v0.3.9) echo b6c8430c0b0a5cb139b939bcf0ffd25285b896c7 ;;
    esac
}

fail() {
    echo "error: $*" >&2
    exit 1
}

case "$game" in
    jak1 | jak2 | jak3) ;;
    *) fail "Port $FRONTPORT_PORT names no game this Recipe builds (opengoal-jak1, opengoal-jak2, opengoal-jak3)" ;;
esac

# Replaces exactly the text given in a file, failing loudly when upstream changed it.
replace() {
    local file=$1 old=$2 new=$3
    grep -qF -- "$old" "$file" || fail "$file no longer contains: $old"
    OLD=$old NEW=$new perl -0pi -e 's/\Q$ENV{OLD}\E/$ENV{NEW}/g' "$file"
}

fetch() {
    echo "==> Cloning jak-project $FRONTPORT_REF"
    git -c advice.detachedHead=false clone --quiet --depth 1 --branch "$FRONTPORT_REF" \
        https://github.com/open-goal/jak-project.git "$jak"
    local expected actual
    expected=$(known_commit "$FRONTPORT_REF")
    actual=$(git -C "$jak" rev-parse HEAD)
    if [ -n "$expected" ] && [ "$actual" != "$expected" ]; then
        fail "$FRONTPORT_REF is $actual upstream, but this Recipe was tested with $expected"
    fi

    echo "==> Patching"
    # This Port's game when started with no arguments, as from the Dock.
    replace "$jak/game/main.cpp" '  std::string game_name = "jak1";' "  std::string game_name = \"$game\";"
    # curl without TLS: macOS builds take OpenSSL from Homebrew, which the build sandbox hides, and the
    # Port has no network permission for gk's optional web requests anyway.
    replace "$jak/CMakeLists.txt" '    set(CURL_USE_OPENSSL ON)' '    set(CURL_ENABLE_SSL OFF)'
}

build() {
    echo "==> Building gk and extractor"
    cmake -S "$jak" -B "$work/build" -G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_ARCHITECTURES=arm64 \
        -DCMAKE_APPLE_SILICON_PROCESSOR=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=$deployment_target \
        -DSTATICALLY_LINK=ON -DZYDIS_BUILD_SHARED_LIB=OFF -DCURL_ENABLE_SSL=OFF -DBUILD_TESTING=OFF
    cmake --build "$work/build" --target gk extractor -j "$FRONTPORT_JOBS"

    echo "==> Making OpenGOAL.app"
    local app=$FRONTPORT_OUT/OpenGOAL.app plist version=${FRONTPORT_REF#v}
    plist=$app/Contents/Info.plist
    mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
    cp "$work/build/game/gk" "$app/Contents/MacOS/gk"
    # What gk reads at run time; goal_src/ itself is only for compiling, but gk lists goal_src/user.
    make_data "$app/Contents/Resources/data" runtime
    ln -s ../Resources/data "$app/Contents/MacOS/data"
    plutil -create xml1 "$plist"
    plutil -insert CFBundleExecutable -string gk "$plist"
    plutil -insert CFBundleIdentifier -string "dev.frontport.port.$FRONTPORT_PORT" "$plist"
    plutil -insert CFBundleName -string "OpenGOAL Jak ${game#jak}" "$plist"
    plutil -insert CFBundlePackageType -string APPL "$plist"
    plutil -insert CFBundleInfoDictionaryVersion -string 6.0 "$plist"
    plutil -insert CFBundleShortVersionString -string "$version" "$plist"
    plutil -insert CFBundleVersion -string "$version" "$plist"
    plutil -insert LSMinimumSystemVersion -string "$deployment_target" "$plist"
    plutil -insert LSApplicationCategoryType -string public.app-category.games "$plist"
    plutil -insert NSHighResolutionCapable -bool true "$plist"

    extract_assets
}

# make_data <folder> runtime|full: the data/ folder of upstream's release
# (.github/scripts/releases/extract_build_unix.sh); "runtime" leaves out the GOAL source but goal_src/user.
make_data() {
    local data=$1
    mkdir -p "$data/launcher" "$data/decompiler" "$data/game/graphics/opengl_renderer" "$data/goal_src"
    cp "$jak/.github/scripts/releases/error-code-metadata.json" "$data/launcher/"
    cp -R "$jak/decompiler/config" "$data/decompiler/"
    cp -R "$jak/game/assets" "$data/game/"
    cp -R "$jak/game/graphics/opengl_renderer/shaders" "$data/game/graphics/opengl_renderer/"
    cp -R "$jak/custom_assets" "$data/"
    if [ "$2" = full ]; then
        rmdir "$data/goal_src"
        cp -R "$jak/goal_src" "$data/"
    else
        cp -R "$jak/goal_src/user" "$data/goal_src/"
    fi
}

# data/out/<game> from the disc image among the Build-Stage ROMs; nothing when there is none.
extract_assets() {
    local rom data=$work/extract
    for rom in "$FRONTPORT_ROMS"/*; do
        [ -f "$rom" ] || continue
        rm -rf "$data"
        make_data "$data" full
        echo "==> Extracting, decompiling and compiling $(basename "$rom")"
        "$work/build/decompiler/extractor" "$rom" --extract --validate --decompile --compile \
            --proj-path "$data" --game "$game" --disable-ansi
        [ -d "$data/out/$game/iso" ] || fail "extractor made no out/$game/iso"
        # Only the compiled game and its textures; obj/ holds intermediate objects.
        mkdir "$FRONTPORT_OUT/assets"
        mv "$data/out/$game/iso" "$data/out/$game/fr3" "$FRONTPORT_OUT/assets/"
        rm -rf "$data"
        return
    done
    echo "==> No disc image given: skipping assets"
}

case "$step" in
    fetch) fetch ;;
    build) build ;;
    *) fail "unknown step $step" ;;
esac
