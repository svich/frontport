#!/bin/bash
# Frontport Recipe: The Ur-Quan Masters, the open-source port of Star Control II's 3DO version.
# Contract: catalog/recipes/README.md. Invoked as `uqm.sh fetch`, then `uqm.sh build`.
#
# Upstream lives on SourceForge (sc2/uqm); the Catalog pins its 0.8.0 commit through a GitHub copy of the same
# history, so Frontport can look the commit up. Upstream's Mac app is Intel-only, so this builds the same app from
# source with upstream's build.sh, against static SDL2, libogg, libvorbis and libpng, and puts the game's content
# packages in it: the base content, the 3DO version's voices and its music. They are freeware (CC BY-NC-SA 2.5)
# and come from upstream's 0.8.0 release, so there are no ROMs and no Build Assets.
# UQM reads its content from the app's Resources/content and keeps its settings, saved games and Super Melee
# teams in ~/.uqm, which the App Sandbox puts in the container. Netplay is left out. fetch fixes the game's
# lookup of the app's content, which used the path after freeing it, and patches the build: its Mac flags are for an Intel build for 10.6; its object rules compile their
# first dependency, which today's clang makes the SDK's SDKSettings.json rather than the source; and its configure
# step writes its test programs to /tmp, which the build sandbox doesn't allow.
set -euo pipefail

step=${1:?usage: uqm.sh fetch|build}
src=$FRONTPORT_SRC
work=$(dirname "$src")                 # Builds/<port>: writable during build, kept between builds
deps=$src/deps
packages=$src/packages
uqm=$src/sc2-uqm
prefix=$work/prefix                    # the static libraries, reused while their pins don't change
deployment_target=13.0
export MACOSX_DEPLOYMENT_TARGET=$deployment_target
export GIT_CEILING_DIRECTORIES=$work
export CMAKE_POLICY_VERSION_MINIMUM=3.5 # vorbis still declares cmake_minimum_required(2.8.12)

dependencies="
sdl2 5f5993c530f084535c65a6879e9b26ad441169b3e25d789d83287040a9ca5165 https://github.com/libsdl-org/SDL/releases/download/release-2.32.10/SDL2-2.32.10.tar.gz
ogg 5c8253428e181840cd20d41f3ca16557a9cc04bad4a3d04cce84808677fa1061 https://github.com/xiph/ogg/releases/download/v1.3.6/libogg-1.3.6.tar.xz
vorbis b33cc4934322bcbf6efcbacf49e3ca01aadbea4114ec9589d1b1e9d20f72954b https://github.com/xiph/vorbis/releases/download/v1.3.7/libvorbis-1.3.7.tar.xz
libpng d80dd2a38a37f803cb9b6ac7b14bd6e74ddc3b654780a8380bdf93523fdb4389 https://download.sourceforge.net/libpng/libpng-1.6.59.tar.xz
"

# The content packages of upstream's 0.8.0 release, by the content folder each goes in: the base content, and
# the 3DO version's voices and music as the addons UQM turns on by default.
content="
packages uqm-0.8.0-content.uqm 77d75ac25e6fb755a33c4ba3b38a7b7bc41fcbc02896891b0cc9ac9214b72eef
addons uqm-0.8.0-voice.uqm 9edbf51d77d8b533399c5f3afb549314a8210d7aab71ca2c51b4f24832337a45
addons uqm-0.8.0-3domusic.uqm 44cd3cec7e9569b4117adb4d77f1522890972566267391ae09631485d231d8b9
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
    echo "==> Cloning The Ur-Quan Masters $FRONTPORT_REF"
    git clone --quiet https://github.com/0xDEC0DE/sc2-uqm.git "$uqm"
    git -C "$uqm" -c advice.detachedHead=false checkout --quiet "$FRONTPORT_REF"
    head -1 "$uqm/sc2/content/version" >"$src/version"
    replace "$uqm/sc2/build/unix/config_proginfo_build" "-mmacosx-version-min=10.6 -arch x86_64" \
        "-mmacosx-version-min=$deployment_target -arch arm64"
    replace "$uqm/sc2/src/options.c" '			HFree (execFileDup);
			HFree (tempDir);' '			HFree (execFileDup);
			// Frontport: not freed, as loc points to it.'
    local kind
    for kind in c cpp m; do
        replace "$uqm/sc2/Makefile.build" "
%.$kind.o:
" "
\$(OBJDIR)%.$kind.o: \$(BUILD_ROOT)%.$kind
"
    done
    replace "$uqm/sc2/build/unix/config_functions" 'TEMPFILE="/tmp/build.$$.tmp"' \
        'TEMPFILE="${UQM_BUILD_TMP:-/tmp}/build.$$.tmp"'

    mkdir -p "$deps" "$packages"
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
    local folder
    while read -r folder name sha; do
        [ -n "$name" ] || continue
        echo "==> Downloading $name"
        mkdir -p "$packages/$folder"
        download "$packages/$folder/$name" "$sha" "https://downloads.sourceforge.net/project/sc2/UQM/0.8/$name"
    done <<<"$content"
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
    cmake_static ogg -DINSTALL_DOCS=OFF
    cmake_static vorbis
    cmake_static libpng -DPNG_SHARED=OFF -DPNG_STATIC=ON -DPNG_FRAMEWORK=OFF -DPNG_TESTS=OFF -DPNG_TOOLS=OFF
    echo "$wanted" >"$stamp"
}

