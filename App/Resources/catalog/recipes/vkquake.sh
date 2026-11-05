#!/bin/bash
# Frontport Recipe: vkQuake (Novum/vkQuake), Quake on Vulkan, built on QuakeSpasm.
# Contract: catalog/recipes/README.md. Invoked as `vkquake.sh fetch`, then `vkquake.sh build`.
#
# Upstream has no macOS Release (macsourceports carries one) and its macOS build wants Homebrew's MoltenVK,
# glslang, SDL3, the codecs, meson and pkg-config. So this builds everything it needs from pinned sources and
# wraps it in vkQuake.app:
# - Rendering is Vulkan, linked straight to MoltenVK (Vulkan on Metal), as upstream's macOS build does, so no
#   Vulkan loader or ICD manifest is needed; libMoltenVK.dylib ships in Contents/Frameworks. MoltenVK is built with
#   its own CMake, its CPM dependencies pointed at fetched archives; the engine compiles against newer headers.
# - Meson is its pinned wheel, run by the developer tools' python3; pkgconf is built from source for meson's
#   dependency lookups. glslangValidator compiles the shaders; spirv-opt isn't needed, since upstream's darwin
#   build leaves MoltenVK's shaders unoptimized, so the patch below makes it optional.
# - SDL3, libogg and libvorbis are linked statically. Music is Ogg Vorbis (id1/music/track02.ogg on);
#   the other codecs stay out.
# The engine looks for id1 beside the app. The patch below makes its base folder ~/Library/Application Support/
# vkQuake instead, where the App Sandbox puts the container and Frontport Seeds the game's id1 folder; vkQuake.cfg
# and saves go into that id1 folder too. With id1 there, the Steam, GOG and Epic detection and the folder picker
# never run.
set -euo pipefail

step=${1:?usage: vkquake.sh fetch|build}
src=$FRONTPORT_SRC
work=$(dirname "$src")                 # Builds/<port>: writable during build, kept between builds
deps=$src/deps
vkquake=$src/vkQuake
prefix=$work/prefix                    # tools and libraries, reused while their pins don't change
deployment_target=13.0
export MACOSX_DEPLOYMENT_TARGET=$deployment_target
export GIT_CEILING_DIRECTORIES=$work

fail() {
    echo "error: $*" >&2
    exit 1
}

# Commits of the refs this Recipe was tested against, so a moved tag fails the fetch.
known_commit() {
    case "$1" in
        1.37.0) echo 749b4fd43fe8b8554b34163dc9469c4a08a4def1 ;;
    esac
}

