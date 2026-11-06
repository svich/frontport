#!/bin/bash
# Frontport Recipe: Xash3D FWGS's iOS version (FWGS/xash3d-fwgs), with FWGS/hlsdk-portable's game code, for iPhone and
# iPad. Contract: catalog/recipes/README.md, iOS Recipes. Invoked as `xash3d-ios.sh fetch`, then with `build`.
#
# Upstream publishes no iOS build, only scripts that make an .ipa with Xcode's tools. So this builds what they build,
# from the engine commit the Mac Recipe pins and the same hlsdk-portable commit for the game, into one flat unsigned
# arm64 app Frontport signs for each Device:
# - The top: the engine, xash (a program on iOS, with SDL2 linked in statically), and the libraries it loads from
#   beside itself: the menu, the file system and the GLES renderers (nanogl, the GLES 3 wrapper).
# - <gamedir>/: the game's libraries in dlls/ and cl_dlls/, built with CMake as upstream's buildhlsdk.sh builds them
#   (hlsdk-portable's waf has no iOS target), and xash-extras' extras.pk3 in valve/.
# On iOS the engine already plays from Documents, where Frontport Seeds the Steam game folder and Files shows it, and
# reads the app's own folder as its read-only game folder, where it finds the game's libraries (the Steam folder's
# are for the Mac, and named without the ios_arm64 suffix the engine looks for). One line is patched in, for an add-on
# (gearbox for Opposing Force, bshift for Blue Shift): an iOS app has no launch arguments or environment to give
# `-game`, so main sets XASH3D_GAME, which the engine reads in their place, leaving valve the base game add-ons need.
#
# - Launch: upstream's launch dialog asks for launch options (kept in Documents/settings.bin) before each start, and
#   asks for the microphone, for voice chat, the first time; both are kept as they are.
# - No actool or ibtool: upstream ships no asset catalog or storyboard, only an Info.plist, so this writes one with
#   its keys, the UILaunchScreen key, and loose icons scaled from the engine's 256-pixel icon.
# - UIScene: SDL2's UIKit backend has no scene delegate, so the engine is stamped with the iOS 18 SDK, as in
#   fallout-ce-ios.sh. upstream's waf builds for iOS 12 and later, and so does everything else here.
set -euo pipefail

step=${1:?usage: xash3d-ios.sh fetch|build}
[ "${FRONTPORT_SDK:-}" = iphoneos ] || { echo "error: xash3d-ios.sh builds the iOS version" >&2; exit 1; }
src=$FRONTPORT_SRC
work=$(dirname "$src")                 # Builds/<port>.ios: writable during build, kept between builds
deps=$src/deps
xash=$src/xash3d-fwgs
hlsdk=$src/hlsdk-portable
prefix=$work/prefix                    # SDL2, reused while its pin doesn't change
deployment_target=12.0                 # waf's, fixed in its iOS toolchain (scripts/waifulib/xcompile.py)
stamped_sdk=18.0
export GIT_CEILING_DIRECTORIES=$work

fail() {
    echo "error: $*" >&2
    exit 1
}

# The hlsdk-portable branch and game folder for this Port's game, the commit of that branch this Recipe was tested
# with (the Mac Recipe's), and the name the home screen shows.
case "$FRONTPORT_PORT" in
    xash3d-half-life)
        branch=master gamedir=valve hlsdk_commit=8a09758d2912d278423870391f6c25995de0000b display_name=Half-Life ;;
    xash3d-opposing-force)
        branch=opfor gamedir=gearbox hlsdk_commit=54c48ed81445e21c02504466596d49f83530dc1f display_name="Opposing Force" ;;
    xash3d-blue-shift)
        branch=bshift gamedir=bshift hlsdk_commit=ebc703ef52aef4d4623a2e54348fc0104887143e display_name="Blue Shift" ;;
    *) fail "Port $FRONTPORT_PORT names no game this Recipe builds (xash3d-half-life, xash3d-opposing-force, xash3d-blue-shift)" ;;
esac

# The engine's submodules an iOS build uses: the Mac Recipe's, with nanogl for the GLES 1 renderer.
submodules="
3rdparty/mainui
3rdparty/nanogl
3rdparty/extras/xash-extras
3rdparty/opus/opus
3rdparty/bzip2/bzip2
3rdparty/MultiEmulator
3rdparty/libogg/libogg
3rdparty/vorbis/vorbis-src
3rdparty/opusfile/opusfile
3rdparty/libbacktrace/libbacktrace
3rdparty/library_suffix
3rdparty/mbedtls/mbedtls
3rdparty/mpg123/mpg123
"

# name sha256 url, as in xash3d.sh.
dependencies="
sdl2 5f5993c530f084535c65a6879e9b26ad441169b3e25d789d83287040a9ca5165 https://github.com/libsdl-org/SDL/releases/download/release-2.32.10/SDL2-2.32.10.tar.gz
"

