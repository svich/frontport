#!/bin/bash
# Frontport Recipe: Starship (HarbourMasters/Starship), a Star Fox 64 Decomp.
# Contract: catalog/recipes/README.md. Invoked as `starship.sh fetch`, then `starship.sh build`.
#
# Build Assets: sf64.o2r, extracted with Torch from a US Build-Stage ROM, left at $FRONTPORT_OUT/assets
# for the Catalog's buildAssets.path "Contents/Resources/sf64.o2r". On macOS upstream looks for its .o2r
# archives only in $SHIP_HOME or the working directory ("/" when launched from Finder), so fetch adds a
# small source file that makes Starship read them from the bundle's Resources first and keep its Data in
# ~/Library/Application Support/Starship, which the App Sandbox puts in the container.
set -euo pipefail

step=${1:?usage: starship.sh fetch|build}
src=$FRONTPORT_SRC
work=$(dirname "$src")                 # Builds/<port>: writable during build, kept between builds
deps=$src/deps
starship=$src/Starship
prefix=$work/prefix                    # libraries built from deps/, reused while their pins don't change
deployment_target=13.0
export CMAKE_POLICY_VERSION_MINIMUM=3.5 # vorbis still declares cmake_minimum_required(2.8.12)
export GIT_CEILING_DIRECTORIES=$work

# Commits of the tags this Recipe was tested against, so a moved tag fails the fetch.
known_commit() {
    case "$1" in
        v2.0.0) echo cb19785b51698185a688e17ba1a34c7889195bdb ;;
    esac
}

