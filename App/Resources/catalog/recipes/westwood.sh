#!/bin/bash
# Frontport unpack Recipe: a disc of Westwood's Command & Conquer (Gold) or Red Alert, as EA gave them away: a CD
# image, `.iso`, or a ZIP or RAR holding one.
# Contract: catalog/recipes/README.md, "Unpacking". Invoked as `westwood.sh fetch`, then `westwood.sh build`.
#
# Vanilla Conquer plays a disc from a folder of its MIX files, plus what the game's installer put on the hard disk,
# which the disc keeps in INSTALL/. So this leaves $FRONTPORT_OUT/disc with the MIX files at the disc's top, named
# in upper case as on the disc, and:
# - for C&C, the MIX files its INSTALL/SETUP.Z holds (speech, transitions, icons, Gold's updates): an InstallShield 3
#   archive, PKWare DCL compressed, unpacked by isz, a small tool on zlib's blast decoder, built into
#   Builds/unpack-westwood/prefix and kept for the next disc;
# - for Red Alert, INSTALL/REDALERT.MIX.
# Everything else on the disc, Windows setup programs and DirectX among them, stays behind. bsdtar, which comes
# with macOS, reads the ZIP or RAR and the disc image.
set -euo pipefail

step=${1:?usage: westwood.sh fetch|build}
src=$FRONTPORT_SRC
work=$(dirname "$src")                 # Builds/unpack-westwood: kept between unpacks
prefix=$work/prefix

fail() {
    echo "error: $*" >&2
    exit 1
}

zlib_sha=9a93b2b7dfdac77ceba5a558a580e74667dd6fede4585b91eefb60f03b72df23
zlib_url=https://github.com/madler/zlib/releases/download/v1.3.1/zlib-1.3.1.tar.gz

fetch() {
    echo "==> Downloading zlib"
    curl -fsSL --retry 3 -o "$src/zlib.tar.gz" "$zlib_url"
    echo "$zlib_sha  $src/zlib.tar.gz" | shasum -a 256 -c --status - || fail "zlib doesn't match its pinned sha256"
    mkdir -p "$src/zlib"
    tar -xzf "$src/zlib.tar.gz" -C "$src/zlib" --strip-components=1
    rm "$src/zlib.tar.gz"
}

build_isz() {
    local stamp=$prefix/.frontport-isz
    local wanted
    wanted=$( (echo "$zlib_sha"; sed -n '/^isz_source() {$/,/^}$/p' "$0") | shasum -a 256 | cut -d' ' -f1)
    if [ -x "$prefix/bin/isz" ] && [ -f "$stamp" ] && [ "$(cat "$stamp")" = "$wanted" ]; then
        return
    fi
    echo "==> Building isz"
    rm -rf "$prefix"
    mkdir -p "$prefix/bin"
    isz_source >"$TMPDIR/isz.c"
    clang -O2 -o "$prefix/bin/isz" "$TMPDIR/isz.c" "$src/zlib/contrib/blast/blast.c" -I"$src/zlib/contrib/blast"
    echo "$wanted" >"$stamp"
}

