#!/bin/bash
# Frontport Recipe: PvZ-Portable, a reimplementation of Plants vs. Zombies: Game of the Year Edition.
# Contract: catalog/recipes/README.md. Invoked as `pvz-portable.sh fetch`, then `pvz-portable.sh build`.
#
# Upstream's Mac Release is a bare executable with Homebrew's libraries beside it, not an app, so this builds the
# same executable from source with upstream's CMake, against static SDL2, libpng, libjpeg-turbo and libopenmpt
# (with its own MP3 and Vorbis decoders, for the game's MO3 music), and makes the app around it.
# The game's files (main.pak and properties/) come from the player's copy: a Runtime-Stage folder ROM, Seeded into
# Library/Application Support/io.github.wszqkzqk/PvZPortable, where upstream already keeps its settings, saves and
# caches (SDL's pref path, in the container). fetch patches the game to read its files from there too, where
# upstream reads them beside the executable, and to apply, as its strings load, the overrides upstream's
# scripts/make-compat-overrides.py would write into properties/pvz-portable.xml for releases after 1.2.0.1073,
# such as Steam's: without them the Almanac, Crazy Dave's prices and the Restart Level button show wrong text.
set -euo pipefail

step=${1:?usage: pvz-portable.sh fetch|build}
src=$FRONTPORT_SRC
work=$(dirname "$src")                 # Builds/<port>: writable during build, kept between builds
deps=$src/deps
pvz=$src/PvZ-Portable
prefix=$work/prefix                    # the static libraries, reused while their pins don't change
deployment_target=14.0 # std::format with floating point needs 13.3
export MACOSX_DEPLOYMENT_TARGET=$deployment_target
export GIT_CEILING_DIRECTORIES=$work

# The commit each tag the Catalog may pin is known to be.
known_tags="
0.2.6 396f1c7fcf0507dcd1b79dc1ffad139eea2fb6ca
"