# name sha256 url. Archives unpack into deps/<name>; other files are kept as deps/<name>.
# Libraries built into the prefix:
libraries="
sdl2 5f5993c530f084535c65a6879e9b26ad441169b3e25d789d83287040a9ca5165 https://github.com/libsdl-org/SDL/releases/download/release-2.32.10/SDL2-2.32.10.tar.gz
glew b64790f94b926acd7e8f84c5d6000a86cb43967bd1e688b03089079799c9e889 https://github.com/nigels-com/glew/releases/download/glew-2.3.1/glew-2.3.1.tgz
libzip c40062022a1963c80573d48f6070792297cecd7c6bffe3aefcac0d8b9bee8913 https://github.com/nih-at/libzip/releases/download/v1.12.1/libzip-1.12.1.tar.xz
json 42f6e95cad6ec532fd372391373363b62a14af6d771056dbfc86160e6dfff7aa https://github.com/nlohmann/json/releases/download/v3.12.0/json.tar.xz
ogg 5c8253428e181840cd20d41f3ca16557a9cc04bad4a3d04cce84808677fa1061 https://github.com/xiph/ogg/releases/download/v1.3.6/libogg-1.3.6.tar.xz
vorbis b33cc4934322bcbf6efcbacf49e3ca01aadbea4114ec9589d1b1e9d20f72954b https://github.com/xiph/vorbis/releases/download/v1.3.7/libvorbis-1.3.7.tar.xz
tinyxml2 d5ae097578717b42b4f05f2c6b2d09f473a1c30d1552ca4e2dcb4eab5b34de84 https://github.com/leethomason/tinyxml2/archive/321ea883b7190d4e85cae5512a12e5eaa8f8731f.tar.gz
"
# What upstream's CMake would download at configure time, pinned to the commits it names (or, for the two
# it takes from a branch, to what that branch held at the v2.0.0 release). Torch's standalone build pins
# an older spdlog that current Clang rejects, so it uses libultraship's v1.14.1 instead.
sources="
imgui cc35a88df717dff3c488e43b4b148dcfe968bd3ff6798f60751b106eb9bcee48 https://github.com/ocornut/imgui/archive/4806a1924ff6181180bf5e4b8b79ab4394118875.tar.gz
stormlib cedf9304399339af1a473f89875e9855dc40b588f29f826da081cb12028a4f2f https://github.com/ladislav-zezula/StormLib/archive/28c9b4be3f23c6b3a5ff55cacac7dbe5b9cdc4fc.tar.gz
threadpool 8e54280b4d9af3e4d2fd3dfa3f8d1198fc1c3a572d6f22c5eaf1abe38f2db0a8 https://github.com/bshoshany/thread-pool/archive/097aa718f25d44315cadb80b407144ad455ee4f9.tar.gz
prism 3ff592035105b6ed472b4fee8e8f2d05cce245ec052e67261364165864fd9188 https://github.com/KiritoDv/prism-processor/archive/7ae724a6fb7df8cbf547445214a1a848aefef747.tar.gz
spdlog 7d512b37019b61646cd6fd1e48f52a3cf3e098f36b33ba9c059fe51301ff40b3 https://github.com/gabime/spdlog/archive/27cb4c76708608465c413f6d0e6b8d99a4d84302.tar.gz
metalcpp 9f3d9f9a48663b99e29eb15f6c5cc80f8f34ef770df98a0935fa16b292cf7766 https://github.com/briaguya-ai/single-header-metal-cpp/archive/7bf710a725b386f6db869f8a2b48a56be29b6233.tar.gz
dr_libs 2704d347f480ca1bc92233fb01747e4550cc8031735b6ea62ca9990ebb8851ae https://github.com/mackron/dr_libs/archive/da35f9d6c7374a95353fd1df1d394d44ab66cf01.tar.gz
yaml-cpp a0566d97168c9588734f260ed3220e2d1823f52401d24432bbd26410eeb2b73f https://github.com/jbeder/yaml-cpp/archive/28f93bdec6387d42332220afa9558060c8016795.tar.gz
libgfxd 96d830f6ff9c8a91c8052b51ca02ffdfd1d44ab0a9d20f899f65d4c931073696 https://github.com/glankk/libgfxd/archive/96fd3b849f38b3a7c7b7f3ff03c5921d328e6cdf.tar.gz
stb_image.h c54b15a689e6a1f32c75e2ec23afa442e3e0e37e894b73c1974d08679b20dd5c https://raw.githubusercontent.com/nothings/stb/0bc88af4de5fb022db643c2d8e549a0927749354/stb_image.h
sse2neon.h b49b9e5dc5f1ed9377046c1d91eae279432db25a281a929a72a9baada6274beb https://raw.githubusercontent.com/DLTcollab/sse2neon/658eeac2fe8d37912bba074260f1c604cf037c73/sse2neon.h
gamecontrollerdb.txt c6587cc65789539e61ec375aad5bdbc14f974508b57e2ae87730ac75c4445dba https://raw.githubusercontent.com/mdqinc/SDL_GameControllerDB/ff333823a85ae896e73f4c53670932cf0f728adb/gamecontrollerdb.txt
"

fail() {
    echo "error: $*" >&2
    exit 1
}

# Replaces exactly the text given in a file, failing loudly when upstream changed it.
replace() {
    local file=$1 old=$2 new=$3
    grep -qF -- "$old" "$file" || fail "$file no longer contains: $old"
    OLD=$old NEW=$new perl -0pi -e 's/\Q$ENV{OLD}\E/$ENV{NEW}/g' "$file"
}

