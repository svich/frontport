#!/bin/bash
# Frontport Recipe: TRX, the Lost Artefacts' engine for the classic Tomb Raider games.
# Contract: catalog/recipes/README.md. Invoked as `trx.sh fetch`, then `trx.sh build`.
#
# Upstream's Mac app plays from its own bundle: its configuration folder, cfg/ beside the executable, holds both
# the files it ships and the settings it writes, and it writes its log, saves and caches there too, which a signed,
# read-only app can't. So this builds TRX from source with upstream's Meson, patched to write its settings, saves,
# caches, screenshots and log to ~/Library/Application Support/TRX (the container's) while still reading its own
# files from the app, against static SDL2, GLEW, PCRE2, Lua, rubberband and FFmpeg (every native decoder, for the
# games' many video and audio formats). The files TRX ships (cfg/, games/, modules/, scripts/: game flows, strings,
# shaders, Lua and the freeware demo and expansion) are the release's own, from its Linux zip.
# The games' files are Runtime-Stage folder ROMs, Seeded into Library/Application Support/TRX/<game>; the entry's
# redirects lead TRX's games/<game>/levels, fmv, music, sfx and cuts folders in the app to their places there.
set -euo pipefail

step=${1:?usage: trx.sh fetch|build}
src=$FRONTPORT_SRC
work=$(dirname "$src")                 # Builds/<port>: writable during build, kept between builds
deps=$src/deps
trx=$src/TRX
ship=$src/ship                         # the release's own data files
prefix=$work/prefix                    # tools and libraries, reused while their pins don't change
deployment_target=13.0
export MACOSX_DEPLOYMENT_TARGET=$deployment_target
export GIT_CEILING_DIRECTORIES=$work
export CMAKE_POLICY_VERSION_MINIMUM=3.5 # glew still declares cmake_minimum_required(2.8.12)
export PYTHONDONTWRITEBYTECODE=1

# tag commit sha256-of-the-Linux-zip, for each tag the Catalog may pin.
known_tags="
trx-1.12 bbed65a0e4fee48f1aa70956f9f0f4a44a059013 278e2bc97749971d18682189c7d737de39ff48132c8014aae74c7d72b996ef17
"

# name sha256 url. Archives unpack into deps/<name>. python is a standalone 3.14: upstream's build scripts need a
# newer one than the developer tools' 3.9.
dependencies="
sdl2 5f5993c530f084535c65a6879e9b26ad441169b3e25d789d83287040a9ca5165 https://github.com/libsdl-org/SDL/releases/download/release-2.32.10/SDL2-2.32.10.tar.gz
glew b64790f94b926acd7e8f84c5d6000a86cb43967bd1e688b03089079799c9e889 https://github.com/nigels-com/glew/releases/download/glew-2.3.1/glew-2.3.1.tgz
pcre2 929f0b20e62879252a15886b06c89f1edef61a363cbd5826fb041080a5e557ae https://github.com/PCRE2Project/pcre2/releases/download/pcre2-10.49/pcre2-10.49.tar.gz
lua 4f18ddae154e793e46eeab727c59ef1c0c0c2b744e7b94219710d76f530629ae https://www.lua.org/ftp/lua-5.4.8.tar.gz
uthash e10382ab75518bad8319eb922ad04f907cb20cccb451a3aa980c9d005e661acc https://github.com/troydhanson/uthash/archive/refs/tags/v2.3.0.tar.gz
rubberband af050313ee63bc18b35b2e064e5dce05b276aaf6d1aa2b8a82ced1fe2f8028e9 https://breakfastquay.com/files/releases/rubberband-4.0.0.tar.bz2
ffmpeg 7138d28c96d9d3e3af4ee3d8cad72741f8ffb40da90c1112235dea3ecd3178a3 https://ffmpeg.org/releases/ffmpeg-8.1.3.tar.xz
pkgconf 11818a25f2730132f3b258ac8be4e82f83b9db03a1a99a6c29cd01b94fc9d310 https://github.com/pkgconf/pkgconf/archive/refs/tags/pkgconf-3.0.10.tar.gz
python 226d696642a8a53d03b4d5b255b1c319b1575a6d44bd723a953c9f507755e36a https://github.com/astral-sh/python-build-standalone/releases/download/20261021/cpython-3.14.9%2B20261021-aarch64-apple-darwin-install_only.tar.gz
"
meson_sha=5f84ef186e6e788d9154db63620fc61b3ece69f643b94b43c8b9203c43d89b36
meson_url=https://files.pythonhosted.org/packages/0b/78/7d049e63e624d51d0065191dae101a1e36d5d3a2360633772d9ad8afb2d5/meson-1.10.2-py3-none-any.whl

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

