#!/bin/bash
# Frontport Recipe: Fallout Community Edition's iOS version (alexbatalov/fallout1-ce), for iPhone and iPad.
# Contract: catalog/recipes/README.md, iOS Recipes. Invoked as `fallout-ce-ios.sh fetch`, then with `build`.
#
# Upstream publishes an .ipa, but without a digest, so the Catalog builds it here from the commit the Mac Recipe pins,
# with the same SDL2, adecode and fpattern archives, into one flat unsigned arm64 app Frontport signs for each Device.
#
# - Documents: upstream's iOS app already plays from its Documents folder (winmain.cc changes to it), where Frontport
#   Seeds the game's folder and Files shows it, so the Mac Recipe's chdir patch isn't needed. Its two music patches
#   are, as the CD keeps the music in DATA\SOUND\MUSIC\.
# - Case: iOS containers are case-sensitive and the CD's names are upper case. Fallout CE resolves each path it opens,
#   makes, renames, removes or lists one component at a time, ignoring case (compat_resolve_path in platform_compat.cc),
#   and upper-cases names in its DAT and patch-file lookups, so nothing is patched for it. Only a listing's pattern
#   compares file names by case (fpattern), as it does on the Mac.
# - No actool or ibtool: they can't run in the build sandbox, and Ninja copies upstream's asset catalog and storyboard
#   uncompiled. The app gets the UILaunchScreen key instead of the storyboard, and loose icons listed in CFBundleIcons,
#   scaled from upstream's 1024-pixel icon by a small ImageIO tool (sips needs LaunchServices, which the sandbox lacks).
# - UIScene: SDL2's UIKit backend has no scene delegate, and iOS ends an app linked against the iOS 27 SDK that has
#   none as soon as it launches. So the build stamps the executable's LC_BUILD_VERSION with the iOS 18 SDK
#   (vtool -set-build-version), for which iOS still runs an app without one. It's compiled and linked against the SDK
#   Xcode has and runs on iOS 15 and later; the stamp changes only which SDK iOS takes it to be built with.
set -euo pipefail

step=${1:?usage: fallout-ce-ios.sh fetch|build}
[ "${FRONTPORT_SDK:-}" = iphoneos ] || { echo "error: fallout-ce-ios.sh builds the iOS version" >&2; exit 1; }
src=$FRONTPORT_SRC
work=$(dirname "$src")
deps=$src/deps
fallout=$src/fallout1-ce
deployment_target=15.0
stamped_sdk=18.0
export GIT_CEILING_DIRECTORIES=$work

# name sha256 url, as in fallout-ce.sh.
dependencies="
sdl2 5f5993c530f084535c65a6879e9b26ad441169b3e25d789d83287040a9ca5165 https://github.com/libsdl-org/SDL/releases/download/release-2.32.10/SDL2-2.32.10.tar.gz
adecode 9b532446543ae6f39370688c90a4df0951828573f1082f5004f76f76d278c081 https://github.com/alexbatalov/adecode/archive/e4a8b0f3b66826e0b7779a25d79df8497f8f8087.tar.gz
fpattern 20718b12387482ca0f8fdb9da129b8c876dd9cd5086ba4ed1d45e5ef57c06bfc https://github.com/alexbatalov/fpattern/archive/8523173ec252c3b796fcdfca0fcc6329642fbbe3.tar.gz
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
    echo "==> Cloning fallout1-ce $FRONTPORT_REF"
    git clone --quiet https://github.com/alexbatalov/fallout1-ce.git "$fallout"
    git -C "$fallout" -c advice.detachedHead=false checkout --quiet "$FRONTPORT_REF"
    git -C "$fallout" describe --tags --long >"$src/version" || fail "$FRONTPORT_REF follows no tag to take a version from"

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
    # As on the Mac: music_path2 defaults to the CD's DATA\SOUND\MUSIC\, and level music found only there plays where
    # it is, instead of being copied into music_path1, which doesn't exist.
    replace "$fallout/src/game/gconfig.cc" \
        'GAME_CONFIG_MUSIC_PATH2_KEY, "sound\\music\\");' 'GAME_CONFIG_MUSIC_PATH2_KEY, "data\\sound\\music\\");'
    replace "$fallout/src/game/gsound.cc" \
        'rc = gsound_background_find_with_copy(path, fileName);' 'rc = gsound_background_find_dont_copy(path, fileName);'
}

