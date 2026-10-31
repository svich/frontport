#!/bin/bash
# Frontport Recipe: Render96ex (Render96/Render96ex), a Super Mario 64 PC port with new models and textures.
# Contract: catalog/recipes/README.md. Invoked as `render96ex.sh fetch`, then `render96ex.sh build`.
#
# Upstream publishes no macOS Release, and its Makefile wants Homebrew's GCC and GNU binutils, so this builds
# its `alpha` branch (the one with DynOS, which loads the model pack) with clang against a static SDL2 and
# GLEW, and wraps it in a minimal Render96ex.app holding Render96's model pack (Resources/dynos/packs) and HD
# texture pack (Resources/res/gfx). SDL's base path inside a bundle is Contents/Resources, which is where
# Render96ex looks for both. Saves and sm64config.txt go to SDL's pref path, ~/Library/Application
# Support/sm64ex, which the App Sandbox puts in the container.
#
# Build Assets: res/base.zip, the textures, sound and demos extracted from a US Build-Stage ROM, left at
# $FRONTPORT_OUT/assets for the Catalog's buildAssets.path "Contents/Resources/res/base.zip". The executable
# never contains anything from the ROM: it's compiled against empty stand-ins for the extracted files, as
# upstream already reads textures and sound from base.zip, and fetch makes it read the demos from there too.
set -euo pipefail

step=${1:?usage: render96ex.sh fetch|build}
src=$FRONTPORT_SRC
work=$(dirname "$src")                 # Builds/<port>: writable during build, kept between builds
deps=$src/deps
upstream=$src/Render96ex
prefix=$work/prefix                    # libraries built from deps/, reused while their pins don't change
tree=$TMPDIR/tree                      # this build's copy of the source, with the ROM's files, gone after it
deployment_target=13.0
export MACOSX_DEPLOYMENT_TARGET=$deployment_target
export CMAKE_POLICY_VERSION_MINIMUM=3.5 # glew still declares cmake_minimum_required(2.8.12)
export GIT_CEILING_DIRECTORIES=$work
export PYTHONDONTWRITEBYTECODE=1