fetch() {
    echo "==> Cloning Starship $FRONTPORT_REF"
    git -c advice.detachedHead=false clone --quiet --depth 1 --branch "$FRONTPORT_REF" \
        --recurse-submodules --shallow-submodules https://github.com/HarbourMasters/Starship.git "$starship"
    local expected actual
    expected=$(known_commit "$FRONTPORT_REF")
    actual=$(git -C "$starship" rev-parse HEAD)
    if [ -n "$expected" ] && [ "$actual" != "$expected" ]; then
        fail "$FRONTPORT_REF is $actual upstream, but this Recipe was tested with $expected"
    fi

    mkdir -p "$deps"
    local name sha url file
    while read -r name sha url; do
        [ -n "$name" ] || continue
        echo "==> Downloading $name"
        file=$deps/$name.download
        curl -fsSL --retry 3 -o "$file" "$url"
        echo "$sha  $file" | shasum -a 256 -c --status - || fail "$name doesn't match its pinned sha256"
        case "$url" in
            *.tar.gz | *.tgz | *.tar.xz)
                mkdir -p "$deps/$name"
                tar -xf "$file" -C "$deps/$name" --strip-components=1
                rm "$file"
                ;;
            *) mv "$file" "$deps/$name" ;;
        esac
    done <<<"$libraries$sources"

    echo "==> Patching"
    local patches=$starship/libultraship/cmake/dependencies/patches
    (cd "$deps/imgui" && patch -p1 --forward --quiet <"$patches/imgui-fixes-and-config.patch")
    (cd "$deps/stormlib" && patch -p1 --forward --quiet <"$patches/stormlib-optimizations.patch")
    # Configure-time downloads, which the build sandbox can't make, read the pinned copies instead.
    replace "$starship/CMakeLists.txt" \
        'https://raw.githubusercontent.com/DLTcollab/sse2neon/refs/heads/master/sse2neon.h' \
        'file://${CMAKE_SOURCE_DIR}/../deps/sse2neon.h'
    replace "$starship/libultraship/cmake/dependencies/common.cmake" \
        'https://github.com/nothings/stb/raw/0bc88af4de5fb022db643c2d8e549a0927749354/stb_image.h' \
        'file://${CMAKE_SOURCE_DIR}/../deps/stb_image.h'
    # sips and iconutil need LaunchServices, which the build sandbox doesn't offer; build makes the icon.
    replace "$starship/CMakeLists.txt" 'add_dependencies(${PROJECT_NAME} CreateOSXIcons)' ''
    # Archives inside the bundle, Data in the container.
    replace "$starship/src/port/Engine.cpp" \
        'Ship::Context::GetPathRelativeToAppDirectory("sf64.o2r")' 'FrontportArchivePath("sf64.o2r")'
    replace "$starship/src/port/Engine.cpp" \
        'Ship::Context::GetPathRelativeToAppDirectory("starship.o2r")' 'FrontportArchivePath("starship.o2r")'
    replace "$starship/src/port/Engine.cpp" \
        'GameEngine* GameEngine::Instance;' \
        'GameEngine* GameEngine::Instance;
std::string FrontportArchivePath(const std::string& name);'
    cat >"$starship/src/port/FrontportBundle.cpp" <<'EOF'
// Added by Frontport's Recipe so Starship runs from a sandboxed app bundle.
#include <cstdlib>
#include <filesystem>
#include <string>
#include <unistd.h>

#include "Context.h"

// Keeps Data (config, saves, logs, mods) in ~/Library/Application Support/Starship, which the App
// Sandbox places inside the Port's container, instead of the working directory ("/" from Finder).
__attribute__((constructor)) static void FrontportUseDataFolder() {
    if (std::getenv("SHIP_HOME") != nullptr) {
        return;
    }
    const char* home = std::getenv("HOME");
    if (home == nullptr) {
        return;
    }
    const std::filesystem::path data = std::filesystem::path(home) / "Library" / "Application Support" / "Starship";
    std::error_code error;
    std::filesystem::create_directories(data, error);
    setenv("SHIP_HOME", data.c_str(), 0);
    chdir(data.c_str());
}

// An .o2r archive from the bundle's Resources when it ships there, else from the Data folder.
std::string FrontportArchivePath(const std::string& name) {
    const std::string bundled = Ship::Context::GetPathRelativeToAppBundle(name);
    if (std::filesystem::exists(bundled)) {
        return bundled;
    }
    return Ship::Context::GetPathRelativeToAppDirectory(name);
}
EOF
}