# name sha256 url. spirv-cross, cereal and vulkan-headers-moltenvk are the commits MoltenVK's ExternalRevisions
# pin; vulkan-headers is what the engine compiles against (it wants 1.4.341 or later).
dependencies="
sdl3 f3bb06f55bed9557227a700af2ea62e49497ebdf58037732a731a5fb3ef8581f https://github.com/libsdl-org/SDL/releases/download/release-3.4.20/SDL3-3.4.20.tar.gz
ogg 83e6704730683d004d20e21b8f7f55dcb3383cdf84c0daedf30bde175f774638 https://github.com/xiph/ogg/releases/download/v1.3.6/libogg-1.3.6.tar.gz
vorbis 0e982409a9c3fc82ee06e08205b1355e5c6aa4c36bca58146ef399621b0ce5ab https://github.com/xiph/vorbis/releases/download/v1.3.7/libvorbis-1.3.7.tar.gz
pkgconf 11818a25f2730132f3b258ac8be4e82f83b9db03a1a99a6c29cd01b94fc9d310 https://github.com/pkgconf/pkgconf/archive/refs/tags/pkgconf-3.0.10.tar.gz
glslang 9c09b901149c729df745057dafa815278aaa101b84d2b6e14f16a42de52f97f2 https://github.com/KhronosGroup/glslang/archive/refs/tags/16.6.0.tar.gz
vulkan-headers cbaf687d3c59b9666fe080e7f8396b6b4f4d344a768ee6b337c59852f4526b68 https://github.com/KhronosGroup/Vulkan-Headers/archive/refs/tags/v1.4.363.tar.gz
moltenvk 6864db532f1dbbdb621a8d0ec13f24edae318fd9269dd3dd0cdff791334bb1cb https://github.com/KhronosGroup/MoltenVK/archive/refs/tags/v1.4.2.tar.gz
spirv-cross b81b9956289950570953738e666a031ca32ff64e4fc925eba89f227c42109518 https://github.com/KhronosGroup/SPIRV-Cross/archive/6c09849fe88c48eaed08413aa022aaa136a3a057.tar.gz
cereal 12e10fb541270632f6683286ce8c7e8c321fe4addb53fa91ed498b95c1758f93 https://github.com/USCiLab/cereal/archive/a56bad8bbb770ee266e930c95d37fff2a5be7fea.tar.gz
vulkan-headers-moltenvk f492279345cbc10708b64fcd432b3ff6c8246a5837c4db2b649abba00cf82208 https://github.com/KhronosGroup/Vulkan-Headers/archive/e3b1eec08173d6b825cd3ac88c885a63b621504a.tar.gz
"
cpm_sha=78ba32abdf798bc616bab7c73aac32a17bbd7b06ad9e26a6add69de8f3ae4791
cpm_url=https://github.com/cpm-cmake/CPM.cmake/releases/download/v0.40.8/CPM.cmake
# Meson 1.10 is the last that runs on the developer tools' Python 3.9.
meson_sha=5f84ef186e6e788d9154db63620fc61b3ece69f643b94b43c8b9203c43d89b36
meson_url=https://files.pythonhosted.org/packages/0b/78/7d049e63e624d51d0065191dae101a1e36d5d3a2360633772d9ad8afb2d5/meson-1.10.2-py3-none-any.whl

# Replaces exactly the text given in a file, failing loudly when upstream changed it.
replace() {
    local file=$1 old=$2 new=$3
    grep -qF -- "$old" "$file" || fail "$file no longer contains: $old"
    OLD=$old NEW=$new perl -0pi -e 's/\Q$ENV{OLD}\E/$ENV{NEW}/g' "$file"
}

# download <file> <sha256> <url>
download() {
    curl -fsSL --retry 3 -o "$1" "$3"
    echo "$2  $1" | shasum -a 256 -c --status - || fail "$3 doesn't match its pinned sha256"
}

# Meson from its unzipped wheel, by a launcher beside it, which puts the wheel on the path as the script's folder.
meson() {
    python3 -E -s "$deps/meson/meson.py" "$@"
}

