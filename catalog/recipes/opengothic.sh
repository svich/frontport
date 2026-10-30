#!/bin/bash
# Frontport Recipe: OpenGothic (Try/OpenGothic), a re-implementation of the Gothic II engine.
# Contract: catalog/recipes/README.md. Invoked as `opengothic.sh fetch`, then `opengothic.sh build`.
#
# Upstream's macOS Release is a bare Gothic2Notr executable, no app, so this builds it and wraps it in
# OpenGothic.app. No Build Assets, and nothing patched to run sandboxed: started without -g, OpenGothic plays the
# game in ~/Library/Application Support/OpenGothic when that folder exists, and makes it the working directory,
# where it writes Gothic.ini and its saves. The App Sandbox puts that folder in the container, where Frontport
# Seeds the game's folder. Its shaders are GLSL compiled to SPIR-V at build time by glslangValidator, which upstream
# takes from Homebrew; build makes it from a pinned glslang. Tempest, its engine, turns SPIR-V into Metal shaders
# at run time, so the build needs no Metal compiler.
set -euo pipefail

step=${1:?usage: opengothic.sh fetch|build}
src=$FRONTPORT_SRC
work=$(dirname "$src")                 # Builds/<port>: writable during build, kept between builds
deps=$src/deps
opengothic=$src/OpenGothic
prefix=$work/prefix                    # glslangValidator, reused while its pin doesn't change
deployment_target=13.0
export MACOSX_DEPLOYMENT_TARGET=$deployment_target
export GIT_CEILING_DIRECTORIES=$work

# Commits of the tags this Recipe was tested against, so a moved tag fails the fetch.
known_commit() {
    case "$1" in
        v0.92) echo 2855fa51957bac9e7ce83f938ec127a0ab3badce ;;
    esac
}