common_cmake_flags=(
    -G Ninja
    -DCMAKE_BUILD_TYPE=Release
    -DCMAKE_OSX_ARCHITECTURES=arm64
    -DCMAKE_OSX_DEPLOYMENT_TARGET=$deployment_target
    -DCMAKE_PREFIX_PATH="$prefix"
)

# cmake_library <name> <source subfolder> [cmake flags...]: builds and installs one static library.
cmake_library() {
    local name=$1 subfolder=$2
    shift 2
    echo "==> Building $name"
    cmake -S "$deps/$name/$subfolder" -B "$work/deps-build/$name" "${common_cmake_flags[@]}" \
        -DCMAKE_INSTALL_PREFIX="$prefix" -DBUILD_SHARED_LIBS=OFF "$@"
    cmake --build "$work/deps-build/$name" -j "$FRONTPORT_JOBS"
    cmake --install "$work/deps-build/$name"
}

build_libraries() {
    local stamp=$prefix/.frontport-libraries
    local wanted
    wanted=$(echo "$libraries $deployment_target" | shasum -a 256 | cut -d' ' -f1)
    if [ -f "$stamp" ] && [ "$(cat "$stamp")" = "$wanted" ]; then
        echo "==> Reusing libraries in $prefix"
        return
    fi
    rm -rf "$prefix" "$work/deps-build"
    cmake_library sdl2 . -DSDL_SHARED=OFF -DSDL_STATIC=ON -DSDL_TEST=OFF
    cmake_library glew build/cmake -DGLEW_X11=OFF -DBUILD_UTILS=OFF
    cmake_library libzip . -DBUILD_TOOLS=OFF -DBUILD_REGRESS=OFF -DBUILD_OSSFUZZ=OFF -DBUILD_EXAMPLES=OFF \
        -DBUILD_DOC=OFF -DENABLE_LZMA=OFF -DENABLE_ZSTD=OFF -DENABLE_GNUTLS=OFF -DENABLE_OPENSSL=OFF -DENABLE_MBEDTLS=OFF
    cmake_library json . -DJSON_BuildTests=OFF
    cmake_library tinyxml2 . -Dtinyxml2_BUILD_TESTING=OFF
    cmake_library ogg . -DINSTALL_DOCS=OFF
    cmake_library vorbis .
    echo "$wanted" >"$stamp"
}

fetchcontent_flags=(
    -DFETCHCONTENT_FULLY_DISCONNECTED=ON
    -DFETCHCONTENT_SOURCE_DIR_DR_LIBS="$deps/dr_libs"
    -DFETCHCONTENT_SOURCE_DIR_IMGUI="$deps/imgui"
    -DFETCHCONTENT_SOURCE_DIR_STORMLIB="$deps/stormlib"
    -DFETCHCONTENT_SOURCE_DIR_THREADPOOL="$deps/threadpool"
    -DFETCHCONTENT_SOURCE_DIR_PRISM="$deps/prism"
    -DFETCHCONTENT_SOURCE_DIR_METALCPP="$deps/metalcpp"
    -DFETCHCONTENT_SOURCE_DIR_YAML-CPP="$deps/yaml-cpp"
    -DFETCHCONTENT_SOURCE_DIR_TINYXML2="$deps/tinyxml2"
)