# name sha256 url. Archives unpack into deps/<name>.
libraries="
sdl2 5f5993c530f084535c65a6879e9b26ad441169b3e25d789d83287040a9ca5165 https://github.com/libsdl-org/SDL/releases/download/release-2.32.10/SDL2-2.32.10.tar.gz
glew b64790f94b926acd7e8f84c5d6000a86cb43967bd1e688b03089079799c9e889 https://github.com/nigels-com/glew/releases/download/glew-2.3.1/glew-2.3.1.tgz
"
# Render96's model pack (DynOS packs for Mario, Luigi, Wario and 100-odd objects) and HD texture pack.
packs="
models 22eea6dafcc0a87659d60513eb6a6b0f4ea0acbc6645a6b1b445de9e5812e6df https://github.com/Render96/ModelPack/releases/download/3.25/Render96_DynOs_v3.25.7z
textures 23de753ea11f144c52ee069b74bb09f6cb9d2890d1a3d39db34adcf84c42eba5 https://github.com/pokeheadroom/RENDER96-HD-TEXTURE-PACK/archive/aa99a0e1a957355e7494f2109717c253905274dd.tar.gz
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
    echo "==> Fetching Render96ex $FRONTPORT_REF"
    git init --quiet "$upstream"
    git -C "$upstream" fetch --quiet --depth 1 https://github.com/Render96/Render96ex.git "$FRONTPORT_REF"
    git -C "$upstream" -c advice.detachedHead=false checkout --quiet FETCH_HEAD
    git -C "$upstream" log -1 --format='%cs %h' >"$src/version"
    rm -rf "$upstream/.git"

    mkdir -p "$deps"
    local name sha url file
    while read -r name sha url; do
        [ -n "$name" ] || continue
        echo "==> Downloading $name"
        file=$deps/$name.download
        curl -fsSL --retry 3 -o "$file" "$url"
        echo "$sha  $file" | shasum -a 256 -c --status - || fail "$name doesn't match its pinned sha256"
        mkdir -p "$deps/$name"
        case "$url" in
            *.7z) /usr/bin/bsdtar -xf "$file" -C "$deps/$name" ;;
            *) tar -xf "$file" -C "$deps/$name" --strip-components=1 ;;
        esac
        rm "$file"
    done <<<"$libraries$packs"

    echo "==> Patching"
    local makefile=$upstream/Makefile
    # macOS's make is GNU Make 3.81, which reads `VAR != command` (4.0 and later) as an assignment to
    # "VAR !", so the Makefile would never make its folders and tools. $(shell) runs them in 3.81 too.
    replace "$makefile" 'DUMMY != ./extract_assets.py $(VERSION) >&2 || echo FAIL' \
        'DUMMY := $(shell ./extract_assets.py $(VERSION) >&2 || echo FAIL)'
    replace "$makefile" 'DUMMY != CC=$(CC) CXX=$(CXX) $(MAKE) -C tools >&2 || echo FAIL' \
        'DUMMY := $(shell CC="$(CC)" CXX="$(CXX)" $(MAKE) -C tools >&2 || echo FAIL)'
    replace "$makefile" 'DUMMY != mkdir -p $(ALL_DIRS)' 'DUMMY := $(shell mkdir -p $(ALL_DIRS))'
    # Homebrew's or MacPorts' GCC isn't required: build passes clang and the libraries on the command line.
    replace "$makefile" '$(error No suitable macOS toolchain found, have you installed Homebrew?)' ''
    replace "$makefile" '-framework OpenGL $(shell pkg-config --libs glew)' '-framework OpenGL'
    # macOS has no libstdc++; clang++ links libc++ itself.
    replace "$makefile" '$(GODDARD_O_FILES) $(LDFLAGS) -lstdc++' '$(GODDARD_O_FILES) $(LDFLAGS)'
    replace "$upstream/tools/Makefile" '-laudiofile -lstdc++ -lm' '-laudiofile -lc++ -lm'
    replace "$upstream/tools/Makefile" '-pedantic -std=c99 -O2' \
        '-pedantic -std=c99 -O2 -Wno-error=implicit-function-declaration'
    # Luigi's cap model has texture coordinates the exporter wrote as 29-digit integers. GCC warns and keeps
    # their low bits, all zero; clang refuses them. Write the zeros GCC builds with.
    local cap=$upstream/actors/luigi_cap/model.inc.c
    grep -qE '\b[0-9]{20,}\b' "$cap" || fail "$cap no longer has oversized literals"
    perl -pi -e 's/\b[0-9]{20,}\b/0/g' "$cap"
    # The demos (recorded inputs for the title screen's attract mode) come from the ROM too: compile room
    # for them, and fill it from base.zip, where the extracted files go, once the file system is up.
    replace "$makefile" '$(PYTHON) tools/demo_data_converter.py assets/demo_data.json' \
        '$(PYTHON) tools/frontport_demo_data.py assets/demo_data.json'
    replace "$makefile" '@find db -name \*.* -exec echo "{} {}" >> $(BASEPACK_LST) \;' \
        '@find db -name \*.* -exec echo "{} {}" >> $(BASEPACK_LST) \;
	@find assets/demos -name \*.bin -exec echo "{} {}" >> $(BASEPACK_LST) \;'
    # The languages are read from res/texts beside argv[0], which in a bundle is Contents/MacOS; read them
    # from SDL's base path instead, like everything else: Contents/Resources in a bundle, else the same.
    # A trailing "/" is what the next lines strip, as they would the executable's name.
    replace "$upstream/src/text/text-loader.c" '    snprintf(exeDir, FILENAME_MAX, "%s", exePath);' \
        '    extern const char *sys_exe_path(void);
    snprintf(exeDir, FILENAME_MAX, "%s/", sys_exe_path());'
    replace "$upstream/src/pc/pc_main.c" '    fs_init(sys_ropaths, gamedir, userpath);' \
        '    fs_init(sys_ropaths, gamedir, userpath);
    { extern void frontport_load_demos(void); frontport_load_demos(); }'
    cat >"$upstream/tools/frontport_demo_data.py" <<'EOF'
