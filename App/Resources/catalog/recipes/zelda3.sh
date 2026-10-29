#!/bin/bash
# Frontport Recipe: zelda3 (snesrev/zelda3), a reimplementation of A Link to the Past.
# Contract: catalog/recipes/README.md. Invoked as `zelda3.sh fetch`, then `zelda3.sh build`.
#
# Upstream publishes no macOS Release and no app bundle, so this builds the binary against a static SDL2
# and wraps it in a minimal zelda3.app.
#
# Build Assets: zelda3_assets.dat, made by upstream's assets/restool.py (Python 3 with Pillow and PyYAML,
# both built here from pinned sources) from the US Build-Stage ROM, left at $FRONTPORT_OUT/assets for the
# Catalog's buildAssets.path "Contents/Resources/zelda3_assets.dat". Upstream reads it, zelda3.ini and
# saves/ from the working directory, so fetch adds a small source file that reads the assets from the
# bundle's Resources and runs in ~/Library/Application Support/zelda3 inside the container.
set -euo pipefail

step=${1:?usage: zelda3.sh fetch|build}
src=$FRONTPORT_SRC
work=$(dirname "$src")
deps=$src/deps
zelda3=$src/zelda3
prefix=$work/prefix
deployment_target=13.0
export MACOSX_DEPLOYMENT_TARGET=$deployment_target
export GIT_CEILING_DIRECTORIES=$work

dependencies="
sdl2 5f5993c530f084535c65a6879e9b26ad441169b3e25d789d83287040a9ca5165 https://github.com/libsdl-org/SDL/releases/download/release-2.32.10/SDL2-2.32.10.tar.gz
pillow 3828ee7586cd0b2091b6209e5ad53e20d0649bbe87164a459d0676e035e8f523 https://files.pythonhosted.org/packages/f3/0d/d0d6dea55cd152ce3d6767bb38a8fc10e33796ba4ba210cbab9354b6d238/pillow-11.3.0.tar.gz
pyyaml d76623373421df22fb4cf8817020cbb7ef15c725b9d5e45f17e189bfc384190f https://files.pythonhosted.org/packages/05/8e/961c0007c59b8dd7729d542c61a4d537767a59645b82a0b521206e1e25c2/pyyaml-6.0.3.tar.gz
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
    echo "==> Cloning zelda3 $FRONTPORT_REF"
    git clone --quiet https://github.com/snesrev/zelda3.git "$zelda3"
    git -C "$zelda3" -c advice.detachedHead=false checkout --quiet "$FRONTPORT_REF"
    git -C "$zelda3" describe --tags --long >"$src/version" 2>/dev/null || echo "v0-0-g$FRONTPORT_REF" >"$src/version"

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
    replace "$zelda3/src/main.c" 'ReadWholeFile("zelda3_assets.dat", &length)' \
        'ReadWholeFile(FrontportResource("zelda3_assets.dat"), &length)'
    replace "$zelda3/src/main.c" 'static void LoadAssets() {' \
        'const char *FrontportResource(const char *name);
static void LoadAssets() {'
    cat >"$zelda3/src/frontport_bundle.c" <<'EOF'
// Added by Frontport's Recipe so zelda3 runs from a sandboxed app bundle.
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

// Inside an app bundle, runs in ~/Library/Application Support/zelda3 (inside the container under the App
// Sandbox), where zelda3 keeps zelda3.ini and saves/, starting from the bundled default zelda3.ini.
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
  if (home == NULL || snprintf(data, sizeof(data), "%s/Library/Application Support/zelda3", home) >= (int)sizeof(data))
    return;
  mkdir(data, 0700);
  if (chdir(data) != 0)
    return;
  if (access("zelda3.ini", F_OK) != 0)
    copyfile(FrontportResource("zelda3.ini"), "zelda3.ini", NULL, COPYFILE_DATA);
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

    echo "==> Building zelda3"
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
    export CFLAGS="-O2"
    make -C "$zelda3" -j "$FRONTPORT_JOBS" zelda3 SDLFLAGS="$(sdl2-config --static-libs)"

    echo "==> Making zelda3.app"
    local app=$FRONTPORT_OUT/zelda3.app plist describe version build
    plist=$app/Contents/Info.plist
    describe=$(cat "$src/version")                        # v0.3-27-g45a149d
    version=$(echo "$describe" | sed -E 's/^v?([0-9.]+)-([0-9]+)-g.*$/\1.\2/')
    build=${describe##*-g}
    mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
    cp "$zelda3/zelda3" "$app/Contents/MacOS/zelda3"
    cp "$zelda3/zelda3.ini" "$app/Contents/Resources/zelda3.ini"
    plutil -create xml1 "$plist"
    plutil -insert CFBundleExecutable -string zelda3 "$plist"
    plutil -insert CFBundleIdentifier -string "dev.frontport.port.$FRONTPORT_PORT" "$plist"
    plutil -insert CFBundleName -string zelda3 "$plist"
    plutil -insert CFBundlePackageType -string APPL "$plist"
    plutil -insert CFBundleInfoDictionaryVersion -string 6.0 "$plist"
    plutil -insert CFBundleShortVersionString -string "$version" "$plist"
    plutil -insert CFBundleVersion -string "$version" "$plist"
    plutil -insert CFBundleGetInfoString -string "$describe ($build)" "$plist"
    plutil -insert LSMinimumSystemVersion -string "$deployment_target" "$plist"
    plutil -insert LSApplicationCategoryType -string public.app-category.games "$plist"
    plutil -insert NSHighResolutionCapable -bool true "$plist"

    extract_assets
}

# zelda3_assets.dat from the US ROM among the Build-Stage ROMs; nothing when there is none.
extract_assets() {
    local rom
    for rom in "$FRONTPORT_ROMS"/*.sfc; do
        [ -e "$rom" ] || continue
        echo "==> Building Pillow"
        # The developer tools' setuptools predates Pillow's pyproject layout, so name the output folder.
        (cd "$deps/pillow" && python3 setup.py --quiet build_ext --build-lib "$deps/pillow/src" --disable-jpeg)
        export PYTHONPATH="$deps/pillow/src:$deps/pyyaml/lib"
        export PYTHONDONTWRITEBYTECODE=1
        echo "==> Extracting assets from $(basename "$rom")"
        rm -f "$zelda3/zelda3_assets.dat"
        python3 "$zelda3/assets/restool.py" --extract-from-rom -r "$rom"
        [ -f "$zelda3/zelda3_assets.dat" ] || fail "restool.py made no zelda3_assets.dat"
        mv "$zelda3/zelda3_assets.dat" "$FRONTPORT_OUT/assets"
        return
    done
    echo "==> No ROM given: skipping assets"
}

case "$step" in
    fetch) fetch ;;
    build) build ;;
    *) fail "unknown step $step" ;;
esac
