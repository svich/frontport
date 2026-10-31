#!/bin/bash
# Frontport Recipe: sm (snesrev/sm), a reimplementation of Super Metroid.
# Contract: catalog/recipes/README.md. Invoked as `sm.sh fetch`, then `sm.sh build`.
#
# Upstream publishes no Release and no app bundle, so this builds the binary against a static SDL2 and wraps
# it in a minimal sm.app.
#
# Build Assets: the US/JP ROM itself, left at $FRONTPORT_OUT/assets for the Catalog's buildAssets.path
# "Contents/Resources/sm.smc". Unlike zelda3 and smw, sm has no asset file yet: its C code reads levels and
# graphics straight from the ROM's bytes. Upstream also runs the ROM's original code on its bundled SNES
# core every frame to compare against its own (RM_BOTH); fetch switches it to its own code only (RM_MINE),
# so no original code runs. Upstream reads the ROM, sm.ini and saves/ from the working directory, so fetch
# adds a small source file that reads the ROM from the bundle's Resources and runs in
# ~/Library/Application Support/sm inside the container.
set -euo pipefail

step=${1:?usage: sm.sh fetch|build}
src=$FRONTPORT_SRC
work=$(dirname "$src")
deps=$src/deps
sm=$src/sm
prefix=$work/prefix
deployment_target=13.0
export MACOSX_DEPLOYMENT_TARGET=$deployment_target
export GIT_CEILING_DIRECTORIES=$work

dependencies="
sdl2 5f5993c530f084535c65a6879e9b26ad441169b3e25d789d83287040a9ca5165 https://github.com/libsdl-org/SDL/releases/download/release-2.32.10/SDL2-2.32.10.tar.gz
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
    echo "==> Cloning sm $FRONTPORT_REF"
    git clone --quiet https://github.com/snesrev/sm.git "$sm"
    git -C "$sm" -c advice.detachedHead=false checkout --quiet "$FRONTPORT_REF"
    git -C "$sm" describe --tags --long >"$src/version" 2>/dev/null || echo "v0-0-g$FRONTPORT_REF" >"$src/version"

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
    replace "$sm/src/sm_cpu_infra.c" 'uint8 g_runmode = RM_BOTH;' 'uint8 g_runmode = RM_MINE;'
    # Upstream starts a soft reset (game_state 0xffff, as when the demos end) only in RunOneFrameOfGame_Both, so
    # RM_MINE indexes past kGameStateFuncs and crashes (snesrev/sm#45). Start it the same way here.
    replace "$sm/src/sm_cpu_infra.c" '    RunOneFrameOfGame();
    DrawFrameToPpu();
    g_snes->runningWhichVersion = 0;' '    RunOneFrameOfGame();
    DrawFrameToPpu();
    g_snes->runningWhichVersion = 0;
    if (game_state == 0xffff)
      coroutine_state_0 = 3;'
    replace "$sm/src/main.c" 'const char* filename = argv[0] ? argv[0] : "sm.smc";' \
        'const char* filename = argv[0] ? argv[0] : FrontportResource("sm.smc");'
    replace "$sm/src/main.c" 'int main(int argc, char** argv) {' \
        'const char *FrontportResource(const char *name);