# Added by Frontport's Recipe: demo_data_converter.py, but leaving the demos out of the executable. Each one
# gets room of its size from assets.json, filled at startup from assets/demos/<name>.bin in base.zip.
import json
import re
import sys

defines = [a[2:].split("=")[0] for a in sys.argv[2:] if a.startswith("-D")]
with open(sys.argv[1]) as file:
    descr = json.loads(re.sub(r"/\*[\w\W]*?\*/", "", file.read()))
with open("assets.json") as file:
    sizes = {name: data[-2] for name, data in json.load(file).items() if not name.startswith("@")}

def wanted(item):
    return "ifdef" not in item or any(d in defines for d in item["ifdef"])

table = [item for item in descr["table"] if wanted(item)]
demofiles = [item["name"] for item in descr["demofiles"] if wanted(item)]

print('#include "types.h"')
print("#include <stddef.h>")
print('#include "pc/fs/fs.h"')
print("struct DemoInputsObj {")
print("u32 numEntries;")
print("const void *addrPlaceholder;")
print("struct OffsetSizePair entries[%d];" % len(table))
for name in demofiles:
    print("u8 %s[%d];" % (name, sizes["assets/demos/%s.bin" % name]))
print("} gDemoInputs = {")
print("%d," % len(table))
print("NULL,")
print("{")
for item in table:
    size = "sizeof(gDemoInputs.%s)" % item["demofile"]
    if "extraSize" in item:
        size += " + %d" % item["extraSize"]
    print("{offsetof(struct DemoInputsObj, %s), %s}," % (item["demofile"], size))
print("},")
print("};")
print("void frontport_load_demos(void) {")
print("    uint64_t size; u8 *data;")
for name in demofiles:
    print('    if ((data = fs_load_file("assets/demos/%s.bin", &size)) != NULL) {' % name)
    print("        if (size == sizeof(gDemoInputs.%s)) memcpy(gDemoInputs.%s, data, size);" % (name, name))
    print("        free(data);")
    print("    }")
print("}")
EOF
    # The sound player sequence is GNU assembler source, which the Makefile assembles with GNU as and takes
    # .rodata out of with objcopy. Clang's assembler, writing ELF as a little-endian 64-bit Linux host's as
    # would, and a few lines of Python stand in for them.
    cat >"$upstream/tools/frontport_as.sh" <<'EOF'
#!/bin/bash
# Added by Frontport's Recipe: GNU as's command line, for clang's integrated assembler.
args=()
while [ $# -gt 0 ]; do
    case "$1" in
        -MD) shift 2 ;;
        --defsym) args+=("-Wa,--defsym,$2"); shift 2 ;;
        *) args+=("$1"); shift ;;
    esac
done
exec clang --target=x86_64-linux-gnu -c -x assembler "${args[@]}"
EOF
    chmod +x "$upstream/tools/frontport_as.sh"
    cat >"$upstream/tools/frontport_objcopy.py" <<'EOF'
# Added by Frontport's Recipe: `objcopy -j <section> <elf> -O binary <out>` for 64-bit little-endian ELF.
import struct
import sys

args = sys.argv[1:]
section = args[args.index("-j") + 1]
output = args[args.index("-O") + 2]
source = [a for i, a in enumerate(args) if i not in (args.index("-j"), args.index("-j") + 1,
                                                       args.index("-O"), args.index("-O") + 1, args.index("-O") + 2)][0]
