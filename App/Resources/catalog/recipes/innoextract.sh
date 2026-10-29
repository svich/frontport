#!/bin/bash
# Frontport unpack Recipe: innoextract (dscharrer/innoextract), for installers made with Inno Setup, such as GOG's.
# Contract: catalog/recipes/README.md, "Unpacking". Invoked as `innoextract.sh fetch`, then `innoextract.sh build`.
#
# Builds innoextract against static Boost and liblzma, kept in Builds/<workspace>/prefix while their pins don't change,
# then unpacks the installer among the ROMs into $FRONTPORT_OUT, with `{app}` as $FRONTPORT_OUT itself. A GOG
# installer's own script then copies its support files into the game's folders (`supportData` actions, which never
# replace a file), and innoextract alone doesn't run it, so this does the same: the folders come out as the installer
# leaves them. Frontport takes each folder in $FRONTPORT_OUT whose hash the Catalog lists.
set -euo pipefail

step=${1:?usage: innoextract.sh fetch|build}
src=$FRONTPORT_SRC
work=$(dirname "$src")                 # Builds/<workspace>: writable during build, kept between runs
deps=$src/deps
prefix=$work/prefix                    # xz, Boost and innoextract, reused while their pins don't change
deployment_target=13.0
export MACOSX_DEPLOYMENT_TARGET=$deployment_target

# name sha256 url. innoextract's last Release, 1.9, predates fixes for current Boost, CMake 4 and GOG Galaxy installers,
# so this pins a later commit. Boost 1.88 is the last with the Boost.System library innoextract asks for.
dependencies="
innoextract 4d885b27e452dcb137a9d97736b19478447f172bcfed1aa98d80138e9a4c08ae https://github.com/dscharrer/innoextract/archive/6e9e34ed0876014fdb46e684103ef8c3605e382e.tar.gz
boost f48b48390380cfb94a629872346e3a81370dc498896f16019ade727ab72eb1ec https://github.com/boostorg/boost/releases/download/boost-1.88.0/boost-1.88.0-cmake.tar.xz
xz 0014c7886930454fe8bd4228665b51af55eeae560ea135c9c4cd33f55b2591d9 https://github.com/tukaani-project/xz/releases/download/v5.8.4/xz-5.8.4.tar.gz
"

fail() {
    echo "error: $*" >&2
    exit 1
}

fetch() {
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

cmake_project() {
    local name=$1 source=$2
    shift 2
    echo "==> Building $name"
    cmake -S "$source" -B "$work/build-$name" -G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_ARCHITECTURES=arm64 \
        -DCMAKE_OSX_DEPLOYMENT_TARGET=$deployment_target -DCMAKE_INSTALL_PREFIX="$prefix" -DCMAKE_PREFIX_PATH="$prefix" \
        -DCMAKE_FIND_FRAMEWORK=NEVER -DBUILD_SHARED_LIBS=OFF "$@"
    cmake --build "$work/build-$name" -j "$FRONTPORT_JOBS"
    cmake --install "$work/build-$name"
}

build_tools() {
    local stamp=$prefix/.frontport-tools
    local wanted
    wanted=$(echo "$dependencies $deployment_target" | shasum -a 256 | cut -d' ' -f1)
    if [ -f "$stamp" ] && [ "$(cat "$stamp")" = "$wanted" ] && [ -x "$prefix/bin/innoextract" ]; then
        echo "==> Reusing innoextract in $prefix"
        return
    fi
    rm -rf "$prefix" "$work"/build-*
    cmake_project xz "$deps/xz" -DXZ_NLS=OFF -DXZ_TOOL_XZ=OFF -DXZ_TOOL_XZDEC=OFF -DXZ_TOOL_LZMADEC=OFF \
        -DXZ_TOOL_LZMAINFO=OFF -DXZ_TOOL_SCRIPTS=OFF -DXZ_DOC=OFF
    # The libraries innoextract links and every header-only one it includes; Boost installs only these and their
    # dependencies.
    local boost_libraries="iostreams;filesystem;date_time;system;program_options;algorithm;config;container;core"
    boost_libraries+=";foreach;format;integer;lexical_cast;ptr_container;range;smart_ptr;static_assert;typeof;unordered;utility"
    cmake_project boost "$deps/boost" -DBOOST_INCLUDE_LIBRARIES="$boost_libraries" \
        -DBOOST_IOSTREAMS_ENABLE_ZSTD=OFF -DBOOST_IOSTREAMS_ENABLE_LZMA=OFF -DBOOST_IOSTREAMS_ENABLE_ZLIB=ON \
        -DBOOST_IOSTREAMS_ENABLE_BZIP2=ON
    # zlib, bzip2 and iconv come from the macOS SDK.
    cmake_project innoextract "$deps/innoextract" -DBoost_USE_STATIC_LIBS=ON -DLZMA_USE_STATIC_LIBS=ON \
        -DUSE_STATIC_LIBS=OFF -DSET_WARNING_FLAGS=OFF
    [ -x "$prefix/bin/innoextract" ] || fail "the build made no innoextract"
    echo "$wanted" >"$stamp"
}

# Runs what a GOG installer's `goggame-<id>.script` asks after install: each `supportData` action copies a folder from
# `__support` into `{app}`, replacing nothing. (macOS's `cp -n` fails whenever it skips a file, so Python copies.)
apply_gog_support() {
    local script
    for script in "$FRONTPORT_OUT"/goggame-*.script; do
        [ -f "$script" ] || continue
        echo "==> Copying GOG's support files"
        python3 -I - "$script" "$FRONTPORT_OUT" <<'PYTHON'
import json, os, re, shutil, sys
script, app = sys.argv[1], sys.argv[2]
for action in json.load(open(script, encoding="utf-8")).get("actions", []):
    install = action.get("install") or {}
    arguments = install.get("arguments") or {}
    if install.get("action") != "supportData" or arguments.get("type") != "folder":
        continue
    match = re.fullmatch(r"\{supportDir\}/([A-Za-z0-9_.-]+)", arguments.get("source", ""))
    if arguments.get("target") != "{app}" or arguments.get("overwrite", False) or not match or match.group(1) in (".", ".."):
        sys.exit("unsupported supportData action: %r" % (arguments,))
    root = os.path.join(app, "__support", match.group(1))
    for folder, folders, files in os.walk(root):
        if any(os.path.islink(os.path.join(folder, name)) for name in folders + files):
            sys.exit("%s holds a link" % folder)
        target = os.path.join(app, os.path.relpath(folder, root))
        os.makedirs(target, exist_ok=True)
        for name in files:
            if not os.path.lexists(os.path.join(target, name)):
                shutil.copyfile(os.path.join(folder, name), os.path.join(target, name))
PYTHON
    done
}

build() {
    local installers=("$FRONTPORT_ROMS"/*)
    [ -e "${installers[0]}" ] || fail "no installer to unpack"
    [ "${#installers[@]}" = 1 ] || fail "one installer at a time"
    build_tools
    echo "==> Unpacking $(basename "${installers[0]}")"
    "$prefix/bin/innoextract" --silent --exclude-temp --output-dir "$FRONTPORT_OUT" "${installers[0]}"
    apply_gog_support
}

case "$step" in
    fetch) fetch ;;
    build) build ;;
    *) fail "unknown step $step" ;;
esac