build() {
    build_libraries

    # Upstream built v2.0.0 with an older Clang. Xcode 27's rejects fmt 10's compile-time format string
    # checks ("call to consteval function ... is not a constant expression"), so spdlog's bundled fmt
    # checks them at run time instead, and makes Torch's chained comparisons errors, which stay warnings.
    # Torch overwrites CMAKE_CXX_FLAGS, so these go in through every project() call.
    printf '%s\n' 'add_compile_definitions(FMT_CONSTEVAL=)' 'add_compile_options(-Wno-error=parentheses)' \
        >"$work/frontport-compat.cmake"
    fetchcontent_flags+=(-DCMAKE_PROJECT_INCLUDE="$work/frontport-compat.cmake")

    # Torch, standalone: packs starship.o2r and extracts sf64.o2r from the ROM.
    echo "==> Building Torch"
    cmake -S "$starship/tools/Torch" -B "$work/torch-build" "${common_cmake_flags[@]}" "${fetchcontent_flags[@]}" \
        -DFETCHCONTENT_SOURCE_DIR_LIBGFXD="$deps/libgfxd" -DFETCHCONTENT_SOURCE_DIR_SPDLOG="$deps/spdlog" \
        -DBUILD_SM64=OFF -DBUILD_MK64=OFF -DBUILD_FZERO=OFF
    cmake --build "$work/torch-build" --target torch -j "$FRONTPORT_JOBS"
    local torch=$work/torch-build/torch

    echo "==> Building Starship"
    cmake -S "$starship" -B "$work/build" "${common_cmake_flags[@]}" "${fetchcontent_flags[@]}" \
        -DFETCHCONTENT_SOURCE_DIR_SPDLOG="$deps/spdlog"
    cmake --build "$work/build" --target Starship -j "$FRONTPORT_JOBS"

    echo "==> Packing starship.o2r"
    rm -f "$work/starship.o2r"
    (cd "$starship" && "$torch" pack port "$work/starship.o2r" o2r)

    echo "==> Making Starship.app"
    local app=$FRONTPORT_OUT/Starship.app version=${FRONTPORT_REF#v}
    mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
    cp "$work/build/Starship" "$app/Contents/MacOS/Starship"
    cp "$starship/Info.plist" "$app/Contents/Info.plist"
    plutil -replace CFBundleShortVersionString -string "$version" "$app/Contents/Info.plist"
    plutil -replace CFBundleVersion -string "$version" "$app/Contents/Info.plist"
    plutil -replace CFBundleGetInfoString -string "$version" "$app/Contents/Info.plist"
    plutil -replace LSMinimumSystemVersion -string "$deployment_target" "$app/Contents/Info.plist"
    plutil -remove LSArchitecturePriority "$app/Contents/Info.plist"
    make_icns "$starship/logo.png" "$app/Contents/Resources/Starship.icns"
    cp "$work/starship.o2r" "$app/Contents/Resources/starship.o2r"
    cp "$deps/gamecontrollerdb.txt" "$app/Contents/Resources/gamecontrollerdb.txt"

    extract_assets
}

# make_icns <square png> <icns>: an icon holding the PNG as is; macOS scales it for smaller sizes.
make_icns() {
    python3 - "$1" "$2" <<'EOF'
import struct, sys
png = open(sys.argv[1], "rb").read()
width, height = struct.unpack(">II", png[16:24])
types = {128: [b"ic07"], 256: [b"ic08", b"ic13"], 512: [b"ic09", b"ic14"], 1024: [b"ic10"]}
assert png[:8] == b"\x89PNG\r\n\x1a\n" and width == height and width in types, f"unusable icon {width}x{height}"
entries = b"".join(kind + struct.pack(">I", len(png) + 8) + png for kind in types[width])
open(sys.argv[2], "wb").write(b"icns" + struct.pack(">I", len(entries) + 8) + entries)
EOF
}

# sf64.o2r from the first US ROM among the Build-Stage ROMs; nothing when there are none.
extract_assets() {
    local rom
    for rom in "$FRONTPORT_ROMS"/*.z64; do
        [ -e "$rom" ] || continue
        echo "==> Extracting assets from $(basename "$rom")"
        rm -f "$starship/sf64.o2r"
        (cd "$starship" && "$work/torch-build/torch" o2r "$rom")
        if [ -f "$starship/sf64.o2r" ]; then
            mv "$starship/sf64.o2r" "$FRONTPORT_OUT/assets"
            return
        fi
    done
    echo "==> No US ROM given: skipping assets"
}

case "$step" in
    fetch) fetch ;;
    build) build ;;
    *) fail "unknown step $step" ;;
esac
