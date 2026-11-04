#!/bin/bash
# Frontport Recipe: OpenLara (XProger/OpenLara), a new engine for the classic Tomb Raider games.
# Contract: catalog/recipes/README.md. Invoked as `openlara.sh fetch`, then `openlara.sh build`.
#
# Upstream's last Release is from 2019, with no Mac build; its macOS port (src/platform/osx) is an Xcode project
# that plays from the folder the app sits in and keeps saves and settings in ~/Library/Application Support/OpenLara.
# This compiles the same sources with clang (the engine is headers included by main.mm, plus three small libraries)
# and wraps them in an app, with no dependencies. fetch patches it to:
# - play from ~/Library/Application Support/OpenLara (inside the container under the App Sandbox), where Frontport
#   Seeds the game's files, instead of beside the app, which a sandboxed app can't read;
# - read gamepads through the GameController framework, polled each frame, instead of its IOHID code, which maps
#   only a few vendors' controllers;
# - find Tomb Raider I-III Remastered's copy of the original game: its music as TRACKS/<n>.OGG, the voiced tracks
#   in TRACKS/<language>/, and the PlayStation videos in FMV/OG/.
set -euo pipefail

step=${1:?usage: openlara.sh fetch|build}
src=$FRONTPORT_SRC
work=$(dirname "$src")                 # Builds/<port>: writable during build, kept between builds
openlara=$src/OpenLara
deployment_target=13.0
export MACOSX_DEPLOYMENT_TARGET=$deployment_target
export GIT_CEILING_DIRECTORIES=$work

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