dependencies="
sdl2 5f5993c530f084535c65a6879e9b26ad441169b3e25d789d83287040a9ca5165 https://github.com/libsdl-org/SDL/releases/download/release-2.32.10/SDL2-2.32.10.tar.gz
libpng d80dd2a38a37f803cb9b6ac7b14bd6e74ddc3b654780a8380bdf93523fdb4389 https://download.sourceforge.net/libpng/libpng-1.6.59.tar.xz
libjpeg-turbo c27ad72a68da151177929aa969ae773a2da5ac2af9ce946079314fdac8cece7f https://github.com/libjpeg-turbo/libjpeg-turbo/releases/download/3.2.1/libjpeg-turbo-3.2.1.tar.gz
libopenmpt 95073a10d33d0ed4352f41b68edccb9636002d2626f9fd2e00b191fcaabdd876 https://lib.openmpt.org/files/libopenmpt/src/libopenmpt-0.8.10+release.makefile.tar.gz
"

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
    echo "==> Cloning PvZ-Portable $FRONTPORT_REF"
    git clone --quiet https://github.com/wszqkzqk/PvZ-Portable.git "$pvz"
    git -C "$pvz" -c advice.detachedHead=false checkout --quiet "$FRONTPORT_REF"
    local tag commit head
    head=$(git -C "$pvz" rev-parse HEAD)
    while read -r tag commit; do
        [ -n "$tag" ] || continue
        if [ "$FRONTPORT_REF" = "$tag" ] && [ "$head" != "$commit" ]; then
            fail "tag $tag is $head, not the expected $commit"
        fi
    done <<<"$known_tags"
    git -C "$pvz" describe --tags --always >"$src/version"

    replace "$pvz/src/SexyAppFramework/SexyAppBase.cpp" '	char* aBasePath = SDL_GetBasePath();
	if (aBasePath)
	{
		mResourceDir = aBasePath;' '	// Frontport: the game'\''s files are Seeded beside the saves, in the pref path.
	char* aBasePath = SDL_GetPrefPath("io.github.wszqkzqk", "PvZPortable");
	if (aBasePath)
	{
		mResourceDir = aBasePath;'
    replace "$pvz/src/LawnApp.cpp" '	LoadProperties("properties/Layout.xml", false, false);
' '	LoadProperties("properties/Layout.xml", false, false);
	FrontportCompatStrings();
'
    replace "$pvz/src/LawnApp.cpp" 'void LawnApp::LoadingThreadProc()
{' '// Frontport: what scripts/make-compat-overrides.py writes into properties/pvz-portable.xml, applied as the strings
// load, so the Seeded game files stay as they are. It does nothing for 1.2.0.1073, which lacks these strings.
void LawnApp::FrontportCompatStrings()
{
	auto& s = mStringProperties;
	auto aRestart = s.find("RESTART_LEVEL_BUTTON");
	auto aNotYet = s.find("NOT_ENCOUNTERED_YET_DESCRIPTION");
	auto aSell = s.find("CRAZY_DAVE_1700");
	if (aRestart == s.end() || aNotYet == s.end() || aSell == s.end())
		return;
	std::string aPrice = aSell->second;
	size_t aAt = aPrice.find("{SELL_PRICE}");
	if (aAt == std::string::npos)
		return;
	if (aPrice.find("{SELL_PRICE}0") == std::string::npos)
		aPrice.insert(aAt + 12, "0");

	std::map<std::string, std::string> aOverrides;
	aOverrides["RESTART_LEVEL"] = aRestart->second;
	aOverrides["NOT_ENCOUNTERED_YET"] = aNotYet->second;
	aOverrides["CRAZY_DAVE_1700"] = aPrice;
	const std::string aSuffix = "_DESCRIPTION_HEADER";
	int aHeaders = 0;
	for (const auto& [aKey, aHeader] : s)
	{
		if (aKey.size() <= aSuffix.size() || aKey.compare(aKey.size() - aSuffix.size(), aSuffix.size(), aSuffix) != 0)
			continue;
		std::string aDescriptionKey = aKey.substr(0, aKey.size() - 7);
		auto aDescription = s.find(aDescriptionKey);
		if (aDescription == s.end())
			return;
		aHeaders++;
		if (aDescriptionKey == "ZOMBONI_DESCRIPTION")
		{
			std::string aValue = aDescription->second;
			for (size_t i; (i = aValue.find("{SHORTLINE}\n")) != std::string::npos; )
				aValue.erase(i, 12);
			aOverrides[aDescriptionKey] = aValue;
		}
		else
			aOverrides[aDescriptionKey] = aHeader + "\n" + aDescription->second;
	}
	if (aHeaders == 0)
		return;
	for (const auto& [aKey, aValue] : aOverrides)
		SetString(aKey, aValue);
}

void LawnApp::LoadingThreadProc()
{'
    replace "$pvz/src/LawnApp.h" '	void							LoadingThreadProc() override;' '	void							LoadingThreadProc() override;
	void							FrontportCompatStrings();'

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
}

# cmake_static <name> [options…]: builds a fetched dependency into the prefix as a static library.
cmake_static() {
    local name=$1
    shift
    echo "==> Building $name"
    cmake -S "$deps/$name" -B "$work/$name-build" -G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_ARCHITECTURES=arm64 \
        -DCMAKE_OSX_DEPLOYMENT_TARGET=$deployment_target -DCMAKE_INSTALL_PREFIX="$prefix" \
        -DCMAKE_PREFIX_PATH="$prefix" -DCMAKE_FIND_FRAMEWORK=LAST -DBUILD_SHARED_LIBS=OFF "$@"
    cmake --build "$work/$name-build" -j "$FRONTPORT_JOBS"
    cmake --install "$work/$name-build"
}

build_libraries() {
    local stamp=$prefix/.frontport-libraries
    local wanted
    wanted=$(echo "$dependencies $deployment_target" | shasum -a 256 | cut -d' ' -f1)
    if [ -f "$stamp" ] && [ "$(cat "$stamp")" = "$wanted" ]; then
        echo "==> Reusing the libraries in $prefix"
        return
    fi
    rm -rf "$prefix" "$work"/*-build
    cmake_static sdl2 -DSDL_SHARED=OFF -DSDL_STATIC=ON -DSDL_TEST=OFF
    cmake_static libpng -DPNG_SHARED=OFF -DPNG_STATIC=ON -DPNG_FRAMEWORK=OFF -DPNG_TESTS=OFF -DPNG_TOOLS=OFF
    cmake_static libjpeg-turbo -DENABLE_SHARED=OFF -DENABLE_STATIC=ON -DWITH_TURBOJPEG=OFF -DWITH_TOOLS=OFF \
        -DWITH_TESTS=OFF -DCMAKE_INSTALL_LIBDIR=lib

    # libopenmpt's own Makefile, with the MP3 and Vorbis decoders it carries (minimp3, stb_vorbis), so the static
    # library links on its own; only the static library is built.
    echo "==> Building libopenmpt"
    rm -rf "$work/libopenmpt-build"
    cp -R "$deps/libopenmpt" "$work/libopenmpt-build"
    make -C "$work/libopenmpt-build" -j "$FRONTPORT_JOBS" CONFIG=macos MACOSX_VERSION_MIN=$deployment_target \
        DYNLINK=0 SHARED_LIB=0 STATIC_LIB=1 EXAMPLES=0 OPENMPT123=0 TEST=0 SHARED_SONAME=0 \
        NO_ZLIB=1 NO_MPG123=1 NO_OGG=1 NO_VORBIS=1 NO_VORBISFILE=1 NO_PORTAUDIO=1 NO_PORTAUDIOCPP=1 \
        NO_PULSEAUDIO=1 NO_SDL2=1 NO_SNDFILE=1 NO_FLAC=1 bin/libopenmpt.a
    # Its install target can't take a prefix with a space in it (Application Support).
    mkdir -p "$prefix/include/libopenmpt"
    cp "$work/libopenmpt-build/bin/libopenmpt.a" "$prefix/lib/"
    cp "$work/libopenmpt-build/libopenmpt"/libopenmpt*.h "$work/libopenmpt-build/libopenmpt"/libopenmpt*.hpp \
        "$prefix/include/libopenmpt/"
    echo "$wanted" >"$stamp"
}

build() {
    build_libraries

    echo "==> Configuring PvZ-Portable"
    local cmake_build=$work/pvz-build
    rm -rf "$cmake_build"
    cmake -S "$pvz" -B "$cmake_build" -G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_ARCHITECTURES=arm64 \
        -DCMAKE_OSX_DEPLOYMENT_TARGET=$deployment_target -DCMAKE_PREFIX_PATH="$prefix" -DCMAKE_FIND_FRAMEWORK=LAST \
        -DCMAKE_IGNORE_PREFIX_PATH="/opt/homebrew;/usr/local;/opt/local" -DSDL2_DIR="$prefix/lib/cmake/SDL2"
    echo "==> Building PvZ-Portable"
    cmake --build "$cmake_build" -j "$FRONTPORT_JOBS"

    local app="$FRONTPORT_OUT/PvZ Portable.app" plist version
    plist=$app/Contents/Info.plist
    version=$(cat "$src/version")
    echo "==> Making PvZ Portable.app"
    mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
    cp "$cmake_build/pvz-portable" "$app/Contents/MacOS/pvz-portable"
    make_icon "$pvz/icon.png" "$app/Contents/Resources/PvZPortable.icns"
    plutil -create xml1 "$plist"
    plutil -insert CFBundleExecutable -string pvz-portable "$plist"
    plutil -insert CFBundleIdentifier -string "dev.frontport.port.$FRONTPORT_PORT" "$plist"
    plutil -insert CFBundleName -string "PvZ Portable" "$plist"
    plutil -insert CFBundlePackageType -string APPL "$plist"
    plutil -insert CFBundleInfoDictionaryVersion -string 6.0 "$plist"
    plutil -insert CFBundleShortVersionString -string "${version%%-*}" "$plist"
    plutil -insert CFBundleVersion -string "${version%%-*}" "$plist"
    plutil -insert CFBundleIconFile -string PvZPortable "$plist"
    plutil -insert LSMinimumSystemVersion -string "$deployment_target" "$plist"
    plutil -insert LSApplicationCategoryType -string public.app-category.strategy-games "$plist"
    plutil -insert NSHighResolutionCapable -bool true "$plist"
    plutil -insert NSPrincipalClass -string NSApplication "$plist"
}

# make_icon <png> <icns>: an icns holding upstream's 512×512 PNG as it is.
make_icon() {
    python3 - "$1" "$2" <<'EOF'
import struct, sys
png = open(sys.argv[1], "rb").read()
assert png[:8] == b"\x89PNG\r\n\x1a\n" and struct.unpack(">II", png[16:24]) == (512, 512), "unusable icon"
entries = b"".join(kind + struct.pack(">I", len(png) + 8) + png for kind in (b"ic09", b"ic14"))
open(sys.argv[2], "wb").write(b"icns" + struct.pack(">I", len(entries) + 8) + entries)
EOF
}

case "$step" in
    fetch) fetch ;;
    build) build ;;
    *) fail "unknown step $step" ;;
esac
