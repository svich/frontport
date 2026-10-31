#!/bin/bash
# Frontport Recipe: RBDOOM-3-BFG (RobertBeckebans/RBDOOM-3-BFG), a modernised DOOM 3: BFG Edition engine.
# Contract: catalog/recipes/README.md. Invoked as `rbdoom3bfg.sh fetch`, then `rbdoom3bfg.sh build`.
#
# Upstream has no macOS Release; its macOS build wants the Vulkan SDK and Homebrew's openal-soft. So this builds
# everything it needs from pinned sources and wraps it in RBDOOM-3-BFG.app:
# - Rendering is Vulkan through NVRHI. On macOS the app links MoltenVK (Vulkan on Metal) directly, upstream's
#   USE_MoltenVK option, so no Vulkan loader or ICD manifest is needed; libMoltenVK.dylib ships in
#   Contents/Frameworks. MoltenVK is built with its own CMake, its CPM dependencies pointed at fetched archives.
# - The shaders are HLSL, compiled to SPIR-V at build time by ShaderMake (built from the engine's tree) running
#   DXC, which has no macOS Release: build makes it from a pinned tag, once, into Builds/<port>/dxc.
# - The texture compressor's kernel is ISPC, whose pinned macOS arm64 Release is fetched (a build tool only).
# - SDL2 and openal-soft are linked statically.
# Inside the app, Contents/Resources/base holds the engine's own files (the compiled shaders in renderprogs2, its
# defs, materials, scripts, configs), which the engine already looks for in an app's Resources when there is no
# base folder beside the executable or in the working directory. Configs, saves and generated files go to
# SDL_GetPrefPath's ~/Library/Application Support/RBDOOM-3-BFG, which the App Sandbox puts in the container, and
# whose base folder, where Frontport Seeds the game's base folder, the engine searches before the app's. So the
# engine needs no patch to run sandboxed; the one patch (ShaderMake's) and the build options that turn off DXC's
# git version and the engine's precompiled headers are for the space in every Frontport build folder.
# Not included: upstream's Release also ships baked global illumination (_rbdoom_global_illumination_data.pk4,
# inside a 1.6 GB Windows 7z); without it, maps light with the engine's fallback instead of baked env probes.
set -euo pipefail

step=${1:?usage: rbdoom3bfg.sh fetch|build}
src=$FRONTPORT_SRC
work=$(dirname "$src")                 # Builds/<port>: writable during build, kept between builds
deps=$src/deps
rbdoom=$src/RBDOOM-3-BFG
dxc_src=$src/DirectXShaderCompiler
prefix=$work/prefix                    # SDL2, openal-soft and MoltenVK, reused while their pins don't change
dxc=$work/dxc                          # dxc and libdxcompiler, reused while their pin doesn't change
deployment_target=13.0
export MACOSX_DEPLOYMENT_TARGET=$deployment_target
export GIT_CEILING_DIRECTORIES=$work

fail() {
    echo "error: $*" >&2
    exit 1
}

# Commits of the refs this Recipe was tested against, so a moved tag fails the fetch. v1.6.0 predates upstream's
# fixes for Apple clang 17 (its zlib) and CMake 4, so the Catalog pins a later master commit.
known_commit() {
    case "$1" in
        v1.6.0) echo ba39ba67df049dcf16c7b31f6613f72959be2c21 ;;
    esac
}

# The engine's submodules: NVRHI with the Vulkan headers it builds against, and ShaderMake. NVRHI's RTXMU stays out.
submodules="neo/extern/nvrhi neo/extern/ShaderMake"

dxc_tag=v1.9.2609
dxc_commit=01b62ad47db7dee3dd33f90e7339cf9e860b3f93