fetch() {
    echo "==> Cloning OpenLara $FRONTPORT_REF"
    git clone --quiet https://github.com/XProger/OpenLara.git "$openlara"
    git -C "$openlara" -c advice.detachedHead=false checkout --quiet "$FRONTPORT_REF"
    # Upstream tags only its old Releases: the version is the commit's date, and its hash describes it.
    git -C "$openlara" log -1 --format='%cs %H' >"$src/version"

    echo "==> Patching"
    local main=$openlara/src/platform/osx/main.mm gameflow=$openlara/src/gameflow.h

    replace "$main" '    NSBundle *bundle    = [NSBundle mainBundle];
    NSURL *parentURL    = bundle.bundleURL.URLByDeletingLastPathComponent;
    [parentURL getFileSystemRepresentation:contentDir maxLength:sizeof(contentDir)];
    strcat(contentDir, "/");' '    // Frontport: play from ~/Library/Application Support/OpenLara, which holds the saves and settings too.
    [supportPath getCString:contentDir maxLength:sizeof(contentDir) encoding:NSUTF8StringEncoding];
    strcat(contentDir, "/");'

    replace "$main" '#include <IOKit/hid/IOHidLib.h>' '#include <IOKit/hid/IOHidLib.h>
#import <GameController/GameController.h>'
    replace "$main" 'bool osJoyReady(int index) {' 'bool osJoyReadyHID(int index) {'
    replace "$main" 'void osJoyVibrate(int index, float L, float R) {' 'void osJoyVibrateHID(int index, float L, float R) {'
    replace "$main" 'NSWindow *window;' '// Frontport: gamepads through the GameController framework, polled each frame, instead of the IOHID code above.
static GCController *fpPads[4];

bool osJoyReady(int index) {
    return index >= 0 && index < 4 && fpPads[index] != nil;
}

void osJoyVibrate(int index, float L, float R) {}

static void fpJoyPoll() {
    int count = 0;
    for (GCController *controller in [GCController controllers]) {
        if (count < 4 && controller.extendedGamepad) fpPads[count++] = controller;
    }
    for (int i = count; i < 4; i++) fpPads[i] = nil;
    for (int i = 0; i < 4; i++) {
        GCExtendedGamepad *pad = fpPads[i].extendedGamepad;
        if (!pad) {
            for (int key = jkA; key < jkMAX; key++) Input::setJoyDown(i, JoyKey(key), false);
            Input::setJoyPos(i, jkL, vec2(0.0f, 0.0f));
            Input::setJoyPos(i, jkR, vec2(0.0f, 0.0f));
            Input::joy[i].LT = Input::joy[i].RT = 0.0f;
            continue;
        }
        Input::setJoyPos(i, jkL,  vec2(pad.leftThumbstick.xAxis.value, -pad.leftThumbstick.yAxis.value));
        Input::setJoyPos(i, jkR,  vec2(pad.rightThumbstick.xAxis.value, -pad.rightThumbstick.yAxis.value));
        Input::setJoyPos(i, jkLT, vec2(pad.leftTrigger.value, 0.0f));
        Input::setJoyPos(i, jkRT, vec2(pad.rightTrigger.value, 0.0f));
        Input::setJoyDown(i, jkA,      pad.buttonA.pressed);
        Input::setJoyDown(i, jkB,      pad.buttonB.pressed);
        Input::setJoyDown(i, jkX,      pad.buttonX.pressed);
        Input::setJoyDown(i, jkY,      pad.buttonY.pressed);
        Input::setJoyDown(i, jkLB,     pad.leftShoulder.pressed);
        Input::setJoyDown(i, jkRB,     pad.rightShoulder.pressed);
        Input::setJoyDown(i, jkSelect, pad.buttonOptions.pressed);
        Input::setJoyDown(i, jkStart,  pad.buttonMenu.pressed);
        Input::setJoyDown(i, jkL,      pad.leftThumbstickButton.pressed);
        Input::setJoyDown(i, jkR,      pad.rightThumbstickButton.pressed);
        Input::setJoyDown(i, jkUp,     pad.dpad.up.pressed);
        Input::setJoyDown(i, jkDown,   pad.dpad.down.pressed);
        Input::setJoyDown(i, jkLeft,   pad.dpad.left.pressed);
        Input::setJoyDown(i, jkRight,  pad.dpad.right.pressed);
    }
}

NSWindow *window;'
    replace "$main" '    if (!Game::update())' '    fpJoyPoll();
    if (!Game::update())'
    replace "$main" '    joyInit();
    sndInit();' '    sndInit();'
    replace "$main" '    joyFree();
' ''

    replace "$gameflow" '#define CHECK_FILE(name) if (Stream::existsContent(name)) return name' '// Frontport: Tomb Raider I-III Remastered keeps the PlayStation videos, FMV/<name>.FMV, in FMV/OG/.
static const char* fpRemasteredVideo(const char *name) {
    static char path[64];
    if (strncmp(name, "FMV/", 4) != 0) return NULL;
    snprintf(path, sizeof(path), "FMV/OG/%s", name + 4);
    return Stream::existsContent(path) ? path : NULL;
}

#define CHECK_FILE(name) if (Stream::existsContent(name)) return name; else if (const char *fpVideo = fpRemasteredVideo(name)) return fpVideo'
    replace "$gameflow" '                if (Stream::existsContent(buf)) {
                    strcpy(name, buf);
                    return true;
                }
            }

        return false;' '                if (Stream::existsContent(buf)) {
                    strcpy(name, buf);
                    return true;
                }
            }

        // Frontport: Tomb Raider I-III Remastered keeps track_<nn> as TRACKS/<n>.OGG, and the voiced ones in
        // TRACKS/<language>/, English when there is none for the language.
        if (pre[0] == 0 && strncmp(name, "track_", 6) == 0) {
            const char *id = name + 6;
            while (id[0] == '\''0'\'' && id[1]) id++;
            const char *dirs[] = { lng[Core::settings.audio.language + 2] + 1, "EN/", "" };
            for (int d = 0; d < COUNT(dirs); d++) {
                snprintf(buf, sizeof(buf), d == 0 ? "TRACKS/%s/%s.OGG" : "TRACKS/%s%s.OGG", dirs[d], id);
                if (Stream::existsContent(buf)) {
                    strcpy(name, buf);
                    return true;
                }
            }
        }

        return false;'
}