dependencies="
glslang 9c09b901149c729df745057dafa815278aaa101b84d2b6e14f16a42de52f97f2 https://github.com/KhronosGroup/glslang/archive/refs/tags/16.6.0.tar.gz
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
    echo "==> Cloning OpenGothic $FRONTPORT_REF"
    git -c advice.detachedHead=false clone --quiet --depth 1 --branch "$FRONTPORT_REF" \
        --recurse-submodules --shallow-submodules https://github.com/Try/OpenGothic.git "$opengothic"
    local expected actual
    expected=$(known_commit "$FRONTPORT_REF")
    actual=$(git -C "$opengothic" rev-parse HEAD)
    if [ -n "$expected" ] && [ "$actual" != "$expected" ]; then
        fail "$FRONTPORT_REF is $actual upstream, but this Recipe was tested with $expected"
    fi
    echo "$FRONTPORT_REF" >"$src/version"

    echo "==> Patching"
    # The shaders' include folder is passed as -I"<folder>", whose quotes CMake keeps as written, so the shell
    # reads a backslash into any space in it, and every Frontport build folder has one (Application Support).
    replace "$opengothic/shader/CMakeLists.txt" \
        'COMMAND    ${GLSLANGVALIDATOR} -V ${VARS} -I"${CMAKE_SOURCE_DIR}/shader" "${SOURCE_FILE}" -o ${OUTPUT_FILE}
    )' \
        'COMMAND    ${GLSLANGVALIDATOR} -V ${VARS} "-I${CMAKE_SOURCE_DIR}/shader" "${SOURCE_FILE}" -o "${OUTPUT_FILE}"
    VERBATIM
    )'
    # Builds a std::string from a null pointer, which current clang rejects under upstream's -Werror.
    replace "$opengothic/game/game/compatibility/cpu32.cpp" 'std::string Cpu32::popString() {
  if(stack.size()==0)
    return 0;' 'std::string Cpu32::popString() {
  if(stack.size()==0)
    return std::string();'

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

build_glslang() {
    local stamp=$prefix/.frontport-libraries
    local wanted
    wanted=$(echo "$dependencies" | shasum -a 256 | cut -d' ' -f1)
    if [ -f "$stamp" ] && [ "$(cat "$stamp")" = "$wanted" ]; then
        echo "==> Reusing glslangValidator in $prefix"
        return
    fi
    rm -rf "$prefix" "$work/glslang-build"
    echo "==> Building glslangValidator"
    # A host tool only; spirv-opt isn't needed, so SPIRV-Tools stays out.
    cmake -S "$deps/glslang" -B "$work/glslang-build" -G Ninja -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_INSTALL_PREFIX="$prefix" \
        -DENABLE_OPT=OFF -DGLSLANG_TESTS=OFF -DBUILD_TESTING=OFF -DENABLE_GLSLANG_BINARIES=ON -DBUILD_SHARED_LIBS=OFF
    cmake --build "$work/glslang-build" -j "$FRONTPORT_JOBS" --target glslang-standalone
    mkdir -p "$prefix/bin"
    cp "$work/glslang-build/StandAlone/glslang" "$prefix/bin/glslangValidator"
    rm -rf "$work/glslang-build"
    echo "$wanted" >"$stamp"
}

build() {
    build_glslang

    local version
    version=$(cat "$src/version")      # v0.92
    version=${version#v}
    printf '#pragma once\n\nstatic const char* appBuild = "OpenGothic v%s";\n' "$version" >"$opengothic/game/build.h"

    echo "==> Configuring OpenGothic"
    rm -rf "$work/build"
    cmake -S "$opengothic" -B "$work/build" -G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_ARCHITECTURES=arm64 \
        -DCMAKE_OSX_DEPLOYMENT_TARGET=$deployment_target -DGLSLANGVALIDATOR="$prefix/bin/glslangValidator"

    echo "==> Building OpenGothic"
    cmake --build "$work/build" -j "$FRONTPORT_JOBS" --target Gothic2Notr

    echo "==> Making OpenGothic.app"
    local executable=$work/build/opengothic/Gothic2Notr
    local app=$FRONTPORT_OUT/OpenGothic.app plist
    [ -x "$executable" ] || fail "the build made no Gothic2Notr executable"
    mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
    cp "$executable" "$app/Contents/MacOS/Gothic2Notr"
    plist=$app/Contents/Info.plist
    plutil -create xml1 "$plist"
    plutil -insert CFBundleExecutable -string Gothic2Notr "$plist"
    plutil -insert CFBundleIdentifier -string "dev.frontport.port.$FRONTPORT_PORT" "$plist"
    plutil -insert CFBundleName -string OpenGothic "$plist"
    plutil -insert CFBundleDisplayName -string OpenGothic "$plist"
    plutil -insert CFBundlePackageType -string APPL "$plist"
    plutil -insert CFBundleInfoDictionaryVersion -string 6.0 "$plist"
    plutil -insert CFBundleShortVersionString -string "$version" "$plist"
    plutil -insert CFBundleVersion -string "$version" "$plist"
    plutil -insert CFBundleIconFile -string OpenGothic "$plist"
    plutil -insert LSMinimumSystemVersion -string "$deployment_target" "$plist"
    plutil -insert LSApplicationCategoryType -string public.app-category.role-playing-games "$plist"
    plutil -insert NSHighResolutionCapable -bool true "$plist"
    plutil -insert NSPrincipalClass -string NSApplication "$plist"
    make_icon "$opengothic/icon.ico" "$app/Contents/Resources/OpenGothic.icns"
}

# make_icon <ico holding a PNG> <icns>: upstream's only icon is a 246×256 PNG inside icon.ico. An icns wants a square
# one, so a small ImageIO tool centres it on a transparent 256×256 canvas (sips needs LaunchServices, which the
# build sandbox doesn't offer).
make_icon() {
    local ico=$1 icns=$2 png=$TMPDIR/icon.png square=$TMPDIR/icon-256.png tool=$TMPDIR/square-icon
    python3 - "$ico" "$png" <<'EOF'
import struct, sys
ico = open(sys.argv[1], "rb").read()
count = struct.unpack("<H", ico[4:6])[0]
entries = [struct.unpack("<BBBBHHII", ico[6 + 16 * i:22 + 16 * i]) for i in range(count)]
size, offset = max((e[6], e[7]) for e in entries)
png = ico[offset:offset + size]
assert png[:8] == b"\x89PNG\r\n\x1a\n", "icon.ico holds no PNG"
open(sys.argv[2], "wb").write(png)
EOF
    cat >"$TMPDIR/square-icon.c" <<'EOF'
#include <CoreGraphics/CoreGraphics.h>
#include <ImageIO/ImageIO.h>
int main(int argc, char **argv) {
    CFURLRef in = CFURLCreateFromFileSystemRepresentation(NULL, (const UInt8 *)argv[1], (CFIndex)strlen(argv[1]), false);
    CFURLRef out = CFURLCreateFromFileSystemRepresentation(NULL, (const UInt8 *)argv[2], (CFIndex)strlen(argv[2]), false);
    CGImageSourceRef source = CGImageSourceCreateWithURL(in, NULL);
    CGImageRef image = source ? CGImageSourceCreateImageAtIndex(source, 0, NULL) : NULL;
    if (!image) return 1;
    size_t w = CGImageGetWidth(image), h = CGImageGetHeight(image), side = w > h ? w : h;
    CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef context = CGBitmapContextCreate(NULL, side, side, 8, 0, space, (CGBitmapInfo)kCGImageAlphaPremultipliedLast);
    CGContextDrawImage(context, CGRectMake((side - w) / 2.0, (side - h) / 2.0, w, h), image);
    CGImageRef squared = CGBitmapContextCreateImage(context);
    CGImageDestinationRef destination = CGImageDestinationCreateWithURL(out, CFSTR("public.png"), 1, NULL);
    CGImageDestinationAddImage(destination, squared, NULL);
    return CGImageDestinationFinalize(destination) ? 0 : 1;
}
EOF
    clang -O2 -o "$tool" "$TMPDIR/square-icon.c" -framework CoreGraphics -framework ImageIO -framework CoreFoundation
    "$tool" "$png" "$square" || fail "couldn't square the icon"
    python3 - "$square" "$icns" <<'EOF'
import struct, sys
png = open(sys.argv[1], "rb").read()
width, height = struct.unpack(">II", png[16:24])
types = {128: [b"ic07"], 256: [b"ic08", b"ic13"], 512: [b"ic09", b"ic14"], 1024: [b"ic10"]}
assert png[:8] == b"\x89PNG\r\n\x1a\n" and width == height and width in types, f"unusable icon {width}x{height}"
entries = b"".join(kind + struct.pack(">I", len(png) + 8) + png for kind in types[width])
open(sys.argv[2], "wb").write(b"icns" + struct.pack(">I", len(entries) + 8) + entries)
EOF
}

case "$step" in
    fetch) fetch ;;
    build) build ;;
    *) fail "unknown step $step" ;;
esac