# name sha256 url. spirv-cross, cereal and vulkan-headers are the commits MoltenVK's ExternalRevisions pin, and
# cpm is the CPM.cmake its cmake/recipes/CPM.cmake downloads.
dependencies="
sdl2 5f5993c530f084535c65a6879e9b26ad441169b3e25d789d83287040a9ca5165 https://github.com/libsdl-org/SDL/releases/download/release-2.32.10/SDL2-2.32.10.tar.gz
openal-soft fb27e5839aa11f0e5b9d33756965291fad5d6909ab928ea1f796f4a1a6877894 https://github.com/kcat/openal-soft/archive/refs/tags/1.25.2.tar.gz
moltenvk 6864db532f1dbbdb621a8d0ec13f24edae318fd9269dd3dd0cdff791334bb1cb https://github.com/KhronosGroup/MoltenVK/archive/refs/tags/v1.4.2.tar.gz
spirv-cross b81b9956289950570953738e666a031ca32ff64e4fc925eba89f227c42109518 https://github.com/KhronosGroup/SPIRV-Cross/archive/6c09849fe88c48eaed08413aa022aaa136a3a057.tar.gz
cereal 12e10fb541270632f6683286ce8c7e8c321fe4addb53fa91ed498b95c1758f93 https://github.com/USCiLab/cereal/archive/a56bad8bbb770ee266e930c95d37fff2a5be7fea.tar.gz
vulkan-headers f492279345cbc10708b64fcd432b3ff6c8246a5837c4db2b649abba00cf82208 https://github.com/KhronosGroup/Vulkan-Headers/archive/e3b1eec08173d6b825cd3ac88c885a63b621504a.tar.gz
ispc efc5180095554628c01022507329ba7a2141c7ba97cf1bccc2df85dc47874e02 https://github.com/ispc/ispc/releases/download/v1.32.0/ispc-v1.32.0-macOS.arm64.tar.gz
"
cpm_sha=78ba32abdf798bc616bab7c73aac32a17bbd7b06ad9e26a6add69de8f3ae4791
cpm_url=https://github.com/cpm-cmake/CPM.cmake/releases/download/v0.40.8/CPM.cmake

# Replaces exactly the text given in a file, failing loudly when upstream changed it.
replace() {
    local file=$1 old=$2 new=$3
    grep -qF -- "$old" "$file" || fail "$file no longer contains: $old"
    OLD=$old NEW=$new perl -0pi -e 's/\Q$ENV{OLD}\E/$ENV{NEW}/g' "$file"
}

# clone <url> <folder> <ref>: that ref alone, with no history.
clone() {
    local url=$1 folder=$2 ref=$3
    git init --quiet "$folder"
    git -C "$folder" fetch --quiet --depth 1 "$url" "$ref"
    git -C "$folder" -c advice.detachedHead=false checkout --quiet FETCH_HEAD
}

fetch() {
    echo "==> Cloning RBDOOM-3-BFG $FRONTPORT_REF"
    clone https://github.com/RobertBeckebans/RBDOOM-3-BFG.git "$rbdoom" "$FRONTPORT_REF"
    local expected actual
    expected=$(known_commit "$FRONTPORT_REF")
    actual=$(git -C "$rbdoom" rev-parse HEAD)
    if [ -n "$expected" ] && [ "$actual" != "$expected" ]; then
        fail "$FRONTPORT_REF is $actual upstream, but this Recipe was tested with $expected"
    fi
    # The engine's major.minor and the commit's date, such as 1.6.20260807.
    local engine
    engine=$(sed -n 's/^#define[[:space:]]*ENGINE_VERSION[[:space:]]*"RBDOOM 3 BFG \([0-9]*\.[0-9]*\).*/\1/p' \
        "$rbdoom/neo/framework/Licensee.h")
    [ -n "$engine" ] || fail "neo/framework/Licensee.h names no ENGINE_VERSION"
    echo "$engine.$(git -C "$rbdoom" log -1 --format=%cs | tr -d -)" >"$src/version"
    echo "==> Cloning NVRHI and ShaderMake"
    # shellcheck disable=SC2086
    git -C "$rbdoom" submodule --quiet update --init --depth 1 -- $submodules
    git -C "$rbdoom/neo/extern/nvrhi" submodule --quiet update --init --depth 1 -- thirdparty/Vulkan-Headers

    echo "==> Cloning DirectXShaderCompiler $dxc_tag"
    git -c advice.detachedHead=false clone --quiet --depth 1 --branch "$dxc_tag" \
        --recurse-submodules --shallow-submodules https://github.com/microsoft/DirectXShaderCompiler.git "$dxc_src"
    actual=$(git -C "$dxc_src" rev-parse HEAD)
    [ "$actual" = "$dxc_commit" ] || fail "DXC $dxc_tag is $actual upstream, but this Recipe was tested with $dxc_commit"

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
    echo "==> Downloading CPM.cmake"
    mkdir -p "$deps/cpm/cpm"
    curl -fsSL --retry 3 -o "$deps/cpm/cpm/CPM_0.40.8.cmake" "$cpm_url"
    echo "$cpm_sha  $deps/cpm/cpm/CPM_0.40.8.cmake" | shasum -a 256 -c --status - \
        || fail "CPM.cmake doesn't match its pinned sha256"

    echo "==> Patching"
    # ShaderMake runs the compiler through the shell as an unquoted $COMPILER, which splits its path at the space
    # every Frontport build folder has (Application Support).
    replace "$rbdoom/neo/extern/ShaderMake/src/ShaderMake.cpp" '                cmd << "$COMPILER";' \
        '                cmd << "\"$COMPILER\"";'
}