isz_source() {
    cat <<'EOF'
// isz: extracts files from an InstallShield 3 archive (Westwood's INSTALL/SETUP.Z), whose files are PKWare DCL
// ("blast") compressed, in the layout OpenRA reads (OpenRA.Mods.Common/FileSystem/InstallShieldPackage.cs).
// usage: isz <archive>                   lists "<dir>\<name> <compressed size>"
//        isz <archive> <outdir> <name>…  extracts each named file, matched without its folder in any case
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include "blast.h"

static unsigned char *data;
static size_t size;

static void fail(const char *message) {
    fprintf(stderr, "isz: %s\n", message);
    exit(1);
}

static unsigned u16(size_t at) {
    if (at + 2 > size) fail("truncated archive");
    return data[at] | data[at + 1] << 8;
}

static unsigned long u32(size_t at) {
    if (at + 4 > size) fail("truncated archive");
    return (unsigned long)data[at] | (unsigned long)data[at + 1] << 8 | (unsigned long)data[at + 2] << 16 |
           (unsigned long)data[at + 3] << 24;
}

struct input { size_t at, end; };

static unsigned feed(void *how, unsigned char **buf) {
    struct input *in = how;
    unsigned n = (unsigned)(in->end - in->at);
    *buf = data + in->at;
    in->at = in->end;
    return n;
}

static int drain(void *how, unsigned char *buf, unsigned len) {
    return fwrite(buf, 1, len, (FILE *)how) != len;
}

int main(int argc, char **argv) {
    if (argc < 2) fail("usage: isz <archive> [<outdir> <name>...]");
    FILE *f = fopen(argv[1], "rb");
    if (!f) fail("can't open the archive");
    fseek(f, 0, SEEK_END);
    size = (size_t)ftell(f);
    fseek(f, 0, SEEK_SET);
    data = malloc(size);
    if (!data || fread(data, 1, size, f) != size) fail("can't read the archive");
    fclose(f);

    if (u32(0) != 0x8C655D13) fail("not an InstallShield 3 archive");
    size_t at = u32(41);
    unsigned dirs = u16(49);
    unsigned counts[256];
    char names[256][256];
    if (dirs > 256) fail("too many directories");
    for (unsigned i = 0; i < dirs; i++) {
        unsigned count = u16(at), chunk = u16(at + 2), length = u16(at + 4);
        if (length > 255 || at + 6 + length > size || chunk < length + 6) fail("bad directory entry");
        memcpy(names[i], data + at + 6, length);
        names[i][length] = 0;
        counts[i] = count;
        at += chunk;
    }

    // The files' data follows the 255-byte header back to back, in the order they're listed.
    size_t offset = 255;
    int extracted = 0;
    for (unsigned i = 0; i < dirs; i++) {
        for (unsigned j = 0; j < counts[i]; j++) {
            if (at + 30 > size) fail("truncated file entry");
            size_t compressed = u32(at + 7);
            unsigned chunk = u16(at + 23), length = data[at + 29];
            if (at + 30 + length > size || chunk < length + 30) fail("bad file entry");
            char name[256];
            memcpy(name, data + at + 30, length);
            name[length] = 0;
            if (offset + compressed > size) fail("file data past the end");
            if (argc == 2) printf("%s\\%s %zu\n", names[i], name, compressed);
            for (int k = 3; k < argc; k++) {
                if (strcasecmp(argv[k], name) != 0) continue;
                char path[4096];
                snprintf(path, sizeof path, "%s/%s", argv[2], argv[k]);
                FILE *out = fopen(path, "wb");
                if (!out) fail("can't create an output file");
                struct input in = {offset, offset + compressed};
                if (blast(feed, &in, drain, out, NULL, NULL) != 0) fail("bad compressed data");
                if (fclose(out) != 0) fail("can't write an output file");
                extracted++;
            }
            offset += compressed;
            at += chunk;
        }
    }
    if (argc > 2 && extracted != argc - 3) fail("not every named file is in the archive");
    return 0;
}
EOF
}

build() {
    local inputs=("$FRONTPORT_ROMS"/*)
    [ -e "${inputs[0]}" ] || fail "no disc to unpack"
    [ "${#inputs[@]}" = 1 ] || fail "one disc at a time"
    local input=${inputs[0]} image disc=$TMPDIR/disc out=$FRONTPORT_OUT/disc

    case "$input" in
        *.zip|*.rar)
            echo "==> Unpacking $(basename "$input")"
            mkdir "$TMPDIR/archive"
            /usr/bin/bsdtar -xf "$input" -C "$TMPDIR/archive"
            image=$(find "$TMPDIR/archive" -maxdepth 1 -iname '*.iso' -print | head -1)
            [ -n "$image" ] || fail "no disc image in $(basename "$input")"
            ;;
        *) image=$input ;;
    esac

    echo "==> Unpacking the disc"
    mkdir "$disc"
    /usr/bin/bsdtar -xf "$image" -C "$disc"
    rm -rf "$TMPDIR/archive"

    mkdir "$out"
    local file name count=0
    for file in "$disc"/*; do
        name=$(basename "$file" | tr '[:lower:]' '[:upper:]')
        case "$name" in
            *.MIX) cp "$file" "$out/$name"; count=$((count + 1)) ;;
        esac
    done
    [ "$count" -gt 0 ] || fail "no MIX files on the disc"

    if [ -f "$disc/INSTALL/SETUP.Z" ]; then
        build_isz
        echo "==> Unpacking the installer's files"
        # Every MIX file the installer copies: the speech, transitions and tilesets' icons, and Gold's updates.
        "$prefix/bin/isz" "$disc/INSTALL/SETUP.Z" "$out" SPEECH.MIX TRANSIT.MIX TEMPICNH.MIX WINTICNH.MIX \
            DESEICNH.MIX UPDATE.MIX UPDATEC.MIX CCLOCAL.MIX LOCAL.MIX
    elif [ -f "$disc/INSTALL/REDALERT.MIX" ]; then
        cp "$disc/INSTALL/REDALERT.MIX" "$out/REDALERT.MIX"
    else
        fail "neither C&C's INSTALL/SETUP.Z nor Red Alert's INSTALL/REDALERT.MIX is on the disc"
    fi
}

case "$step" in
    fetch) fetch ;;
    build) build ;;
    *) fail "unknown step $step" ;;
esac