# clone <url> <folder> <commit>: that commit alone, with no history.
clone() {
    local url=$1 folder=$2 commit=$3
    git init --quiet "$folder"
    git -C "$folder" fetch --quiet --depth 1 "$url" "$commit"
    git -C "$folder" -c advice.detachedHead=false checkout --quiet FETCH_HEAD
}

fetch() {
    echo "==> Cloning xash3d-fwgs $FRONTPORT_REF"
    git clone --quiet https://github.com/FWGS/xash3d-fwgs.git "$xash"
    git -C "$xash" -c advice.detachedHead=false checkout --quiet "$FRONTPORT_REF"
    echo "==> Cloning the engine's libraries"
    local module
    # shellcheck disable=SC2086
    git -C "$xash" submodule --quiet update --init --recursive -- $submodules
    for module in $submodules; do
        [ -n "$(ls -A "$xash/$module")" ] || fail "submodule $module is empty"
    done

    echo "==> Cloning hlsdk-portable $branch"
    clone https://github.com/FWGS/hlsdk-portable.git "$hlsdk" "$hlsdk_commit"
    # FreeVGUI, which the client links statically on arm64.
    git -C "$hlsdk" submodule --quiet update --init --recursive --depth 1

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

build_sdl2() {
    local stamp=$prefix/.frontport-libraries
    local wanted
    wanted=$(echo "$dependencies $deployment_target ios nohidapi" | shasum -a 256 | cut -d' ' -f1)
    if [ -f "$stamp" ] && [ "$(cat "$stamp")" = "$wanted" ]; then
        echo "==> Reusing SDL2 in $prefix"
        return
    fi
    rm -rf "$prefix" "$work/sdl2-build"
    echo "==> Building SDL2 for iOS"
    # No HIDAPI: on iOS it only scans Bluetooth for Steam Controllers, which iOS kills the app for without a Bluetooth
    # usage description. Game controllers still come through GameController.framework.
    cmake -S "$deps/sdl2" -B "$work/sdl2-build" -G Ninja -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_SYSROOT="$SDKROOT" -DCMAKE_OSX_ARCHITECTURES=arm64 \
        -DCMAKE_OSX_DEPLOYMENT_TARGET=$deployment_target -DCMAKE_INSTALL_PREFIX="$prefix" \
        -DSDL_SHARED=OFF -DSDL_STATIC=ON -DSDL_TEST=OFF -DSDL_HIDAPI=OFF
    cmake --build "$work/sdl2-build" -j "$FRONTPORT_JOBS"
    cmake --install "$work/sdl2-build"
    # waf takes SDL2 on Apple platforms only as a framework: one whose binary is the static library links it in.
    mkdir -p "$prefix/SDL2.framework"
    cp -R "$prefix/include/SDL2" "$prefix/SDL2.framework/Headers"
    cp "$prefix/lib/libSDL2.a" "$prefix/SDL2.framework/SDL2"
    echo "$wanted" >"$stamp"
}

build() {
    build_sdl2
    # What the static SDL2 itself links against: its system libraries and frameworks, leaving out its own paths,
    # which hold a space (Application Support).
    local sdl_libs
    sdl_libs=$("$prefix/bin/sdl2-config" --static-libs | tr ' ' '\n' | grep -E '^-(l|Wl,)' | grep -v '^-lSDL2$' | tr '\n' ' ')

    echo "==> Building the engine for iOS"
    rm -rf "$work/xash-build" "$work/xash-install"
    (
        cd "$xash"
        git checkout -- engine/common/launcher.c
        if [ "$gamedir" != valve ]; then
            local anchor='	IOS_LaunchDialog();'
            grep -qxF "$anchor" engine/common/launcher.c || fail "launcher.c no longer shows the iOS launch dialog in main"
            sed -i '' "s|^$anchor\$|	setenv( \"XASH3D_GAME\", \"$gamedir\", 0 );\\
$anchor|" engine/common/launcher.c
            grep -qF "setenv( \"XASH3D_GAME\", \"$gamedir\", 0 );" engine/common/launcher.c || fail "couldn't patch launcher.c"
        fi
        LINKFLAGS="$sdl_libs" python3 ./waf configure -o "$work/xash-build" -T release --ios --enable-bundled-deps \
            --sdl2="$prefix/SDL2.framework"
        python3 ./waf build -j "$FRONTPORT_JOBS"
        python3 ./waf install --destdir="$work/xash-install"
    )

    echo "==> Building the $gamedir game libraries for iOS"
    rm -rf "$work/hlsdk-build" "$work/hlsdk-install"
    cmake -S "$hlsdk" -B "$work/hlsdk-build" -G Ninja -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_SYSROOT="$SDKROOT" -DCMAKE_OSX_ARCHITECTURES=arm64 \
        -DCMAKE_OSX_DEPLOYMENT_TARGET=$deployment_target \
        -DCMAKE_INSTALL_PREFIX_INITIALIZED_TO_DEFAULT=0 -DCMAKE_INSTALL_PREFIX="$work/hlsdk-install" \
        -DGAMEDIR="$gamedir"
    cmake --build "$work/hlsdk-build" -j "$FRONTPORT_JOBS"
    cmake --install "$work/hlsdk-build"

    echo "==> Making xash3d.app"
    local app=$FRONTPORT_OUT/xash3d.app lib
    local executable=$app/xash
    mkdir -p "$app/valve"
    cp "$work/xash-install/xash" "$app/"
    for lib in "$work/xash-install"/*.dylib; do
        cp "$lib" "$app/"
    done
    for lib in filesystem_stdio.dylib libmenu.dylib libref_gles1.dylib libref_gles3compat.dylib; do
        [ -f "$app/$lib" ] || fail "the engine build made no $lib"
    done
    cp "$work/xash-install/valve/extras.pk3" "$app/valve/"
    mkdir -p "$app/$gamedir"
    cp -R "$work/hlsdk-install/$gamedir/dlls" "$work/hlsdk-install/$gamedir/cl_dlls" "$app/$gamedir/"
    ls "$app/$gamedir/dlls"/*_ios_arm64.dylib "$app/$gamedir/cl_dlls"/client_ios_arm64.dylib >/dev/null \
        || fail "the hlsdk build made no iOS libraries for $gamedir"
    # waf names each engine library by its path in the build folder; the engine opens them by path, so this only
    # keeps the build's paths out of the app.
    for lib in "$app"/*.dylib; do
        install_name_tool -id "@rpath/$(basename "$lib")" "$lib" 2>/dev/null
    done
    if otool -L "$executable" | grep -q -i sdl; then
        fail "xash links SDL dynamically"
    fi

    echo "==> Stamping the iOS $stamped_sdk SDK"
    vtool -set-build-version ios "$deployment_target" "$stamped_sdk" -replace -output "$executable.stamped" "$executable"
    mv "$executable.stamped" "$executable"
    chmod 755 "$executable"

    echo "==> Making icons"
    make_icons "$xash/game_launch/icon-xash-material.png" "$app"

    # Upstream's Info.plist (engine/platform/ios/bundle), without Xcode's build keys, its storyboard and its document
    # browser, made whole for Frontport. Versions as the Mac Recipe's: 0.21.<the engine commit's date>.
    local plist=$app/Info.plist version
    version=$(git -C "$xash" log -1 --format=%cs | tr -d -)     # such as 20261030
    cat >"$plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key>
	<string>en</string>
	<key>CFBundleDisplayName</key>
	<string>$display_name</string>
	<key>CFBundleExecutable</key>
	<string>xash</string>
	<key>CFBundleIdentifier</key>
	<string>dev.frontport.port.$FRONTPORT_PORT</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleName</key>
	<string>Xash3D FWGS</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>0.21.$version</string>
	<key>CFBundleSupportedPlatforms</key>
	<array>
		<string>iPhoneOS</string>
	</array>
	<key>CFBundleVersion</key>
	<string>$version</string>
	<key>CFBundleIcons</key>
	<dict>
		<key>CFBundlePrimaryIcon</key>
		<dict>
			<key>CFBundleIconFiles</key>
			<array>
				<string>AppIcon60x60</string>
			</array>
		</dict>
	</dict>
	<key>CFBundleIcons~ipad</key>
	<dict>
		<key>CFBundlePrimaryIcon</key>
		<dict>
			<key>CFBundleIconFiles</key>
			<array>
				<string>AppIcon60x60</string>
				<string>AppIcon76x76</string>
				<string>AppIcon83.5x83.5</string>
			</array>
		</dict>
	</dict>
	<key>LSApplicationCategoryType</key>
	<string>public.app-category.games</string>
	<key>LSRequiresIPhoneOS</key>
	<true/>
	<key>LSSupportsGameMode</key>
	<true/>
	<key>LSSupportsOpeningDocumentsInPlace</key>
	<true/>
	<key>MinimumOSVersion</key>
	<string>$deployment_target</string>
	<key>NSMicrophoneUsageDescription</key>
	<string>Microphone permissions are required for voice chat</string>
	<key>UIApplicationSupportsIndirectInputEvents</key>
	<true/>
	<key>UIDeviceFamily</key>
	<array>
		<integer>1</integer>
		<integer>2</integer>
	</array>
	<key>UIFileSharingEnabled</key>
	<true/>
	<key>UILaunchScreen</key>
	<dict/>
	<key>UIRequiredDeviceCapabilities</key>
	<array>
		<string>arm64</string>
	</array>
	<key>UIRequiresFullScreen</key>
	<true/>
	<key>UIStatusBarStyle</key>
	<string>UIStatusBarStyleLightContent</string>
	<key>UISupportedInterfaceOrientations</key>
	<array>
		<string>UIInterfaceOrientationLandscapeLeft</string>
		<string>UIInterfaceOrientationLandscapeRight</string>
	</array>
</dict>
</plist>
EOF
    plutil -lint "$plist"
    vtool -show-build "$executable"
    vtool -show-build "$executable" | grep -q "minos $deployment_target\$" \
        || fail "xash isn't built for iOS $deployment_target, as its Info.plist says"
}

# make_icons <PNG> <app>: the iPhone and iPad home screen icons, as in fallout-ce-ios.sh.
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