elf = open(source, "rb").read()
assert elf[:4] == b"\x7fELF" and elf[4] == 2 and elf[5] == 1, "not a 64-bit little-endian ELF object"
shoff, = struct.unpack_from("<Q", elf, 0x28)
shentsize, shnum, shstrndx = struct.unpack_from("<HHH", elf, 0x3A)
def header(i):
    return struct.unpack_from("<IIQQQQIIQQ", elf, shoff + i * shentsize)
names = header(shstrndx)[4]
for i in range(shnum):
    name, kind, _, _, offset, size = header(i)[:6]
    if elf[names + name:elf.index(b"\0", names + name)].decode() == section:
        open(output, "wb").write(elf[offset:offset + size])
        break
else:
    sys.exit("no section " + section + " in " + source)
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
    rm -rf "$work/deps-build"
    echo "$wanted" >"$stamp"
}

build() {
    build_libraries

    # The Makefile splices paths into shell commands unquoted, and Builds/ lies under "Application Support",
    # so it runs in a copy of the source and reaches the libraries by a relative path without spaces.
    rm -rf "$tree"
    cp -Rc "$upstream" "$tree"
    cd "$tree"
    local lib
    lib=$(python3 -c 'import os, sys; print(os.path.relpath(sys.argv[1]))' "$prefix")
    mkdir -p frontport
    cat >frontport/sdl2-config <<EOF
#!/bin/sh
case "\$1" in
    --cflags) echo "-I$lib/include/SDL2 -D_THREAD_SAFE" ;;
    *) "$prefix/bin/sdl2-config" --static-libs | sed "s|-L$prefix/lib||; s|-lSDL2|$lib/lib/libSDL2.a|; s|$prefix/|$lib/|g" ;;
esac
EOF
    chmod +x frontport/sdl2-config

    # Clang 17 and later make these errors; the decompiled code predates them. The Makefile checks every
    # file's syntax with CC_CHECK before compiling it with OPT_FLAGS, so both get them.
    local lenient
    lenient=$(printf -- '-Wno-error=%s ' implicit-function-declaration incompatible-function-pointer-types \
        int-conversion incompatible-pointer-types)
    local exe=build/us_pc/sm64.us.f3dex2e
    local make_flags=(
        CC=clang CXX=clang++ LD=clang++ CPP="clang -E -P -x c"
        AS=tools/frontport_as.sh
        OBJCOPY="python3 tools/frontport_objcopy.py"
        SDLCONFIG=frontport/sdl2-config
        PLATFORM_CFLAGS="-I$lib/include -arch arm64 -mmacosx-version-min=$deployment_target"
        PLATFORM_LDFLAGS="$lib/lib/libGLEW.a -arch arm64 -mmacosx-version-min=$deployment_target"
        OPT_FLAGS="-O2 $lenient" CC_CHECK_CFLAGS="$lenient"
    )

    # The executable, from empty stand-ins for every file the ROM would give it: with external data, the
    # Makefile only puts their names in it. The sound it would assemble from the ROM's samples is stood in
    # for the same way, and make told to treat those files as up to date.
    echo "==> Building Render96ex"
    python3 - <<'EOF'
import json, os
for name in json.load(open("assets.json")):
    if name.endswith(".png") and not os.path.exists(name):
        os.makedirs(os.path.dirname(name), exist_ok=True)
        open(name, "wb").close()
        print(name, file=open("frontport/stand-ins", "a"))
EOF
    local sound=build/us_pc/sound sound_files file
    sound_files=("$sound/sound_data.ctl" "$sound/sound_data.tbl" "$sound/sequences.bin" "$sound/bank_sets")
    mkdir -p "$sound"
    local old_files=()
    for file in "${sound_files[@]}"; do
        : >"$file"
        old_files+=(-o "$file")
    done
    make -j "$FRONTPORT_JOBS" NOEXTRACT=1 "${make_flags[@]}" "${old_files[@]}" "$exe"

    make_app "$exe"
    extract_assets "$exe" "${make_flags[@]}"
}

