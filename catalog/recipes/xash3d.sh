#!/bin/bash
# Frontport Recipe: Xash3D FWGS (FWGS/xash3d-fwgs), a GoldSrc-compatible engine, with FWGS/hlsdk-portable's game code.
# Contract: catalog/recipes/README.md. Invoked as `xash3d.sh fetch`, then `xash3d.sh build`.
#
# One Recipe for one Port per game: the Port id names the game (xash3d-half-life, xash3d-opposing-force,
# xash3d-blue-shift), and each build makes an app with the engine and that game's client and server libraries,
# built from the hlsdk-portable branch for it (master, opfor, bshift).
#
# Upstream publishes only rolling builds, as a bare folder of binaries with SDL2.framework beside them. So this
# builds the engine against a static SDL2 and wraps it in Xash3D FWGS.app:
# - Contents/MacOS: the launcher, xash3d, and the engine's libraries, which it loads from beside itself.
# - Contents/Resources: the read-only game folder (-rodir), with the game's libraries in <gamedir>/dlls and
#   <gamedir>/cl_dlls, and xash-extras' extras.pk3 in valve/.
# Inside an app, the engine already plays from ~/Library/Application Support/Xash3D FWGS, which the App Sandbox
# puts in the container, where Frontport Seeds the game folders and the engine writes configs and saves. A patch
# makes the app's Resources its default read-only folder, as on iOS, so the game folders Seeded from Steam (whose
# libraries are x86-64 and named without the arm64 suffix the engine looks for) get their code from the app.
set -euo pipefail

step=${1:?usage: xash3d.sh fetch|build}
src=$FRONTPORT_SRC
work=$(dirname "$src")                 # Builds/<port>: writable during build, kept between builds
deps=$src/deps
xash=$src/xash3d-fwgs
hlsdk=$src/hlsdk-portable
prefix=$work/prefix                    # SDL2, reused while its pin doesn't change
deployment_target=13.0
export MACOSX_DEPLOYMENT_TARGET=$deployment_target
export GIT_CEILING_DIRECTORIES=$work

fail() {
    echo "error: $*" >&2
    exit 1
}

# The hlsdk-portable branch and game folder for this Port's game, and the commit of that branch this Recipe was
# tested with.
case "$FRONTPORT_PORT" in
    xash3d-half-life) branch=master gamedir=valve hlsdk_commit=8a09758d2912d278423870391f6c25995de0000b ;;
    xash3d-opposing-force) branch=opfor gamedir=gearbox hlsdk_commit=54c48ed81445e21c02504466596d49f83530dc1f ;;
    xash3d-blue-shift) branch=bshift gamedir=bshift hlsdk_commit=ebc703ef52aef4d4623a2e54348fc0104887143e ;;
    *) fail "Port $FRONTPORT_PORT names no game this Recipe builds (xash3d-half-life, xash3d-opposing-force, xash3d-blue-shift)" ;;
esac

# The engine's submodules a macOS arm64 build with the OpenGL and software renderers uses; the GLES wrappers,
# the TUI menu and the 32-bit-only VGUI are left out.
submodules="
3rdparty/mainui
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

dependencies="
sdl2 5f5993c530f084535c65a6879e9b26ad441169b3e25d789d83287040a9ca5165 https://github.com/libsdl-org/SDL/releases/download/release-2.32.10/SDL2-2.32.10.tar.gz
"

# Replaces exactly the text given in a file, failing loudly when upstream changed it.
replace() {
    local file=$1 old=$2 new=$3
    grep -qF -- "$old" "$file" || fail "$file no longer contains: $old"
    OLD=$old NEW=$new perl -0pi -e 's/\Q$ENV{OLD}\E/$ENV{NEW}/g' "$file"
}

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

    echo "==> Patching"
    # The app's Resources as the default read-only game folder, as iOS uses its app folder.
    replace "$xash/engine/common/filesystem_engine.c" '#if XASH_IOS
	Q_strncpy( out, IOS_GetExecDir(), size );
	return true;
#endif

	return false;' '#if XASH_IOS
	Q_strncpy( out, IOS_GetExecDir(), size );
	return true;
#elif XASH_APPLE && XASH_SDL == 2
	{
		char *path = SDL_GetBasePath();

		if( path != NULL && Q_stristr( path, ".app/" ))
		{
			Q_strncpy( out, path, size );
			SDL_free( path );
			return true;
		}

		SDL_free( path );
	}
#endif

	return false;'
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
    # waf takes SDL2 on macOS only as a framework: one whose binary is the static library links it in.
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

    echo "==> Building the engine"
    rm -rf "$work/xash-build" "$work/xash-install"
    (
        cd "$xash"
        LINKFLAGS="$sdl_libs" python3 ./waf configure -o "$work/xash-build" -T release --enable-bundled-deps \
            --sdl2="$prefix/SDL2.framework"
        python3 ./waf build -j "$FRONTPORT_JOBS"
        python3 ./waf install --destdir="$work/xash-install"
    )

    echo "==> Building the $gamedir game libraries"
    rm -rf "$work/hlsdk-build" "$work/hlsdk-install"
    (
        cd "$hlsdk"
        python3 ./waf configure -o "$work/hlsdk-build" -T release
        python3 ./waf build -j "$FRONTPORT_JOBS"
        python3 ./waf install --destdir="$work/hlsdk-install"
    )

    echo "==> Making Xash3D FWGS.app"
    local app=$FRONTPORT_OUT/Xash3D\ FWGS.app lib
    local macos=$app/Contents/MacOS resources=$app/Contents/Resources
    mkdir -p "$macos" "$resources/valve"
    cp "$work/xash-install/xash3d" "$macos/"
    for lib in "$work/xash-install"/*.dylib; do
        cp "$lib" "$macos/"
    done
    for lib in libxash.dylib filesystem_stdio.dylib libmenu.dylib libref_gl.dylib; do
        [ -f "$macos/$lib" ] || fail "the engine build made no $lib"
    done
    if otool -L "$macos/libxash.dylib" | grep -q -i sdl; then
        fail "libxash links SDL dynamically"
    fi
    cp "$work/xash-install/valve/extras.pk3" "$resources/valve/"
    mkdir -p "$resources/$gamedir"
    cp -R "$work/hlsdk-install/$gamedir/dlls" "$work/hlsdk-install/$gamedir/cl_dlls" "$resources/$gamedir/"
    ls "$resources/$gamedir/dlls"/*_arm64.dylib "$resources/$gamedir/cl_dlls"/client_arm64.dylib >/dev/null \
        || fail "the hlsdk build made no arm64 libraries for $gamedir"
    make_icns "$xash/game_launch/icon-xash-material.png" "$resources/Xash3D.icns"

    local version
    version=$(git -C "$xash" log -1 --format=%cs | tr -d -)     # the engine commit's date, such as 20261030
    cat >"$app/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key>
	<string>en</string>
	<key>CFBundleExecutable</key>
	<string>xash3d</string>
	<key>CFBundleIconFile</key>
	<string>Xash3D</string>
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
	<key>CFBundleVersion</key>
	<string>$version</string>
	<key>LSApplicationCategoryType</key>
	<string>public.app-category.games</string>
	<key>LSMinimumSystemVersion</key>
	<string>$deployment_target</string>
	<key>NSHighResolutionCapable</key>
	<true/>
</dict>
</plist>
EOF
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

case "$step" in
    fetch) fetch ;;
    build) build ;;
    *) fail "unknown step $step" ;;
esac