build() {
    echo "==> Building OpenLara"
    local objects=$work/objects
    rm -rf "$objects"
    mkdir -p "$objects"
    local flags=(-arch arm64 -mmacosx-version-min=$deployment_target -O2 -DNDEBUG -w)
    clang "${flags[@]}" -c "$openlara/src/libs/tinf/tinflate.c" -o "$objects/tinflate.o"
    clang "${flags[@]}" -c "$openlara/src/libs/stb_vorbis/stb_vorbis.c" -o "$objects/stb_vorbis.o"
    clang++ "${flags[@]}" -std=c++11 -c "$openlara/src/libs/minimp3/minimp3.cpp" -o "$objects/minimp3.o"
    clang++ "${flags[@]}" -std=c++11 -fobjc-arc -I"$openlara/src" \
        -c "$openlara/src/platform/osx/main.mm" -o "$objects/main.o"

    local app=$FRONTPORT_OUT/OpenLara.app plist date hash version
    plist=$app/Contents/Info.plist
    read -r date hash <"$src/version"                      # 2026-07-26 3b268ca4bf98…
    version=${date//-/}                                     # 20260726
    mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
    clang++ "${flags[@]}" -o "$app/Contents/MacOS/OpenLara" "$objects"/*.o \
        -framework Cocoa -framework OpenGL -framework AudioToolbox -framework IOKit -framework GameController

    echo "==> Making OpenLara.app"
    make_icon "$openlara/src/platform/osx/Assets.xcassets/AppIcon.appiconset" "$app/Contents/Resources/OpenLara.icns"
    plutil -create xml1 "$plist"
    plutil -insert CFBundleExecutable -string OpenLara "$plist"
    plutil -insert CFBundleIdentifier -string "dev.frontport.port.$FRONTPORT_PORT" "$plist"
    plutil -insert CFBundleName -string OpenLara "$plist"
    plutil -insert CFBundlePackageType -string APPL "$plist"
    plutil -insert CFBundleInfoDictionaryVersion -string 6.0 "$plist"
    plutil -insert CFBundleShortVersionString -string "$version" "$plist"
    plutil -insert CFBundleVersion -string "$version" "$plist"
    plutil -insert CFBundleGetInfoString -string "$date-g${hash:0:7}" "$plist"
    plutil -insert CFBundleIconFile -string OpenLara "$plist"
    plutil -insert LSMinimumSystemVersion -string "$deployment_target" "$plist"
    plutil -insert LSApplicationCategoryType -string public.app-category.action-games "$plist"
    plutil -insert NSHighResolutionCapable -bool true "$plist"
    plutil -insert NSPrincipalClass -string NSApplication "$plist"
}

# make_icon <appiconset> <icns>: an icns from upstream's square PNGs, which an icns holds as they are.
make_icon() {
    python3 - "$1" "$2" <<'EOF'
import struct, sys
files = {32: "icon16x16@2x", 64: "icon32x32@2x", 128: "icon128x128", 256: "icon256x256", 512: "icon512x512"}
types = {32: [b"ic11"], 64: [b"ic12"], 128: [b"ic07"], 256: [b"ic08", b"ic13"], 512: [b"ic09", b"ic14"]}
entries = b""
for size, kinds in types.items():
    png = open(f"{sys.argv[1]}/{files[size]}.png", "rb").read()
    assert png[:8] == b"\x89PNG\r\n\x1a\n" and struct.unpack(">II", png[16:24]) == (size, size), f"unusable icon {size}"
    entries += b"".join(kind + struct.pack(">I", len(png) + 8) + png for kind in kinds)
open(sys.argv[2], "wb").write(b"icns" + struct.pack(">I", len(entries) + 8) + entries)
EOF
}

case "$step" in
    fetch) fetch ;;
    build) build ;;
    *) fail "unknown step $step" ;;
esac
