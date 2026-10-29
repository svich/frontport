#!/bin/bash
# Frontport unpack Recipe: a PC Game's CD image, an ISO 9660 `.iso`, for Games the Catalog takes as the disc's folder.
# Contract: catalog/recipes/README.md, "Unpacking". Invoked as `iso.sh fetch`, then `iso.sh build`.
#
# macOS's bsdtar (libarchive) reads the disc's Joliet or Rock Ridge names, the ones a mounted disc shows, so the files
# land in $FRONTPORT_OUT/disc as they are on the CD, and the folder has the hash the CD's own files have. Nothing to
# fetch: bsdtar comes with macOS.
set -euo pipefail

step=${1:?usage: iso.sh fetch|build}

fail() {
    echo "error: $*" >&2
    exit 1
}

build() {
    local images=("$FRONTPORT_ROMS"/*)
    [ -e "${images[0]}" ] || fail "no disc image to unpack"
    [ "${#images[@]}" = 1 ] || fail "one disc image at a time"
    echo "==> Unpacking $(basename "${images[0]}")"
    mkdir "$FRONTPORT_OUT/disc"
    /usr/bin/bsdtar -xf "${images[0]}" -C "$FRONTPORT_OUT/disc"
}

case "$step" in
    fetch) ;;
    build) build ;;
    *) fail "unknown step $step" ;;
esac