# extract_assets <executable> <make flags...>: base.zip from the US ROM among the Build-Stage ROMs, made by the
# Makefile's res target once the stand-ins are replaced by the ROM's files; nothing when there is none.
extract_assets() {
    local exe=$1
    shift
    local rom
    for rom in "$FRONTPORT_ROMS"/*.z64; do
        [ -e "$rom" ] || continue
        echo "==> Extracting assets from $(basename "$rom")"
        xargs rm -f <frontport/stand-ins
        rm -f build/us_pc/sound/sound_data.ctl build/us_pc/sound/sound_data.tbl \
            build/us_pc/sound/sequences.bin build/us_pc/sound/bank_sets build/us_pc/basepack.lst
        cp -c "$rom" baserom.us.z64
        ./extract_assets.py us
        rm baserom.us.z64
        echo "==> Building sound"
        make -j "$FRONTPORT_JOBS" NOEXTRACT=1 "$@" -o "$exe" build/us_pc/sound/sound_data.ctl \
            build/us_pc/sound/sequences.bin
        echo "==> Packing base.zip"
        make -j "$FRONTPORT_JOBS" NOEXTRACT=1 "$@" -o "$exe" res
        [ -f build/us_pc/res/base.zip ] || fail "the Makefile made no base.zip"
        mv build/us_pc/res/base.zip "$FRONTPORT_OUT/assets"
        return
    done
    echo "==> No US ROM given: skipping assets"
}

# make_app <executable>: Render96ex.app around it, with its resources and the packs.
make_app() {
    echo "==> Making Render96ex.app"
    local app=$FRONTPORT_OUT/Render96ex.app plist version
    plist=$app/Contents/Info.plist
    local date year month day
    read -r date _ <"$src/version"                           # 2026-07-16 f6e9e1b
    IFS=- read -r year month day <<<"$date"
    version=$(printf '%d.%d.%d' "$year" $((10#$month)) $((10#$day)))   # 2026.7.16
    mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
    cp "$1" "$app/Contents/MacOS/Render96ex"
    # What the Makefile leaves beside the executable: res/texts (the languages) and dynos/audio (Render96's
    # music, jingles and voices). Then the packs, in the folders their READMEs name.
    cp -Rc build/us_pc/res build/us_pc/dynos "$app/Contents/Resources/"
    cp -Rc "$deps/textures/gfx" "$app/Contents/Resources/res/gfx"
    rm -rf "$app/Contents/Resources/dynos/packs"
    cp -Rc "$deps/models" "$app/Contents/Resources/dynos/packs"
    make_icns levels/fourth_floor/marioIconR96_1024.rgba32.png "$app/Contents/Resources/Render96ex.icns"
    plutil -create xml1 "$plist"
    plutil -insert CFBundleExecutable -string Render96ex "$plist"
    plutil -insert CFBundleIdentifier -string "dev.frontport.port.$FRONTPORT_PORT" "$plist"
    plutil -insert CFBundleName -string Render96ex "$plist"
    plutil -insert CFBundleIconFile -string Render96ex "$plist"
    plutil -insert CFBundlePackageType -string APPL "$plist"
    plutil -insert CFBundleInfoDictionaryVersion -string 6.0 "$plist"
    plutil -insert CFBundleShortVersionString -string "$version" "$plist"
    plutil -insert CFBundleVersion -string "$version" "$plist"
    plutil -insert CFBundleGetInfoString -string "$(cat "$src/version")" "$plist"
    plutil -insert LSMinimumSystemVersion -string "$deployment_target" "$plist"
    plutil -insert LSApplicationCategoryType -string public.app-category.games "$plist"
    plutil -insert NSHighResolutionCapable -bool true "$plist"
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