fetch() {
    echo "==> Cloning vkQuake $FRONTPORT_REF"
    git init --quiet "$vkquake"
    git -C "$vkquake" fetch --quiet --depth 1 https://github.com/Novum/vkQuake.git "$FRONTPORT_REF"
    git -C "$vkquake" -c advice.detachedHead=false checkout --quiet FETCH_HEAD
    local expected actual
    expected=$(known_commit "$FRONTPORT_REF")
    actual=$(git -C "$vkquake" rev-parse HEAD)
    if [ -n "$expected" ] && [ "$actual" != "$expected" ]; then
        fail "$FRONTPORT_REF is $actual upstream, but this Recipe was tested with $expected"
    fi
    local version
    version=$(sed -n 's/^#define[[:space:]]*VKQUAKE_VERSION[[:space:]]*\([0-9.]*\).*/\1/p' "$vkquake/Quake/quakever.h")
    local patchlevel
    patchlevel=$(sed -n 's/^#define[[:space:]]*VKQUAKE_VER_PATCH[[:space:]]*\([0-9]*\).*/\1/p' "$vkquake/Quake/quakever.h")
    [ -n "$version" ] && [ -n "$patchlevel" ] || fail "Quake/quakever.h names no VKQUAKE_VERSION"
    echo "$version.$patchlevel" >"$src/version"

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
    echo "==> Downloading CPM.cmake"
    mkdir -p "$deps/cpm/cpm"
    download "$deps/cpm/cpm/CPM_0.40.8.cmake" "$cpm_sha" "$cpm_url"
    echo "==> Downloading meson"
    download "$deps/meson.whl" "$meson_sha" "$meson_url"
    unzip -q "$deps/meson.whl" -d "$deps/meson"
    rm "$deps/meson.whl"
    printf '%s\n' 'import sys' 'from mesonbuild.mesonmain import main' 'sys.exit(main())' >"$deps/meson/meson.py"

    echo "==> Patching"
    # The base folder: the app's own folder in Application Support, not the folder holding the app.
    replace "$vkquake/Quake/sys_sdl_unix.c" '	tmp = OSX_StripAppBundle (dst);
	if (tmp != dst)
		q_strlcpy (dst, tmp, dstsize);' '	tmp = OSX_StripAppBundle (dst);
	if (tmp != dst) /* Frontport: an app plays from its folder in Application Support */
		q_snprintf (dst, dstsize, "%s/Library/Application Support/vkQuake", getenv ("HOME"));'
    # MoltenVK: from the build's prefix rather than Homebrew's, and as the dylib the app ships, while prefer_static,
    # for SDL3 and the codecs, would look for a static one.
    replace "$vkquake/meson.build" "    if import('fs').exists('/opt/homebrew/lib/libMoltenVK.dylib')
        molten_dirs += '/opt/homebrew/lib'
    endif
    deps += cc.find_library('MoltenVK', required : true, dirs : molten_dirs)" \
        "    molten_dirs += get_option('prefix') / get_option('libdir')
    deps += cc.find_library('MoltenVK', required : true, dirs : molten_dirs, static : false)"
    # Vsync starts as triple buffering: through MoltenVK, plain vsync's two swapchain images play unevenly, and a
    # third smooths it without tearing. The Video menu still offers off and on.
    replace "$vkquake/Quake/gl_vidsdl.c" 'static cvar_t vid_vsync = {"vid_vsync", "1", CVAR_ARCHIVE};' \
        'static cvar_t vid_vsync = {"vid_vsync", "2", CVAR_ARCHIVE};'
    # spirv-opt only runs off darwin.
    replace "$vkquake/meson.build" "spirv_opt = find_program('spirv-opt')
run_test_canonicalize_ids_spirv_opt = run_command(spirv_opt, '-h', check : false)
has_canonicalize_ids_spirv_opt = (run_test_canonicalize_ids_spirv_opt.stdout().strip().contains('--canonicalize-ids'))" \
        "spirv_opt = find_program('spirv-opt', required : build_machine.system() != 'darwin')
has_canonicalize_ids_spirv_opt = false
if spirv_opt.found()
    run_test_canonicalize_ids_spirv_opt = run_command(spirv_opt, '-h', check : false)
    has_canonicalize_ids_spirv_opt = (run_test_canonicalize_ids_spirv_opt.stdout().strip().contains('--canonicalize-ids'))
endif"
}