build_libraries() {
    local stamp=$prefix/.frontport-libraries
    local wanted
    wanted=$(echo "$dependencies $cpm_sha $deployment_target" | shasum -a 256 | cut -d' ' -f1)
    if [ -f "$stamp" ] && [ "$(cat "$stamp")" = "$wanted" ]; then
        echo "==> Reusing SDL2, openal-soft and MoltenVK in $prefix"
        return
    fi
    rm -rf "$prefix" "$work/libraries-build"
    local common=(-G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_ARCHITECTURES=arm64
        -DCMAKE_OSX_DEPLOYMENT_TARGET=$deployment_target -DCMAKE_INSTALL_PREFIX="$prefix")

    echo "==> Building SDL2"
    cmake -S "$deps/sdl2" -B "$work/libraries-build/sdl2" "${common[@]}" \
        -DSDL_SHARED=OFF -DSDL_STATIC=ON -DSDL_TEST=OFF
    cmake --build "$work/libraries-build/sdl2" -j "$FRONTPORT_JOBS"
    cmake --install "$work/libraries-build/sdl2"

    echo "==> Building openal-soft"
    # Its -Werror=function-effects fails with Xcode 27's clang on its CoreAudio callbacks; the check stays off.
    cmake -S "$deps/openal-soft" -B "$work/libraries-build/openal-soft" "${common[@]}" \
        -DLIBTYPE=STATIC -DALSOFT_UTILS=OFF -DALSOFT_EXAMPLES=OFF -DALSOFT_TESTS=OFF -DALSOFT_INSTALL_CONFIG=OFF \
        -DALSOFT_INSTALL_HRTF_DATA=OFF -DALSOFT_INSTALL_AMBDEC_PRESETS=OFF -DALSOFT_INSTALL_EXAMPLES=OFF \
        -DALSOFT_INSTALL_UTILS=OFF -DHAVE_WFUNCTION_EFFECTS=OFF
    cmake --build "$work/libraries-build/openal-soft" -j "$FRONTPORT_JOBS"
    cmake --install "$work/libraries-build/openal-soft"

    echo "==> Building MoltenVK"
    # SPIRV-Tools only disassembles SPIR-V in MoltenVK's debug logs, and needs python to build, so it stays out.
    cmake -S "$deps/moltenvk" -B "$work/libraries-build/moltenvk" "${common[@]}" \
        -DCPM_SOURCE_CACHE="$deps/cpm" -DFETCHCONTENT_FULLY_DISCONNECTED=ON \
        -DCPM_SPIRV-Cross_SOURCE="$deps/spirv-cross" -DCPM_cereal_SOURCE="$deps/cereal" \
        -DCPM_Vulkan-Headers_SOURCE="$deps/vulkan-headers" -DMVK_EXCLUDE_SPIRV_TOOLS=ON
    cmake --build "$work/libraries-build/moltenvk" -j "$FRONTPORT_JOBS"
    cmake --install "$work/libraries-build/moltenvk"
    # Its install leaves out the headers the engine includes as <MoltenVK/...>, and names the library by its
    # SOVERSION, libMoltenVK.1.dylib, while the engine loads libMoltenVK.dylib.
    mkdir -p "$prefix/include/MoltenVK"
    cp "$deps/moltenvk/MoltenVK/MoltenVK/API/"*.h "$prefix/include/MoltenVK/"
    install_name_tool -id @rpath/libMoltenVK.dylib "$(realpath "$prefix/lib/libMoltenVK.dylib")"

    rm -rf "$work/libraries-build"
    echo "$wanted" >"$stamp"
}

build_dxc() {
    local stamp=$dxc/.frontport-dxc
    if [ -f "$stamp" ] && [ "$(cat "$stamp")" = "$dxc_commit" ]; then
        echo "==> Reusing DXC in $dxc"
        return
    fi
    rm -rf "$dxc" "$work/dxc-build"
    echo "==> Building DXC"
    # A host tool only, with SPIR-V code generation and without tests. Its version header comes from the source's
    # version.inc: generating it from git runs through a path CMake escapes as "App\ Support", which ninja splits.
    cmake -S "$dxc_src" -B "$work/dxc-build" -G Ninja -C "$dxc_src/cmake/caches/PredefinedParams.cmake" \
        -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_ARCHITECTURES=arm64 -DLLVM_APPEND_VC_REV=OFF \
        -DHLSL_INCLUDE_TESTS=OFF -DSPIRV_BUILD_TESTS=OFF -DLLVM_INCLUDE_TESTS=OFF -DCLANG_INCLUDE_TESTS=OFF \
        -DHLSL_ENABLE_FIXED_VER=ON
    cmake --build "$work/dxc-build" -j "$FRONTPORT_JOBS" --target dxc
    mkdir -p "$dxc/bin" "$dxc/lib"
    cp "$work/dxc-build/bin/dxc" "$dxc/bin/"
    cp "$work/dxc-build/lib/libdxcompiler.dylib" "$dxc/lib/"
    "$dxc/bin/dxc" --version >/dev/null || fail "the DXC build doesn't run"
    rm -rf "$work/dxc-build"
    echo "$dxc_commit" >"$stamp"
}