build() {
    echo "==> Configuring fallout1-ce for iOS"
    rm -rf "$work/build"
    cmake -S "$fallout" -B "$work/build" -G Ninja -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_SYSROOT="$SDKROOT" -DCMAKE_OSX_ARCHITECTURES=arm64 \
        -DCMAKE_OSX_DEPLOYMENT_TARGET=$deployment_target \
        -DFETCHCONTENT_FULLY_DISCONNECTED=ON \
        -DFETCHCONTENT_SOURCE_DIR_SDL2="$deps/sdl2" \
        -DFETCHCONTENT_SOURCE_DIR_ADECODE="$deps/adecode" \
        -DFETCHCONTENT_SOURCE_DIR_FPATTERN="$deps/fpattern"

    echo "==> Building fallout1-ce"
    cmake --build "$work/build" -j "$FRONTPORT_JOBS"

    local app="$work/build/fallout-ce.app" executable plist describe version build_number
    [ -d "$app" ] || fail "the build made no app"
    executable=$app/fallout-ce
    find "$app" \( -name '*.xcassets' -o -name '*.storyboard' \) -prune -exec rm -rf {} +

    echo "==> Stamping the iOS $stamped_sdk SDK"
    vtool -set-build-version ios "$deployment_target" "$stamped_sdk" -replace -output "$executable.stamped" "$executable"
    mv "$executable.stamped" "$executable"
    chmod 755 "$executable"

    echo "==> Making icons"
    make_icons "$fallout/os/ios/AppIcon.xcassets/AppIcon.appiconset/AppIcon.png" "$app"

    # Upstream's Info.plist, as CMake filled it in, made whole for iOS without a storyboard. iOS takes at most three
    # integers for each version: the tag's for the short one, and the commits since it for the build number.
    plist=$app/Info.plist
    describe=$(cat "$src/version")                        # v1.1.0-7-g0609bcf: 1.1.0, build 7
    [[ $describe =~ ^v?([0-9]+(\.[0-9]+){0,2})-([0-9]+)-g[0-9a-f]+$ ]] || fail "can't take a version from $describe"
    version=${BASH_REMATCH[1]}
    build_number=${BASH_REMATCH[3]}
    plutil -remove UILaunchStoryboardName "$plist"
    plutil -remove LSMinimumSystemVersion "$plist"
    plutil -replace UILaunchScreen -json '{}' "$plist"
    plutil -replace MinimumOSVersion -string "$deployment_target" "$plist"
    plutil -replace CFBundleSupportedPlatforms -json '["iPhoneOS"]' "$plist"
    plutil -replace UIDeviceFamily -json '[1,2]' "$plist"
    # Documents shows in Files, where the user can see the game's files and saves.
    plutil -replace UIFileSharingEnabled -bool YES "$plist"
    plutil -replace LSSupportsOpeningDocumentsInPlace -bool YES "$plist"
    plutil -replace CFBundleIcons -json '{"CFBundlePrimaryIcon":{"CFBundleIconFiles":["AppIcon60x60"]}}' "$plist"
    plutil -replace 'CFBundleIcons~ipad' \
        -json '{"CFBundlePrimaryIcon":{"CFBundleIconFiles":["AppIcon60x60","AppIcon76x76","AppIcon83.5x83.5"]}}' "$plist"
    plutil -replace CFBundleShortVersionString -string "$version" "$plist"
    plutil -replace CFBundleVersion -string "$build_number" "$plist"
    plutil -lint "$plist"
    vtool -show-build "$executable"

    cp -R "$app" "$FRONTPORT_OUT/"
}

# make_icons <1024-pixel PNG> <app>: the iPhone and iPad home screen icons, named as Xcode names the loose copies it
# makes beside an asset catalog, opaque as iOS wants them.
make_icons() {
    local source=$1 app=$2 tool=$TMPDIR/scale-icon
    cat >"$TMPDIR/scale-icon.c" <<'EOF'
#include <CoreGraphics/CoreGraphics.h>
#include <ImageIO/ImageIO.h>
#include <stdlib.h>
#include <string.h>
int main(int argc, char **argv) {
    if (argc != 4) return 2;
    size_t side = (size_t)atoi(argv[3]);
    CFURLRef in = CFURLCreateFromFileSystemRepresentation(NULL, (const UInt8 *)argv[1], (CFIndex)strlen(argv[1]), false);
    CFURLRef out = CFURLCreateFromFileSystemRepresentation(NULL, (const UInt8 *)argv[2], (CFIndex)strlen(argv[2]), false);
    CGImageSourceRef source = CGImageSourceCreateWithURL(in, NULL);
    CGImageRef image = source ? CGImageSourceCreateImageAtIndex(source, 0, NULL) : NULL;
    if (!image || side == 0) return 1;
    CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef context = CGBitmapContextCreate(NULL, side, side, 8, 0, space, (CGBitmapInfo)kCGImageAlphaNoneSkipLast);
    CGContextSetInterpolationQuality(context, kCGInterpolationHigh);
    CGContextDrawImage(context, CGRectMake(0, 0, side, side), image);
    CGImageRef scaled = CGBitmapContextCreateImage(context);
    CGImageDestinationRef destination = CGImageDestinationCreateWithURL(out, CFSTR("public.png"), 1, NULL);
    CGImageDestinationAddImage(destination, scaled, NULL);
    return CGImageDestinationFinalize(destination) ? 0 : 1;
}
EOF
    # A Mac tool, so it builds with the macOS SDK rather than $SDKROOT's.
    xcrun --sdk macosx clang -O2 -o "$tool" "$TMPDIR/scale-icon.c" -framework CoreGraphics -framework ImageIO \
        -framework CoreFoundation
    local name pixels
    while read -r name pixels; do
        "$tool" "$source" "$app/$name" "$pixels" || fail "couldn't make $name"
    done <<EOF
AppIcon60x60@2x.png 120
AppIcon60x60@3x.png 180
AppIcon76x76@2x~ipad.png 152
AppIcon83.5x83.5@2x~ipad.png 167
EOF
}

case "$step" in
    fetch) fetch ;;
    build) build ;;
    *) fail "unknown step $step" ;;
esac