build_libraries() {
    local stamp=$prefix/.frontport-libraries
    local wanted
    wanted=$(echo "$dependencies $cpm_sha $meson_sha $deployment_target" | shasum -a 256 | cut -d' ' -f1)
    if [ -f "$stamp" ] && [ "$(cat "$stamp")" = "$wanted" ]; then
        echo "==> Reusing the tools and libraries in $prefix"
        return
    fi
    rm -rf "$prefix" "$work/libraries-build"
    local common=(-G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_ARCHITECTURES=arm64
        -DCMAKE_OSX_DEPLOYMENT_TARGET=$deployment_target -DCMAKE_INSTALL_PREFIX="$prefix"
        -DCMAKE_PREFIX_PATH="$prefix" -DCMAKE_POLICY_VERSION_MINIMUM=3.5)

    echo "==> Building pkgconf"
    meson setup "$work/libraries-build/pkgconf" "$deps/pkgconf" --prefix="$prefix" --buildtype=release -Ddefault_library=static
    ninja -C "$work/libraries-build/pkgconf"
    meson install -C "$work/libraries-build/pkgconf" --quiet

    echo "==> Building SDL3"
    cmake -S "$deps/sdl3" -B "$work/libraries-build/sdl3" "${common[@]}" \
        -DSDL_SHARED=OFF -DSDL_STATIC=ON -DSDL_TESTS=OFF -DSDL_EXAMPLES=OFF
    cmake --build "$work/libraries-build/sdl3" -j "$FRONTPORT_JOBS"
    cmake --install "$work/libraries-build/sdl3"

    echo "==> Building libogg and libvorbis"
    cmake -S "$deps/ogg" -B "$work/libraries-build/ogg" "${common[@]}" -DBUILD_SHARED_LIBS=OFF -DINSTALL_DOCS=OFF \
        -DBUILD_TESTING=OFF
    cmake --build "$work/libraries-build/ogg" -j "$FRONTPORT_JOBS"
    cmake --install "$work/libraries-build/ogg"
    cmake -S "$deps/vorbis" -B "$work/libraries-build/vorbis" "${common[@]}" -DBUILD_SHARED_LIBS=OFF \
        -DBUILD_TESTING=OFF
    cmake --build "$work/libraries-build/vorbis" -j "$FRONTPORT_JOBS"
    cmake --install "$work/libraries-build/vorbis"

    echo "==> Building glslang"
    cmake -S "$deps/glslang" -B "$work/libraries-build/glslang" "${common[@]}" \
        -DENABLE_OPT=OFF -DGLSLANG_TESTS=OFF -DGLSLANG_ENABLE_INSTALL=ON -DENABLE_GLSLANG_BINARIES=ON \
        -DBUILD_SHARED_LIBS=OFF -DBUILD_EXTERNAL=OFF
    cmake --build "$work/libraries-build/glslang" -j "$FRONTPORT_JOBS"
    cmake --install "$work/libraries-build/glslang"

    echo "==> Building MoltenVK"
    # SPIRV-Tools only disassembles SPIR-V in MoltenVK's debug logs, and needs python to build, so it stays out.
    cmake -S "$deps/moltenvk" -B "$work/libraries-build/moltenvk" "${common[@]}" \
        -DCPM_SOURCE_CACHE="$deps/cpm" -DFETCHCONTENT_FULLY_DISCONNECTED=ON \
        -DCPM_SPIRV-Cross_SOURCE="$deps/spirv-cross" -DCPM_cereal_SOURCE="$deps/cereal" \
        -DCPM_Vulkan-Headers_SOURCE="$deps/vulkan-headers-moltenvk" -DMVK_EXCLUDE_SPIRV_TOOLS=ON
    cmake --build "$work/libraries-build/moltenvk" -j "$FRONTPORT_JOBS"
    cmake --install "$work/libraries-build/moltenvk"
    install_name_tool -id @rpath/libMoltenVK.dylib "$(realpath "$prefix/lib/libMoltenVK.dylib")"

    echo "==> Installing the Vulkan headers"
    cmake -S "$deps/vulkan-headers" -B "$work/libraries-build/vulkan-headers" "${common[@]}" \
        -DVULKAN_HEADERS_ENABLE_MODULE=OFF -DVULKAN_HEADERS_ENABLE_TESTS=OFF
    cmake --install "$work/libraries-build/vulkan-headers"

    rm -rf "$work/libraries-build"
    echo "$wanted" >"$stamp"
}