int main(int argc, char** argv) {'
    cat >"$sm/src/frontport_bundle.c" <<'EOF'
// Added by Frontport's Recipe so sm runs from a sandboxed app bundle.
#include <copyfile.h>
#include <limits.h>
#include <mach-o/dyld.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

static char resources[PATH_MAX];

// A file from the bundle's Resources when it ships there, else the name, relative to the working directory.
const char *FrontportResource(const char *name) {
  static char path[PATH_MAX];
  if (resources[0] && snprintf(path, sizeof(path), "%s/%s", resources, name) < (int)sizeof(path) &&
      access(path, R_OK) == 0)
    return path;
  return name;
}

// Inside an app bundle, runs in ~/Library/Application Support/sm (inside the container under the App
// Sandbox), where sm keeps sm.ini and saves/, starting from the bundled default sm.ini.
__attribute__((constructor)) static void FrontportUseDataFolder(void) {
  char executable[PATH_MAX], real[PATH_MAX], data[PATH_MAX];
  uint32_t size = sizeof(executable);
  if (_NSGetExecutablePath(executable, &size) != 0 || realpath(executable, real) == NULL)
    return;
  char *slash = strrchr(real, '/');
  if (slash == NULL)
    return;
  *slash = 0;
  size_t length = strlen(real);
  const char *macos = "/Contents/MacOS";
  if (length < strlen(macos) || strcmp(real + length - strlen(macos), macos) != 0)
    return;
  real[length - strlen("MacOS")] = 0;
  snprintf(resources, sizeof(resources), "%sResources", real);

  const char *home = getenv("HOME");
  if (home == NULL || snprintf(data, sizeof(data), "%s/Library/Application Support/sm", home) >= (int)sizeof(data))
    return;
  mkdir(data, 0700);
  if (chdir(data) != 0)
    return;
  if (access("sm.ini", F_OK) != 0)
    copyfile(FrontportResource("sm.ini"), "sm.ini", NULL, COPYFILE_DATA);
}
EOF
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

    echo "==> Building sm"
    # The Makefile splices sdl2-config's output into shell commands unquoted, and Builds/ lies under
    # "Application Support", so quote the prefix in what it prints.
    mkdir -p "$work/bin"
    cat >"$work/bin/sdl2-config" <<EOF
#!/bin/sh
"$prefix/bin/sdl2-config" "\$@" | sed "s|$prefix|'$prefix'|g"
EOF
    chmod +x "$work/bin/sdl2-config"
    export PATH=$work/bin:$PATH
    # Upstream adds -Werror only when CFLAGS is unset; a newer compiler's new warnings shouldn't fail the build.
    export CFLAGS="-O2 -fno-strict-aliasing"
    make -C "$sm" -j "$FRONTPORT_JOBS" sm SDLFLAGS="$(sdl2-config --static-libs)"

    echo "==> Making sm.app"
    local app=$FRONTPORT_OUT/sm.app plist describe version build
    plist=$app/Contents/Info.plist
    describe=$(cat "$src/version")                        # v0-0-g578f90b…, as upstream has no tags
    version=$(echo "$describe" | sed -E 's/^v?([0-9.]+)-([0-9]+)-g.*$/\1.\2/')
    build=${describe##*-g}
    mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
    cp "$sm/sm" "$app/Contents/MacOS/sm"
    cp "$sm/sm.ini" "$app/Contents/Resources/sm.ini"
    plutil -create xml1 "$plist"
    plutil -insert CFBundleExecutable -string sm "$plist"
    plutil -insert CFBundleIdentifier -string "dev.frontport.port.$FRONTPORT_PORT" "$plist"
    plutil -insert CFBundleName -string sm "$plist"
    plutil -insert CFBundlePackageType -string APPL "$plist"
    plutil -insert CFBundleInfoDictionaryVersion -string 6.0 "$plist"
    plutil -insert CFBundleShortVersionString -string "$version" "$plist"
    plutil -insert CFBundleVersion -string "$version" "$plist"
    plutil -insert CFBundleGetInfoString -string "$describe ($build)" "$plist"
    plutil -insert LSMinimumSystemVersion -string "$deployment_target" "$plist"
    plutil -insert LSApplicationCategoryType -string public.app-category.games "$plist"
    plutil -insert NSHighResolutionCapable -bool true "$plist"

    copy_rom
}

# The ROM among the Build-Stage ROMs, which sm reads as it is; nothing when there is none.
copy_rom() {
    local rom
    for rom in "$FRONTPORT_ROMS"/*.sfc; do
        [ -e "$rom" ] || continue
        echo "==> Copying $(basename "$rom")"
        cp "$rom" "$FRONTPORT_OUT/assets"
        return
    done
    echo "==> No ROM given: skipping assets"
}

case "$step" in
    fetch) fetch ;;
    build) build ;;
    *) fail "unknown step $step" ;;
esac
