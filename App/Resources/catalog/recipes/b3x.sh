#!/bin/bash
# Frontport Recipe: b3x (aribrilliantsyah/Burnout3-Recompiled-Mobile), Burnout 3: Takedown statically recompiled
# from the Xbox's default.xbe with the vendored xboxrecomp toolkit.
# Contract: catalog/recipes/README.md. Invoked as `b3x.sh fetch`, then `b3x.sh build`.
#
# Upstream ships an Android APK and builds a desktop program on Linux (SDL2 + Vulkan); it has no Mac build. The
# game's code is never distributed: it is lifted from the user's disc to C in the build, so the disc image is a
# Build-Stage ROM. build unpacks it (the toolkit's tools.xiso) into the Build Assets, the read-only game folder the
# game reads as its D: drive, lifts default.xbe with the toolkit's Python pipeline (tools/regen.sh: disasm,
# func_id, abi_analysis, recomp) and compiles the generated C with upstream's CMake, Vulkan renderer on, against
# static SDL2 and glslang, and MoltenVK (Vulkan on Metal), which the app carries in Contents/Frameworks.
# The generated C is kept in Builds/<port>/gen with the XBE's sha256, so a build with no ROM (an update that carries
# the Build Assets over) compiles from it; with neither, the build fails.
# Python is a pinned standalone 3.14 with the capstone wheel; the developer tools' python3 is too old.
# fetch patches the build for macOS: the kernel library links OpenSSL on desktop though nothing calls it; guest
# threads are pinned to a core with Linux's affinity calls, which macOS lacks, so they float; the D3D8 HLE layer
# wants libepoxy for an OpenGL renderer the Vulkan build doesn't use, so it takes Android's null one; and the Vulkan
# renderer finds SDL2 through pkg-config and links SPIRV-Tools and libstdc++. And the runtime, for macOS and the
# sandbox: the Xbox's RAM is shared memory from shm_open, which the App Sandbox refuses without an app group, so it
# is an unlinked file in $TMPDIR; the title keeps TDATA and UDATA on its E: drive, which the toolkit puts in the
# read-only game folder, so they go to its T: and U: folders with the saves; AppKit makes windows and pumps events
# only on the main thread, where the desktop main runs the game, so the game runs on its own thread as on Android,
# the main thread pumps events and makes the window and its Vulkan surface, and the renderer only reads events;
# pads go through the GameController framework and IOKit (SDL's HIDAPI is off, as the sandbox gives no HID access to
# Bluetooth pads), started on the main thread. The game looks for its folder in ./game, so on macOS it looks in the
# app's Resources/game (SDL_GetBasePath), and points SDL at the app's MoltenVK. Saves and the Xbox's hard disk
# images go to ~/.local/share/xboxrecomp (the toolkit's default), which the App Sandbox puts in the container.
set -euo pipefail

step=${1:?usage: b3x.sh fetch|build}
src=$FRONTPORT_SRC
work=$(dirname "$src")                 # Builds/<port>: writable during build, kept between builds
deps=$src/deps
b3x=$src/b3x
prefix=$work/prefix                    # SDL2, glslang and MoltenVK, reused while their pins don't change
gen=$work/gen                          # the C lifted from default.xbe, reused while the XBE and the toolkit don't change
deployment_target=13.0
export MACOSX_DEPLOYMENT_TARGET=$deployment_target
export GIT_CEILING_DIRECTORIES=$work