build() {
    build_libraries

    echo "==> Configuring vkQuake"
    rm -rf "$work/build"
    # The libraries' .pc files name the prefix as it is, and pkgconf splits their flags at its space; escaped, it
    # keeps them whole. Only spaces not yet escaped are, so a reused prefix stays as it was.
    perl -pi -e 's/(?<!\\) /\\ /g if /^(prefix|exec_prefix|libdir|includedir)=/' "$prefix"/lib/pkgconfig/*.pc
    # A native file, as Meson splits -Dc_args at the space every Frontport build folder has (Application Support).
    # MoltenVK is found in the prefix, which nothing installs into; SDL3 and the codecs by pkgconf, statically.
    local native=$work/native.ini
    cat >"$native" <<EOF
[binaries]
pkg-config = '$prefix/bin/pkgconf'
glslangValidator = '$prefix/bin/glslangValidator'

[built-in options]
pkg_config_path = '$prefix/lib/pkgconfig'
c_args = ['-I$prefix/include', '-mmacosx-version-min=$deployment_target']
c_link_args = ['-L$prefix/lib', '-Wl,-rpath,@executable_path/../Frameworks', '-mmacosx-version-min=$deployment_target']
EOF
    meson setup "$work/build" "$vkquake" --native-file "$native" --prefix="$prefix" --buildtype=release \
        -Ddebug=false -Dstrip=true \
        -Dprefer_static=true -Duse_sdl3=enabled -Duse_codec_vorbis=enabled -Duse_codec_mp3=disabled \
        -Duse_codec_flac=disabled -Duse_codec_opus=disabled -Db_pch=false

    echo "==> Building vkQuake"
    ninja -C "$work/build" -j "$FRONTPORT_JOBS"

    echo "==> Making vkQuake.app"
    local executable=$work/build/vkquake
    local app=$FRONTPORT_OUT/vkQuake.app
    [ -x "$executable" ] || fail "the build made no vkquake executable"
    otool -L "$executable" | grep -q '@rpath/libMoltenVK.dylib' || fail "vkquake doesn't link @rpath/libMoltenVK.dylib"
    mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$app/Contents/Frameworks"
    cp "$executable" "$app/Contents/MacOS/vkQuake"
    cp "$prefix/lib/libMoltenVK.dylib" "$app/Contents/Frameworks/"
    make_icon "$vkquake/Misc/vkQuake_512.png" "$app/Contents/Resources/vkQuake.icns"

    local version
    version=$(cat "$src/version")
    local plist=$app/Contents/Info.plist
    plutil -create xml1 "$plist"
    plutil -insert CFBundleExecutable -string vkQuake "$plist"
    plutil -insert CFBundleIdentifier -string "dev.frontport.port.$FRONTPORT_PORT" "$plist"
    plutil -insert CFBundleName -string vkQuake "$plist"
    plutil -insert CFBundleDisplayName -string vkQuake "$plist"
    plutil -insert CFBundlePackageType -string APPL "$plist"
    plutil -insert CFBundleInfoDictionaryVersion -string 6.0 "$plist"
    plutil -insert CFBundleShortVersionString -string "$version" "$plist"
    plutil -insert CFBundleVersion -string "$version" "$plist"
    plutil -insert CFBundleIconFile -string vkQuake "$plist"
    plutil -insert LSMinimumSystemVersion -string "$deployment_target" "$plist"
    plutil -insert LSApplicationCategoryType -string public.app-category.action-games "$plist"
    plutil -insert NSHighResolutionCapable -bool true "$plist"
    plutil -insert NSPrincipalClass -string NSApplication "$plist"
}

# make_icon <png> <icns>: an icns holding upstream's square PNG as it is, when it's a size an icns takes.
make_icon() {
    python3 -I - "$1" "$2" <<'EOF'
import struct, sys
png = open(sys.argv[1], "rb").read()
assert png[:8] == b"\x89PNG\r\n\x1a\n", "not a PNG"
width, height = struct.unpack(">II", png[16:24])
kinds = {32: b"ic11", 64: b"ic12", 128: b"ic07", 256: b"ic08", 512: b"ic09", 1024: b"ic10"}
assert width == height and width in kinds, f"unusable icon {width}x{height}"
entry = kinds[width] + struct.pack(">I", len(png) + 8) + png
open(sys.argv[2], "wb").write(b"icns" + struct.pack(">I", len(entry) + 8) + entry)
EOF
}

case "$step" in
    fetch) fetch ;;
    build) build ;;
    *) fail "unknown step $step" ;;
esac