build() {
    build_libraries

    echo "==> Building The Ur-Quan Masters"
    local sc2=$uqm/sc2 tools=$work/tools
    # build.sh splits its flags on spaces, and the prefix is under "Application Support", so the flags reach it
    # relative to sc2, which it runs in. sdl2-config is asked for SDL's static libraries.
    local rel=../../..
    [ "$(cd "$sc2/$rel" && pwd -P)" = "$(cd "$work" && pwd -P)" ] || fail "sc2 isn't three folders below $work"
    rm -rf "$tools"
    mkdir -p "$tools"
    local sdl_libs sdl_version
    sdl_libs=$("$prefix/bin/sdl2-config" --static-libs)
    sdl_libs=${sdl_libs//-L$prefix\/lib/}
    sdl_libs=-lSDL2${sdl_libs//$prefix\/lib\/libSDL2.a/}
    sdl_version=$("$prefix/bin/sdl2-config" --version)
    cat >"$tools/sdl2-config" <<EOF
#!/bin/sh
case "\$1" in
    --cflags) echo "-I$rel/prefix/include/SDL2 -D_THREAD_SAFE" ;;
    --libs) echo "$sdl_libs" ;;
    --version) echo "$sdl_version" ;;
esac
EOF
    # build.sh compiles with gcc, which is a shim that asks xcrun for clang on every call; xcrun can't keep its
    # cache in the sandbox, so each call would take seconds. The toolchain's clang, on the PATH, is called directly.
    printf '#!/bin/sh\nexec clang "$@"\n' >"$tools/gcc"
    chmod +x "$tools/sdl2-config" "$tools/gcc"

    cd "$sc2"
    rm -f config.state build.vars config_unix.h
    # The build menu's choices: a release build, plain C (its asm is for x86), no netplay. reprocess_config
    # applies them without the menu, but doesn't detect the system as config does, so it's given.
    cat >config.state <<'EOF'
CHOICE_debug_VALUE='nodebug'
CHOICE_graphics_VALUE='sdl2'
CHOICE_sound_VALUE='mixsdl'
CHOICE_mikmod_VALUE='internal'
CHOICE_ovcodec_VALUE='standard'
CHOICE_netplay_VALUE='none'
CHOICE_joystick_VALUE='enabled'
CHOICE_ioformat_VALUE='stdio_zip'
CHOICE_accel_VALUE='plainc'
CHOICE_threadlib_VALUE='sdl'
EOF
    # Older C that today's clang rejects by default, such as calls to functions it doesn't declare first.
    local flags="-w -Wno-error=implicit-function-declaration -Wno-error=int-conversion"
    flags+=" -Wno-error=incompatible-function-pointer-types"
    PATH=$tools:$PATH CC=clang CXX=clang++ OBJC=clang BUILD_SYSTEM=Darwin HOST_SYSTEM=Darwin UQM_BUILD_TMP=$rel/tmp \
        CFLAGS="$flags -I$rel/prefix/include" LDFLAGS="$flags -L$rel/prefix/lib -logg" \
        ./build.sh uqm reprocess_config
    PATH=$tools:$PATH ./build.sh uqm

    local app="$FRONTPORT_OUT/The Ur-Quan Masters.app" plist version
    plist=$app/Contents/Info.plist
    version=$(cat "$src/version")
    echo "==> Making The Ur-Quan Masters.app"
    mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources/content"
    # Without the resource fork build.sh gives it for running outside an app, which codesign refuses.
    cp -X uqm "$app/Contents/MacOS/The Ur-Quan Masters"
    cp content/version "$app/Contents/Resources/content/"
    cp -R "$packages/" "$app/Contents/Resources/content/"
    cp "src/res/darwin/The Ur-Quan Masters.icns" "$app/Contents/Resources/"
    plutil -create xml1 "$plist"
    plutil -insert CFBundleExecutable -string "The Ur-Quan Masters" "$plist"
    plutil -insert CFBundleIdentifier -string "dev.frontport.port.$FRONTPORT_PORT" "$plist"
    plutil -insert CFBundleName -string "The Ur-Quan Masters" "$plist"
    plutil -insert CFBundlePackageType -string APPL "$plist"
    plutil -insert CFBundleInfoDictionaryVersion -string 6.0 "$plist"
    plutil -insert CFBundleShortVersionString -string "$version" "$plist"
    plutil -insert CFBundleVersion -string "$version" "$plist"
    plutil -insert CFBundleIconFile -string "The Ur-Quan Masters" "$plist"
    plutil -insert LSMinimumSystemVersion -string "$deployment_target" "$plist"
    plutil -insert LSApplicationCategoryType -string public.app-category.role-playing-games "$plist"
    plutil -insert NSHighResolutionCapable -bool true "$plist"
    plutil -insert NSPrincipalClass -string NSApplication "$plist"
}

case "$step" in
    fetch) fetch ;;
    build) build ;;
    *) fail "unknown step $step" ;;
esac