python() {
    "$deps/python/bin/python3" -E -s "$@"
}

meson() {
    python "$deps/meson/meson.py" "$@"
}

fetch() {
    echo "==> Cloning TRX $FRONTPORT_REF"
    git clone --quiet https://github.com/LostArtefacts/TRX.git "$trx"
    git -C "$trx" -c advice.detachedHead=false checkout --quiet "$FRONTPORT_REF"
    local tag commit zip_sha="" head
    head=$(git -C "$trx" rev-parse HEAD)
    while read -r tag commit sha; do
        [ -n "$tag" ] || continue
        if [ "$FRONTPORT_REF" = "$tag" ] || [ "$FRONTPORT_REF" = "$commit" ]; then
            [ "$head" = "$commit" ] || fail "$tag is $head, not the expected $commit"
            zip_sha=$sha
            echo "${tag#trx-}" >"$src/version"
        fi
    done <<<"$known_tags"
    [ -n "$zip_sha" ] || fail "no known release for $FRONTPORT_REF"

    echo "==> Downloading the release's data files"
    local version
    version=$(cat "$src/version")
    download "$src/release.zip" "$zip_sha" \
        "https://github.com/LostArtefacts/TRX/releases/download/trx-$version/TRX-$version-Linux.zip"
    mkdir -p "$ship"
    unzip -q "$src/release.zip" 'cfg/*' 'games/*' 'modules/*' 'scripts/*' -d "$ship"
    rm "$src/release.zip"
    # The list of files older releases shipped, which TRX deletes from its folder at start; the app's are signed.
    rm -f "$ship/cfg/tombstones.json5"
    # Tomb Raider III Remastered names the original's videos after their scenes, in the original's order
    # (its tomb3.dll lists INTRO, LAGOON, HUEY, END). TRX tries each video extension, so .avi finds the .FMV.
    local flow=$ship/games/tr3/gameflow.json5
    replace "$flow" '{"path": {"*": "intr_eng.avi", "it": "intr_ita.avi"}, "intro": true},' \
        '{"path": "intro.avi", "intro": true}, // Frontport: the Remastered'\''s name'
    replace "$flow" '{"path": {"*": "sail_eng.avi", "it": "sail_ita.avi"}},' '{"path": "lagoon.avi"},'
    replace "$flow" '{"path": {"*": "crsh_eng.avi", "it": "crsh_ita.avi"}},' '{"path": "huey.avi"},'
    replace "$flow" '{"path": "endgame.avi"},' '{"path": "end.avi"},'

    echo "==> Patching"
    local paths=$trx/src/trx/game/paths.c
    # Settings, caches, screenshots and saves go to Application Support, unless the player's environment says
    # otherwise, as upstream's own variables still can.
    replace "$paths" 'void GamePath_Init(const SHELL_ARGS *const args)
{
    M_Shutdown();' 'void GamePath_Init(const SHELL_ARGS *const args)
{
    M_Shutdown();

#if defined(__APPLE__)
    // Frontport: the app is read-only, so what TRX writes goes to its folder in Application Support.
    const char *const home = getenv("HOME");
    if (home != nullptr && !String_IsEmpty(home)) {
        static const char *const dirs[][2] = {
            { "TRX_CONFIG_DIR", "" },
            { "TRX_CACHE_DIR", "/cache" },
            { "TRX_SCREENSHOTS_DIR", "/screenshots" },
            { "TRX_SAVES_DIR", "/saves" },
        };
        for (size_t i = 0; i < sizeof(dirs) / sizeof(dirs[0]); i++) {
            char *const dir = String_Format(
                "%s/Library/Application Support/TRX%s", home, dirs[i][1]);
            setenv(dirs[i][0], dir, 0);
            Memory_Free(dir);
        }
    }
#endif'
    # The files TRX ships in cfg/ are read from the app still, after the configuration folder.
    replace "$paths" '            "%config_dir%/%rel%",
' '            "%config_dir%/%rel%",
            "%trx_dir%/cfg/%rel%",
'
    replace "$paths" '            "%config_dir%/shaders/%rel%",
' '            "%config_dir%/shaders/%rel%",
            "%trx_dir%/cfg/shaders/%rel%",
'
    # TRX finds a file whatever its case by listing every folder from the root down, and the App Sandbox lets it
    # list neither /private nor the home folder. A path that exists as it's given needs no listing: the Mac's
    # volumes ignore case already.
    replace "$paths" 'static char *M_ResolveCasePathCached(const char *const path)
{
    if (path == nullptr || String_IsEmpty(path)) {
        return nullptr;
    }' 'static char *M_ResolveCasePathCached(const char *const path)
{
    if (path == nullptr || String_IsEmpty(path)) {
        return nullptr;
    }
#if defined(__APPLE__)
    // Frontport: no walk from the root, whose folders the sandbox hides.
    if (FS_Exists(path)) {
        return Memory_DupStr(path);
    }
#endif'
    # Tomb Raider II and III's main.sfx sits in the Remastered's SFX folder, not beside their levels: TRX looks in a
    # game's sfx/ too, which the entry's redirects lead there.
    replace "$paths" '    [GAME_DYNAMIC_PATH_SFX_FILE] = {
        .patterns = {
            "%mod_dir%/%rel%",
' '    [GAME_DYNAMIC_PATH_SFX_FILE] = {
        .patterns = {
            "%mod_dir%/%rel%",
            "%mod_dir%/sfx/%rel%", // Frontport: the Remastered'\''s SFX folder
'
    # The Remastered's MAIN.SFX puts a table of its own before the original's sounds, which follow as they were.
    replace "$trx/src/trx/game/level/pipeline.c" '    LOG_DEBUG("Loading samples from %s", file_name);
' '    LOG_DEBUG("Loading samples from %s", file_name);

    // Frontport: Tomb Raider I-III Remastered'\''s MAIN.SFX puts a table of its own before the original'\''s sounds.
    {
        uint32_t tag = 0;
        size_t start = 0;
        File_ReadData(fp, &tag, sizeof(tag));
        if (tag != MKTAG('\''R'\'', '\''I'\'', '\''F'\'', '\''F'\'')) {
            const size_t limit = File_Size(fp) < 65536 ? File_Size(fp) : 65536;
            for (size_t pos = 2; pos + sizeof(tag) <= limit; pos += 2) {
                File_Seek(fp, pos, FILE_SEEK_SET);
                File_ReadData(fp, &tag, sizeof(tag));
                if (tag == MKTAG('\''R'\'', '\''I'\'', '\''F'\'', '\''F'\'')) {
                    start = pos;
                    break;
                }
            }
        }
        File_Seek(fp, start, FILE_SEEK_SET);
    }
'
    replace "$trx/src/trx/game/shell/main.c" 'String_Format("%s/TRX.log", GamePath_Get(GAME_PATH_TRX_DIR));' \
        'String_Format("%s/TRX.log", GamePath_Get(GAME_PATH_CONFIG_DIR)); // Frontport: beside its settings'
    # The Mac's OpenGL 4.1 has no indexed GL_SAMPLER_BINDING, so every quad drawn logged GL_INVALID_ENUM and left
    # texture unit 0 without its sampler. The unit is the active one there, so the plain query asks the same.
    replace "$trx/src/trx/game/output/quad.c" 'glGetIntegeri_v(GL_SAMPLER_BINDING, 0, &prev_sampler);' \
        'glGetIntegerv(GL_SAMPLER_BINDING, &prev_sampler); // Frontport: OpenGL 4.1 has no indexed query'
    # Static libraries, which upstream's Mac build doesn't use: it bundles MacPorts' dylibs.
    replace "$trx/src/meson.build" "if host_machine.system() == 'darwin'
  staticdeps = false
endif" "# Frontport: static libraries on macOS too."

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
    echo "==> Downloading meson"
    download "$deps/meson.whl" "$meson_sha" "$meson_url"
    unzip -q "$deps/meson.whl" -d "$deps/meson"
    rm "$deps/meson.whl"
    printf '%s\n' 'import sys' 'from mesonbuild.mesonmain import main' 'sys.exit(main())' >"$deps/meson/meson.py"
    # rubberband 4.0.0 uses size_t without including what declares it, which today's libc++ no longer does for it.
    replace "$deps/rubberband/src/common/mathmisc.h" '#include "sysutils.h"' '#include "sysutils.h"
#include <cstddef> // Frontport: for size_t'
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
    wanted=$(echo "$dependencies $meson_sha $deployment_target" | shasum -a 256 | cut -d' ' -f1)
    if [ -f "$stamp" ] && [ "$(cat "$stamp")" = "$wanted" ]; then
        echo "==> Reusing the tools and libraries in $prefix"
        return
    fi
    rm -rf "$prefix" "$work/libraries-build"
    mkdir -p "$prefix/include" "$prefix/lib/pkgconfig"

    echo "==> Building pkgconf"
    meson setup "$work/libraries-build/pkgconf" "$deps/pkgconf" --prefix="$prefix" --buildtype=release \
        -Ddefault_library=static
    ninja -C "$work/libraries-build/pkgconf"
    meson install -C "$work/libraries-build/pkgconf" --quiet

    cmake_static sdl2 -DSDL_SHARED=OFF -DSDL_STATIC=ON -DSDL_TEST=OFF
    echo "==> Building GLEW"
    cmake_static glew/build/cmake -DGLEW_X11=OFF -DBUILD_UTILS=OFF
    cmake_static pcre2 -DPCRE2_BUILD_PCRE2_8=ON -DPCRE2_BUILD_PCRE2_16=OFF -DPCRE2_BUILD_PCRE2_32=OFF \
        -DPCRE2_BUILD_PCRE2GREP=OFF -DPCRE2_BUILD_TESTS=OFF -DPCRE2_SUPPORT_LIBZ=OFF -DPCRE2_SUPPORT_LIBBZ2=OFF \
        -DPCRE2_SUPPORT_LIBREADLINE=OFF -DPCRE2_SUPPORT_LIBEDIT=OFF

    echo "==> Building Lua"
    rm -rf "$work/libraries-build/lua"
    cp -R "$deps/lua" "$work/libraries-build/lua"
    make -C "$work/libraries-build/lua/src" -j "$FRONTPORT_JOBS" CC="clang -std=gnu99" \
        MYCFLAGS="-mmacosx-version-min=$deployment_target" liblua.a SYSCFLAGS="-DLUA_USE_MACOSX"
    cp "$work/libraries-build/lua/src/liblua.a" "$prefix/lib/"
    cp "$deps/lua/src"/{lua.h,luaconf.h,lualib.h,lauxlib.h,lua.hpp} "$prefix/include/"
    cat >"$prefix/lib/pkgconfig/lua.pc" <<'EOF'
prefix=${pcfiledir}/../..
libdir=${prefix}/lib
includedir=${prefix}/include

Name: Lua
Description: An extensible extension language
Version: 5.4.8
Libs: -L${libdir} -llua
Cflags: -I${includedir}
EOF

    echo "==> Installing uthash"
    cp "$deps/uthash/src"/*.h "$prefix/include/"

    echo "==> Building rubberband"
    meson setup "$work/libraries-build/rubberband" "$deps/rubberband" --prefix="$prefix" --libdir=lib \
        --buildtype=release -Ddefault_library=static -Dfft=vdsp -Dresampler=builtin -Djni=disabled \
        -Dladspa=disabled -Dlv2=disabled -Dvamp=disabled -Dcmdline=disabled -Dtests=disabled
    ninja -C "$work/libraries-build/rubberband"
    meson install -C "$work/libraries-build/rubberband" --quiet
    escape_pkgconfig

    echo "==> Building FFmpeg"
    # Every decoder, demuxer and parser FFmpeg has without other libraries, for the games' videos and music
    # (PlayStation STR, Escape RPL, AVI, Ogg Theora and Vorbis, WebP, MP3…), and rubberband for TRX's time stretch.
    # FFmpeg's configure can't take a path with a space (Application Support), so it's built in its own tree, with
    # the prefix, its temporary folder and rubberband's .pc file at paths relative to it.
    local ffmpeg=$work/libraries-build/ffmpeg
    rm -rf "$ffmpeg"
    cp -R "$deps/ffmpeg" "$ffmpeg"
    mkdir -p "$ffmpeg/frontport-pc"
    cat >"$ffmpeg/frontport-pc/rubberband.pc" <<'EOF'
prefix=../../prefix
libdir=${prefix}/lib
includedir=${prefix}/include

Name: rubberband
Description: Audio time-stretching and pitch-shifting library
Version: 4.0.0
Libs: -L${libdir} -lrubberband
Libs.private: -framework Accelerate -lc++
Cflags: -I${includedir}
EOF
    [ "$(cd "$ffmpeg/../../prefix" && pwd -P)" = "$(cd "$prefix" && pwd -P)" ] || fail "the prefix isn't at ../../prefix"
    (
        cd "$ffmpeg"
        mkdir -p frontport-tmp
        TMPDIR=frontport-tmp PATH=$prefix/bin:$PATH PKG_CONFIG_PATH=frontport-pc PKG_CONFIG_LIBDIR=frontport-pc ./configure \
            --prefix=../../prefix --cc=clang --pkg-config=pkgconf --pkg-config-flags=--static \
            --extra-cflags="-mmacosx-version-min=$deployment_target" \
            --extra-ldflags="-mmacosx-version-min=$deployment_target" \
            --enable-static --disable-shared --disable-programs --disable-doc --disable-network \
            --disable-avdevice --disable-encoders --disable-muxers --disable-autodetect --disable-debug \
            --enable-gpl --enable-librubberband --enable-zlib --enable-pthreads
        make -j "$FRONTPORT_JOBS"
        make install
    )
    # Its .pc files name the relative prefix it was given.
    perl -pi -e "s|^prefix=\\.\\./\\.\\./prefix\$|prefix=$prefix|" "$prefix"/lib/pkgconfig/lib{av,sw}*.pc

    escape_pkgconfig
    rm -rf "$work/libraries-build"
    echo "$wanted" >"$stamp"
}

# The libraries' .pc files name the prefix as it is, and pkgconf splits their flags at its space; escaped, it
# keeps them whole. Only spaces not yet escaped are, so it can run again.
escape_pkgconfig() {
    perl -pi -e 's/(?<!\\) /\\ /g if /^(prefix|exec_prefix|libdir|includedir)=/' "$prefix"/lib/pkgconfig/*.pc
}

build() {
    PATH=$deps/python/bin:$PATH
    build_libraries

    echo "==> Configuring TRX"
    rm -rf "$work/build"
    # A native file, as Meson splits -Dc_args at the space every Frontport build folder has (Application Support).
    local native=$work/native.ini version
    version=$(cat "$src/version")
    cat >"$native" <<EOF
[binaries]
pkg-config = '$prefix/bin/pkgconf'
python3 = '$deps/python/bin/python3'

[built-in options]
pkg_config_path = '$prefix/lib/pkgconfig'
c_args = ['-I$prefix/include', '-mmacosx-version-min=$deployment_target']
c_link_args = ['-L$prefix/lib', '-mmacosx-version-min=$deployment_target']
EOF
    meson setup "$work/build" "$trx/src" --native-file "$native" --buildtype=release -Dstrip=true \
        -Dstaticdeps=true -Dlua_dep=lua -Dtrx_version="$version"

    echo "==> Building TRX"
    ninja -C "$work/build" -j "$FRONTPORT_JOBS" TRX

    echo "==> Making TRX.app"
    local app=$FRONTPORT_OUT/TRX.app plist
    plist=$app/Contents/Info.plist
    mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
    cp "$work/build/TRX" "$app/Contents/MacOS/TRX"
    otool -L "$app/Contents/MacOS/TRX" | grep -E '^\s' | grep -vE '/System/Library/|/usr/lib/' \
        && fail "TRX links libraries outside the system"
    cp -R "$ship/" "$app/Contents/Resources/"
    cp "$trx/data/trx/mac/icon.icns" "$app/Contents/Resources/TRX.icns"
    plutil -create xml1 "$plist"
    plutil -insert CFBundleExecutable -string TRX "$plist"
    plutil -insert CFBundleIdentifier -string "dev.frontport.port.$FRONTPORT_PORT" "$plist"
    plutil -insert CFBundleName -string TRX "$plist"
    plutil -insert CFBundlePackageType -string APPL "$plist"
    plutil -insert CFBundleInfoDictionaryVersion -string 6.0 "$plist"
    plutil -insert CFBundleShortVersionString -string "$version" "$plist"
    plutil -insert CFBundleVersion -string "$version" "$plist"
    plutil -insert CFBundleIconFile -string TRX "$plist"
    plutil -insert LSMinimumSystemVersion -string "$deployment_target" "$plist"
    plutil -insert LSApplicationCategoryType -string public.app-category.action-games "$plist"
    plutil -insert NSHighResolutionCapable -bool true "$plist"
    plutil -insert NSPrincipalClass -string NSApplication "$plist"
}

case "$step" in
    fetch) fetch ;;
    build) build ;;
    *) fail "unknown step $step" ;;
esac