# name sha256 url. spirv-cross, cereal and vulkan-headers are the commits MoltenVK's ExternalRevisions pin, and
# cpm is the CPM.cmake its cmake/recipes/CPM.cmake downloads. python is unpacked; capstone is a wheel, unzipped
# into deps/site.
dependencies="
python 226d696642a8a53d03b4d5b255b1c319b1575a6d44bd723a953c9f507755e36a https://github.com/astral-sh/python-build-standalone/releases/download/20261021/cpython-3.14.9%2B20261021-aarch64-apple-darwin-install_only.tar.gz
sdl2 5f5993c530f084535c65a6879e9b26ad441169b3e25d789d83287040a9ca5165 https://github.com/libsdl-org/SDL/releases/download/release-2.32.10/SDL2-2.32.10.tar.gz
glslang 9c09b901149c729df745057dafa815278aaa101b84d2b6e14f16a42de52f97f2 https://github.com/KhronosGroup/glslang/archive/refs/tags/16.6.0.tar.gz
moltenvk 6864db532f1dbbdb621a8d0ec13f24edae318fd9269dd3dd0cdff791334bb1cb https://github.com/KhronosGroup/MoltenVK/archive/refs/tags/v1.4.2.tar.gz
spirv-cross b81b9956289950570953738e666a031ca32ff64e4fc925eba89f227c42109518 https://github.com/KhronosGroup/SPIRV-Cross/archive/6c09849fe88c48eaed08413aa022aaa136a3a057.tar.gz
cereal 12e10fb541270632f6683286ce8c7e8c321fe4addb53fa91ed498b95c1758f93 https://github.com/USCiLab/cereal/archive/a56bad8bbb770ee266e930c95d37fff2a5be7fea.tar.gz
vulkan-headers f492279345cbc10708b64fcd432b3ff6c8246a5837c4db2b649abba00cf82208 https://github.com/KhronosGroup/Vulkan-Headers/archive/e3b1eec08173d6b825cd3ac88c885a63b621504a.tar.gz
"
capstone_sha=fc269c5082e17d7f9f265cd6980e2fdc6ab572df913951d76db0357e06b8001d
capstone_url=https://files.pythonhosted.org/packages/42/9a/4eecfbc94961cda70301fd13de69042be1943bee456e37bc1369840601b1/capstone-5.0.9-py3-none-macosx_11_0_arm64.whl
cpm_sha=78ba32abdf798bc616bab7c73aac32a17bbd7b06ad9e26a6add69de8f3ae4791
cpm_url=https://github.com/cpm-cmake/CPM.cmake/releases/download/v0.40.8/CPM.cmake

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
    echo "==> Cloning b3x $FRONTPORT_REF"
    git clone --quiet https://github.com/aribrilliantsyah/Burnout3-Recompiled-Mobile.git "$b3x"
    git -C "$b3x" -c advice.detachedHead=false checkout --quiet "$FRONTPORT_REF"
    sed -n 's/^VERSION_NAME=//p' "$b3x/android/version.properties" >"$src/version"
    [ -s "$src/version" ] || git -C "$b3x" rev-parse --short HEAD >"$src/version"

    mkdir -p "$deps/site" "$deps/cpm/cpm"
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
    echo "==> Downloading capstone"
    download "$deps/capstone.whl" "$capstone_sha" "$capstone_url"
    unzip -q "$deps/capstone.whl" -d "$deps/site"
    rm "$deps/capstone.whl"
    echo "==> Downloading CPM.cmake"
    download "$deps/cpm/cpm/CPM_0.40.8.cmake" "$cpm_sha" "$cpm_url"

    echo "==> Patching"
    local tk=$b3x/xboxrecomp
    replace "$tk/src/kernel/CMakeLists.txt" '    if(ANDROID)
        target_link_libraries(xbox_kernel PUBLIC platform)' '    if(ANDROID OR APPLE)
        target_link_libraries(xbox_kernel PUBLIC platform)'
    replace "$tk/src/platform/win32_compat.c" '#else
    {
        cpu_set_t set;' '#elif defined(__APPLE__)
    (void)interrupt;   /* Frontport: macOS has no way to pin a thread to a core */
#else
    {
        cpu_set_t set;'
    replace "$tk/src/platform/win32_compat.c" '    static volatile LONG map_counter = 0;
    char shm_name[32];
    LONG seq = InterlockedIncrement(&map_counter);
    const char *base = name ? name : "xbox_map";
    snprintf(shm_name, sizeof(shm_name), "/%s_%ld", base, seq);
    int fd = shm_open(shm_name, O_CREAT | O_RDWR | O_EXCL, 0600);
    if (fd >= 0) shm_unlink(shm_name);
    return fd;' '    /* Frontport: the App Sandbox refuses shm_open without an app group, so an unlinked file in $TMPDIR. */
    char path[1024];
    const char *tmp = getenv("TMPDIR");
    (void)name;
    snprintf(path, sizeof(path), "%s/xbox_map.XXXXXX", (tmp && tmp[0]) ? tmp : "/tmp");
    int fd = mkstemp(path);
    if (fd >= 0) unlink(path);
    return fd;'
    replace "$tk/src/kernel/kernel_path.c" '    { "\\Device\\Harddisk0\\Partition1\\",    0, NULL,         NULL          },' \
'    /* Frontport: the game folder is read-only, so the title'"'"'s own and its saves'"'"' folders on E: are T: and U:. */
    { "\\Device\\Harddisk0\\Partition1\\TDATA", 1, "\\TitleData", "/TitleData" },
    { "\\Device\\Harddisk0\\Partition1\\UDATA", 1, "\\UserData", "/UserData"   },
    { "\\Device\\Harddisk0\\Partition1\\",    0, NULL,         NULL          },'
    # AppKit makes windows and pumps events only on the main thread, where upstream's desktop main runs the game
    # and its renderer makes the window from a GPU thread. On macOS the game gets its own thread, as on Android;
    # the main thread pumps events and makes the window and its Vulkan surface; the renderer only reads events.
    replace "$b3x/src/main.c" 'int main(int argc, char **argv)
{
    (void)argc;
    (void)argv;
    return b3x_game_main();
}' '#if defined(__APPLE__)
#include <pthread.h>
#include <CoreFoundation/CoreFoundation.h>
extern int SDL_InitSubSystem(uint32_t flags);
extern void SDL_PumpEvents(void);

static void *frontport_game_thread(void *arg)
{
    (void)arg;
    exit(b3x_game_main());
    return NULL;
}

int main(int argc, char **argv)
{
    pthread_attr_t attr;
    pthread_t th;
    (void)argc;
    (void)argv;
    /* Pads through the GameController framework and IOKit: the SDL HIDAPI drivers need HID access to
     * Bluetooth pads that the App Sandbox does not give. Started here, where events are pumped, so
     * pads are found; xbox_InputInit then finds the subsystem up. */
    setenv("SDL_JOYSTICK_HIDAPI", "0", 0);
    if (SDL_InitSubSystem(0x00000020u | 0x00002000u /* SDL_INIT_VIDEO | SDL_INIT_GAMECONTROLLER */) != 0)
        fprintf(stderr, "[macOS] SDL video or game controllers failed to start\n");
    pthread_attr_init(&attr);
    pthread_attr_setstacksize(&attr, 16u * 1024 * 1024);
    if (pthread_create(&th, &attr, frontport_game_thread, NULL) != 0) {
        fprintf(stderr, "[FATAL] cannot start the game thread\n");
        return 1;
    }
    for (;;) {
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.005, true);
        SDL_PumpEvents();
    }
}
#else
int main(int argc, char **argv)
{
    (void)argc;
    (void)argv;
    return b3x_game_main();
}
#endif'
    local vk=$tk/src/nv2a_vk/nv2a_vk.c
    replace "$vk" 'static int ready(void)
{' '#if defined(__APPLE__)
#include <dispatch/dispatch.h>
/* Frontport: the window and its Vulkan surface are made on the main thread, as AppKit needs. */
static SDL_Window *frontport_create_window(void)
{
    __block SDL_Window *w = NULL;
    dispatch_sync(dispatch_get_main_queue(), ^{
        w = SDL_CreateWindow("Burnout 3: Takedown", SDL_WINDOWPOS_CENTERED, SDL_WINDOWPOS_CENTERED,
                             1280, 720, SDL_WINDOW_VULKAN | SDL_WINDOW_RESIZABLE);
    });
    return w;
}

static SDL_bool frontport_create_surface(void)
{
    __block SDL_bool made = SDL_FALSE;
    dispatch_sync(dispatch_get_main_queue(), ^{
        made = SDL_Vulkan_CreateSurface(s_win, s_inst, &s_surface);
    });
    return made;
}
#endif

static int ready(void)
{'
    replace "$vk" '                s_win = SDL_CreateWindow("NV2A (Vulkan)", SDL_WINDOWPOS_CENTERED, SDL_WINDOWPOS_CENTERED,
                                         1280, 720, SDL_WINDOW_VULKAN | SDL_WINDOW_RESIZABLE);' '#if defined(__APPLE__)
                s_win = frontport_create_window();
#else
                s_win = SDL_CreateWindow("NV2A (Vulkan)", SDL_WINDOWPOS_CENTERED, SDL_WINDOWPOS_CENTERED,
                                         1280, 720, SDL_WINDOW_VULKAN | SDL_WINDOW_RESIZABLE);
#endif'
    replace "$vk" '    if (!s_headless && !SDL_Vulkan_CreateSurface(s_win, s_inst, &s_surface)) {' '#if defined(__APPLE__)
    if (!s_headless && !frontport_create_surface()) {
#else
    if (!s_headless && !SDL_Vulkan_CreateSurface(s_win, s_inst, &s_surface)) {
#endif'
    replace "$vk" '        while (SDL_PollEvent(&e)) {' '#if defined(__APPLE__)
        /* Frontport: the main thread pumps; here the queue is only read, and quitting ends the game. */
        while (SDL_PeepEvents(&e, 1, SDL_GETEVENT, SDL_FIRSTEVENT, SDL_LASTEVENT) > 0) {
            if (e.type == SDL_QUIT)
                exit(0);
#else
        while (SDL_PollEvent(&e)) {
#endif'
    replace "$tk/src/d3d/CMakeLists.txt" 'elseif(ANDROID)
    # No HLE D3D8 renderer' 'elseif(ANDROID OR XBOXRECOMP_VULKAN)
    # No HLE D3D8 renderer'
    replace "$tk/src/nv2a_vk/CMakeLists.txt" '    find_package(PkgConfig REQUIRED)
    pkg_check_modules(SDL2 REQUIRED IMPORTED_TARGET sdl2)
    # The distribution glslang is built with its optimizer (static SPIRV-Tools).
    target_link_libraries(xbox_nv2a_vk PUBLIC Vulkan::Vulkan PkgConfig::SDL2
        SPIRV-Tools-opt SPIRV-Tools stdc++)' '    # Frontport: static SDL2 by its CMake package, glslang without its optimizer, and libc++.
    find_package(SDL2 REQUIRED)
    target_link_libraries(xbox_nv2a_vk PUBLIC Vulkan::Vulkan SDL2::SDL2 c++)'
    replace "$b3x/src/main.c" '    game_dir = getenv("NFSU2_GAME_DIR");
    if (!game_dir || !game_dir[0])
        game_dir = NFSU2_DEFAULT_GAME_DIR;' '    game_dir = getenv("NFSU2_GAME_DIR");
#if defined(__APPLE__)
    /* Frontport: the game folder is the app'"'"'s Resources/game, and SDL loads the app'"'"'s MoltenVK. */
    if (!game_dir || !game_dir[0]) {
        extern char *SDL_GetBasePath(void);
        static char bundle_game[4096], moltenvk[4096];
        char *base = SDL_GetBasePath();
        if (base) {
            snprintf(bundle_game, sizeof(bundle_game), "%sgame", base);
            snprintf(moltenvk, sizeof(moltenvk), "%s../Frameworks/libMoltenVK.dylib", base);
            if (!getenv("SDL_VULKAN_LIBRARY")) setenv("SDL_VULKAN_LIBRARY", moltenvk, 1);
            game_dir = bundle_game;
        }
    }
#endif
    if (!game_dir || !game_dir[0])
        game_dir = NFSU2_DEFAULT_GAME_DIR;'
}

build_libraries() {
    local stamp=$prefix/.frontport-libraries
    local wanted
    wanted=$(echo "$dependencies $cpm_sha $deployment_target" | shasum -a 256 | cut -d' ' -f1)
    if [ -f "$stamp" ] && [ "$(cat "$stamp")" = "$wanted" ]; then
        echo "==> Reusing SDL2, glslang and MoltenVK in $prefix"
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

    echo "==> Building glslang"
    # The renderer compiles its generated GLSL at run time; the optimizer would need SPIRV-Tools.
    cmake -S "$deps/glslang" -B "$work/libraries-build/glslang" "${common[@]}" \
        -DENABLE_OPT=OFF -DGLSLANG_TESTS=OFF -DGLSLANG_ENABLE_INSTALL=ON -DENABLE_GLSLANG_BINARIES=OFF \
        -DBUILD_SHARED_LIBS=OFF -DBUILD_EXTERNAL=OFF
    cmake --build "$work/libraries-build/glslang" -j "$FRONTPORT_JOBS"
    cmake --install "$work/libraries-build/glslang"

    echo "==> Building MoltenVK"
    # SPIRV-Tools only disassembles SPIR-V in MoltenVK's debug logs, and needs python to build, so it stays out.
    cmake -S "$deps/moltenvk" -B "$work/libraries-build/moltenvk" "${common[@]}" \
        -DCPM_SOURCE_CACHE="$deps/cpm" -DFETCHCONTENT_FULLY_DISCONNECTED=ON \
        -DCPM_SPIRV-Cross_SOURCE="$deps/spirv-cross" -DCPM_cereal_SOURCE="$deps/cereal" \
        -DCPM_Vulkan-Headers_SOURCE="$deps/vulkan-headers" -DMVK_EXCLUDE_SPIRV_TOOLS=ON
    cmake --build "$work/libraries-build/moltenvk" -j "$FRONTPORT_JOBS"
    cmake --install "$work/libraries-build/moltenvk"
    install_name_tool -id @rpath/libMoltenVK.dylib "$(realpath "$prefix/lib/libMoltenVK.dylib")"

    rm -rf "$work/libraries-build"
    echo "$wanted" >"$stamp"
}

# lift <default.xbe>: the toolkit's pipeline, from the XBE to C in $gen, unless $gen already holds this XBE's.
lift() {
    local xbe=$1 stamp=$gen/.frontport-gen wanted
    wanted="$(shasum -a 256 "$xbe" | cut -d' ' -f1) $(cat "$src/version") $(git -C "$b3x" rev-parse HEAD)"
    if [ -f "$stamp" ] && [ "$(cat "$stamp")" = "$wanted" ]; then
        echo "==> Reusing the code lifted from default.xbe"
        return
    fi
    rm -rf "$gen" "$work/xbe"
    # The pipeline writes its analysis beside the XBE, so it works on a copy outside the Build Assets.
    mkdir -p "$work/xbe"
    cp "$xbe" "$work/xbe/default.xbe"
    echo "==> Lifting default.xbe to C"
    PYTHONPATH="$deps/site" PYTHON="$deps/python/bin/python3" B3_XBE="$work/xbe/default.xbe" B3_GEN_DIR="$gen" \
        bash "$b3x/tools/regen.sh"
    [ -f "$gen/recomp_funcs.h" ] || fail "the recompiler wrote no recomp_funcs.h"
    rm -rf "$work/xbe"
    echo "$wanted" >"$stamp"
}

build() {
    build_libraries

    local roms=() rom
    for rom in "$FRONTPORT_ROMS"/*; do
        [ -e "$rom" ] && roms+=("$rom")
    done
    if [ ${#roms[@]} -gt 0 ]; then
        echo "==> Unpacking the disc"
        local game=$FRONTPORT_OUT/assets
        (cd "$b3x/xboxrecomp" && PYTHONPATH="$deps/site" "$deps/python/bin/python3" -m tools.xiso unpack \
            "${roms[0]}" -o "$game")
        [ -f "$game/default.xbe" ] || fail "the disc image has no default.xbe"
        lift "$game/default.xbe"
    else
        echo "==> No ROM given: building the app alone"
        [ -f "$gen/recomp_funcs.h" ] || fail "no ROM, and no code lifted by an earlier build: add the disc and install again"
    fi

    echo "==> Configuring b3x"
    local build=$work/build
    rm -rf "$build"
    cmake -S "$b3x" -B "$build" -G Ninja -Wno-dev -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_ARCHITECTURES=arm64 \
        -DCMAKE_OSX_DEPLOYMENT_TARGET=$deployment_target -DCMAKE_PREFIX_PATH="$prefix" -DCMAKE_FIND_FRAMEWORK=LAST \
        -DNFSU2_VULKAN=ON -DNFSU2_GEN_DIR="$gen" \
        -DVulkan_INCLUDE_DIR="$deps/vulkan-headers/include" -DVulkan_LIBRARY="$prefix/lib/libMoltenVK.dylib" \
        -DCMAKE_BUILD_WITH_INSTALL_RPATH=ON -DCMAKE_INSTALL_RPATH=@executable_path/../Frameworks

    echo "==> Building b3x"
    cmake --build "$build" -j "$FRONTPORT_JOBS"

    echo "==> Making Burnout 3.app"
    local app=$FRONTPORT_OUT/"Burnout 3.app" plist version
    plist=$app/Contents/Info.plist
    version=$(cat "$src/version")
    [ -x "$build/b3_recomp" ] || fail "the build made no b3_recomp executable"
    mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$app/Contents/Frameworks"
    cp "$build/b3_recomp" "$app/Contents/MacOS/b3x"
    cp "$prefix/lib/libMoltenVK.dylib" "$app/Contents/Frameworks/"
    make_icon "$b3x/docs/assets/appicon.png" "$app/Contents/Resources/b3x.icns"
    plutil -create xml1 "$plist"
    plutil -insert CFBundleExecutable -string b3x "$plist"
    plutil -insert CFBundleIdentifier -string "dev.frontport.port.$FRONTPORT_PORT" "$plist"
    plutil -insert CFBundleName -string "Burnout 3" "$plist"
    plutil -insert CFBundleDisplayName -string "Burnout 3" "$plist"
    plutil -insert CFBundlePackageType -string APPL "$plist"
    plutil -insert CFBundleInfoDictionaryVersion -string 6.0 "$plist"
    plutil -insert CFBundleShortVersionString -string "$version" "$plist"
    plutil -insert CFBundleVersion -string "$version" "$plist"
    plutil -insert CFBundleIconFile -string b3x "$plist"
    plutil -insert LSMinimumSystemVersion -string "$deployment_target" "$plist"
    plutil -insert LSApplicationCategoryType -string public.app-category.racing-games "$plist"
    plutil -insert NSHighResolutionCapable -bool true "$plist"
    plutil -insert NSPrincipalClass -string NSApplication "$plist"
}

# make_icon <png> <icns>: an icns holding upstream's square PNG as it is, when it's a size an icns takes.
make_icon() {
    "$deps/python/bin/python3" -I - "$1" "$2" <<'EOF'
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