build() {
    build_libraries
    build_dxc

    echo "==> Configuring RBDOOM-3-BFG"
    rm -rf "$work/build"
    # Precompiled headers are off: their custom command passes include folders unquoted, and every Frontport build
    # folder has a space (Application Support). The static openal-soft, with the frameworks it links against (a STRING, which CMake keeps as written).
    local openal="$prefix/lib/libopenal.a;-framework CoreAudio;-framework AudioToolbox;-framework CoreFoundation"
    cmake -S "$rbdoom/neo" -B "$work/build" -G Ninja -Wno-dev -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=$deployment_target \
        -DCMAKE_PREFIX_PATH="$prefix" -DFFMPEG=OFF -DBINKDEC=ON -DOPENAL=ON -DUSE_MoltenVK=ON \
        -DOPENAL_INCLUDE_DIR="$prefix/include" -DOPENAL_LIBRARY:STRING="$openal" \
        -DVulkan_INCLUDE_DIR="$rbdoom/neo/extern/nvrhi/thirdparty/Vulkan-Headers/include" \
        -DVulkan_LIBRARY="$prefix/lib/libMoltenVK.dylib" \
        -DVulkan_MoltenVK_INCLUDE_DIR="$prefix/include" -DVulkan_MoltenVK_LIBRARY="$prefix/lib/libMoltenVK.dylib" \
        -DVulkan_dxc_EXECUTABLE="$dxc/bin/dxc" -DDXC_SPIRV_PATH="$dxc/bin/dxc" \
        -DISPC_EXECUTABLE="$deps/ispc/bin/ispc" \
        -DCMAKE_BUILD_WITH_INSTALL_RPATH=ON -DCMAKE_INSTALL_RPATH=@executable_path/../Frameworks \
        -DUSE_PRECOMPILED_HEADERS=OFF

    echo "==> Building RBDOOM-3-BFG"
    cmake --build "$work/build" -j "$FRONTPORT_JOBS"

    echo "==> Making RBDOOM-3-BFG.app"
    local executable=$work/build/RBDoom3BFG
    local app=$FRONTPORT_OUT/RBDOOM-3-BFG.app
    local resources=$app/Contents/Resources frameworks=$app/Contents/Frameworks
    [ -x "$executable" ] || fail "the build made no RBDoom3BFG executable"
    [ -d "$rbdoom/base/renderprogs2/spirv" ] || fail "the build compiled no SPIR-V shaders"
    mkdir -p "$app/Contents/MacOS" "$resources" "$frameworks"
    cp "$executable" "$app/Contents/MacOS/RBDoom3BFG"
    cp "$prefix/lib/libMoltenVK.dylib" "$frameworks/"
    # The engine's own files, without the Windows batch files that pack them.
    cp -R "$rbdoom/base" "$resources/base"
    rm -f "$resources/base"/*.bat
    cp "$rbdoom/neo/sys/posix/res/Doom3BFG.icns" "$resources/"

    local version
    version=$(cat "$src/version")
    local plist=$app/Contents/Info.plist
    plutil -create xml1 "$plist"
    plutil -insert CFBundleExecutable -string RBDoom3BFG "$plist"
    plutil -insert CFBundleIdentifier -string "dev.frontport.port.$FRONTPORT_PORT" "$plist"
    plutil -insert CFBundleName -string RBDOOM-3-BFG "$plist"
    plutil -insert CFBundleDisplayName -string RBDOOM-3-BFG "$plist"
    plutil -insert CFBundlePackageType -string APPL "$plist"
    plutil -insert CFBundleInfoDictionaryVersion -string 6.0 "$plist"
    plutil -insert CFBundleShortVersionString -string "$version" "$plist"
    plutil -insert CFBundleVersion -string "$version" "$plist"
    plutil -insert CFBundleIconFile -string Doom3BFG "$plist"
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
