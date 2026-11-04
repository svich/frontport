# Recipes

A Recipe is the Catalog's instructions for building a Port from source: one bash script per source-built
entry, named by the entry's `releases.recipe` and covered by the Catalog's signature through
`releases.recipeSHA256`. Frontport's Builder (`FrontportKit/Sources/FrontportBuilder`) runs it.

## Invocation

The Builder runs every Recipe twice, each time as `/bin/bash recipe.sh <step>` under its own
`sandbox-exec` profile (`FrontportBuilder/Profiles/<step>.sb`), with `$FRONTPORT_SRC` as the working
directory:

1. **`recipe.sh fetch`**, network on: download everything the build needs into `$FRONTPORT_SRC`.
2. **`recipe.sh build`**, network off: build the Port into `$FRONTPORT_OUT`.

A non-zero exit fails the build. Both steps' stdout and stderr go, in order, to the build log,
`Logs/<port>/build.log`, which is outside the Recipe's reach and holds only the latest run.

Between runs:
- **Fetch** starts from an empty `$FRONTPORT_SRC`, and is skipped when the last fetch for the same ref and
  the same Recipe succeeded. So the source tree a build sees is always one complete fetch.
- **Build** runs every time, with empty `$FRONTPORT_OUT`, `$TMPDIR` and `$FRONTPORT_ROMS` folders, and
  none of them outlives the run: `$TMPDIR` and `$FRONTPORT_ROMS` are removed once it ends, and
  `$FRONTPORT_OUT` once Frontport has taken what's in it, or at once when the run fails. So does a
  `$FRONTPORT_SRC` whose fetch failed. Everything else in `Builds/<port>/` (the parent of `$FRONTPORT_SRC`)
  persists until the Port is uninstalled, so a Recipe may keep a dependency prefix or build folders there. It
  owns their invalidation, for example with a stamp of its pinned versions, and should remove what no later
  build can use.
- **Processes:** nothing a step starts outlives it. Once the script exits, or the step is cancelled, every
  process it left running is killed, even one that left its process group, so a step can't leave a server
  for the next one.
- **Links:** Frontport runs unsandboxed, so it treats `Builds/<port>/` as untrusted. It never follows a link
  there, starts over with a fresh fetch when `$FRONTPORT_SRC` isn't a plain folder, and refuses to run a step
  when `$FRONTPORT_SRC`, `$FRONTPORT_OUT`, `$TMPDIR` or `$FRONTPORT_ROMS` was swapped for a link.

## Environment

| Variable | Value |
|---|---|
| `FRONTPORT_PORT` | The Port's Catalog id, such as `starship`. |
| `FRONTPORT_REF` | The git ref the Catalog pins for the Channel being installed. |
| `FRONTPORT_SRC` | `Builds/<port>/src`: the source tree. |
| `FRONTPORT_OUT` | `Builds/<port>/out`: where the build leaves its output. |
| `FRONTPORT_TOOLCHAIN` | `Toolchain/<version>`: the pinned prefix, with `bin/cmake`, `bin/ninja` and friends. |
| `FRONTPORT_ROMS` | `Builds/<port>/roms`: clones of the Build-Stage ROMs (accepted ROM and extras), in standard form, named `<sha1>.<format>` (`.z64`, `.sfc`, `.nsp`, `.nsz`, `.xci`, `.xcz`, `.keys`). Empty during fetch, and unreadable then. Removed after the build. |
| `FRONTPORT_METAL` | The `bin` folder of Xcode's Metal toolchain (`metal`, `metallib`), when it’s installed; unset otherwise. Only the build step can read and run it. |
| `FRONTPORT_JOBS` | Number of parallel jobs to use. |
| `TMPDIR` | `Builds/<port>/tmp`: a private tmp folder, shared by both steps of a run and removed after it. |
| `HOME` | An empty folder inside `$TMPDIR`; the user's home folder is out of reach. |
| `PATH` | `$FRONTPORT_TOOLCHAIN/bin`, the developer tools' own `bin` folders, then `/usr/bin:/bin:/usr/sbin:/sbin`. |
| `DEVELOPER_DIR`, `SDKROOT` | The active developer directory and its macOS SDK, so compilers run without the `xcrun` shims. For an iOS Recipe, Xcode's and its iPhoneOS SDK ([iOS Recipes](#ios-recipes)). |
| `FRONTPORT_SDK` | `iphoneos` for an iOS Recipe, as `xcrun --sdk` names its SDK; unset for a Mac one. |
| `LANG` | `en_US.UTF-8`. Nothing else is inherited from Frontport's environment. |

Every path is canonical (symlinks resolved). All paths may contain spaces (`Application Support`): quote them.

## Output

- **The app:** exactly one `$FRONTPORT_OUT/*.app`. It must be self-contained: link libraries statically,
  or bundle them in `Contents/Frameworks`. Frontport sets its bundle ID and signs it afterwards, so a
  Recipe doesn't sign.
- **Build Assets:** either inside that app at the entry's `buildAssets.path`, or as `$FRONTPORT_OUT/assets`:
  the file or folder Frontport keeps beside the app and links at `buildAssets.path`, so the Port reads it
  there either way. Prefer `assets`, which keeps the app the same whatever ROM was used, and keeps the Build
  Assets out of its signature.
- **No ROM:** when `$FRONTPORT_ROMS` is empty, skip the asset step cleanly and still produce the app.
  Frontport does this on purpose when an update carries the existing Build Assets over.
- **No links out:** the app and `assets` must not be links, and a link inside them must lead somewhere
  inside them (a framework's `Versions/Current`, say). Frontport refuses the output otherwise.

## The sandbox

| | fetch | build |
|---|---|---|
| Network | outbound to remote hosts, plus name lookups; no Unix sockets | none |
| Writes | `$FRONTPORT_SRC`, `$TMPDIR` | `Builds/<port>/`, `$TMPDIR` |
| Reads | system, developer tools, `$FRONTPORT_TOOLCHAIN`, the Recipe, `$FRONTPORT_SRC` | the same, plus all of `Builds/<port>/`, ROMs included |

Neither step can read anything else in the user's home folder (not even file metadata), nor `/usr/local`,
`/opt` or `/Library/Frameworks`, so Homebrew and MacPorts can't leak into a build. "Developer tools" is
the active developer directory: the whole `Xcode.app`, or `/Library/Developer/CommandLineTools`.

Xcode 26 and later download the Metal compiler as a separate component, mounted inside the home folder, where
`xcrun` in the sandbox can't find it. The build step may read and run it at `$FRONTPORT_METAL`; call `metal` and
`metallib` from there, with `-fmodules-cache-path` inside `$TMPDIR` (the default cache is outside the sandbox).

## Progress

The Builder turns output lines into progress:
- `==> <step>`: shown as the current step. Print one before each long stage.
- ninja's `[n/m]` and CMake's `[ nn%]` lines move the progress bar.

## Writing a Recipe

- **Pin everything.** Upstream comes from `$FRONTPORT_REF`; a Recipe may also pin the commit it expects
  for a known tag, so a moved tag fails the fetch. Every other download is pinned by URL and sha256 and
  verified in fetch. Prefer release tarballs with GitHub digests, and GitHub archives of pinned commits.
- **Libraries** come from pinned source tarballs, built into a prefix under `Builds/<port>/`, statically
  where possible. Never Homebrew.
- **Nothing downloads during build.** Point CMake's FetchContent at fetched sources with
  `FETCHCONTENT_SOURCE_DIR_<NAME>` and `FETCHCONTENT_FULLY_DISCONNECTED=ON` (FetchContent then skips its
  patch step, so apply upstream's patches in fetch), and turn `file(DOWNLOAD https://…)` into `file://` URLs.
- **Patches** that make a Port run from a sandboxed bundle (Data in `~/Library/Application Support/<name>`,
  which the sandbox puts in the container; Build Assets read from `Contents/Resources`) are applied in
  fetch, and fail loudly when the text they replace has changed. A folder a Port writes beside its
  executable needs no patch: the entry's `redirects` lead it into the container, as OpenGOAL's `data/log`.
- **Tools:** bash, git, curl, cmake, ninja, make, clang, python3 (from the developer tools), perl, patch,
  shasum, plutil, sips, iconutil. sips and iconutil need LaunchServices and fail in the build step, but a
  small tool calling ImageIO works there, compiled with clang in the build step.
- **CMake 4** refuses projects declaring `cmake_minimum_required` below 3.5; export
  `CMAKE_POLICY_VERSION_MINIMUM=3.5` for those.
- **Asset format:** when a Recipe change alters the Build Assets, bump the entry's `buildAssets.format` so
  updates regenerate them instead of carrying the old ones over.

To run a Recipe end to end through the Builder (network, Command Line Tools, a few minutes):

```sh
cd FrontportKit
FRONTPORT_NETWORK_TESTS=1 FRONTPORT_RECIPE=starship swift test --filter RecipeIntegrationTests
```

Add `FRONTPORT_RECIPE_ROOT=<folder>` to keep the toolchain and builds between runs,
`FRONTPORT_RECIPE_ROMS=<rom>,…` to feed Build-Stage ROMs, and `FRONTPORT_RECIPE_REF=<ref>` to build another ref.

## Unpacking

An unpack Recipe turns an installer the Catalog lists into the ROMs it holds ([ADR 0008](../../docs/adr/0008-unpack-installers-in-the-build-sandbox.md)). Its `KnownROM` names it in `unpack.recipe`, pinned by `unpack.recipeSHA256`. The Builder runs it like any Recipe, `fetch` then `build`, in the same sandbox, with these differences:

- **Workspace:** `Builds/unpack-<recipe name>/`, shared by every installer the Recipe unpacks, so a tool it builds into `Builds/unpack-<name>/prefix` is reused. `FRONTPORT_PORT` is `unpack-<name>`, and `FRONTPORT_REF` is empty: the Recipe pins its sources itself.
- **Input:** `$FRONTPORT_ROMS` holds exactly one file, the installer, as `<sha1>.<format>`.
- **Output:** what the installer holds, in `$FRONTPORT_OUT`. Frontport hashes each folder there as a folder ROM, keeps those the installer `yields`, and ignores the rest. No app.

## iOS Recipes

An iOS Recipe builds a Port's iOS version, which Frontport signs and installs on Devices ([DESIGN › Devices](../../docs/DESIGN.md#devices)). The entry names it in `ios.releases.recipe`, pinned by `ios.releases.recipeSHA256`. The Builder runs it like any Recipe, `fetch` then `build`, in the same sandbox, with these differences:

- **Workspace:** `Builds/<port>.ios/`, apart from the Mac build's `Builds/<port>/`; the build log is `Logs/<port>.ios/build.log`. Frontport keeps the app it prepared for Devices beside the Recipe's folders, in `prepared/` and `preparing/`, which a Recipe never touches. `FRONTPORT_PORT` is still the Port's id.
- **Environment:** `FRONTPORT_SDK` is `iphoneos`; check it, so the Recipe is never run as a Mac one. `DEVELOPER_DIR` is full Xcode's, whether or not the Command Line Tools are selected or installed, and `SDKROOT` its iPhoneOS SDK, so `cmake -DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_SYSROOT="$SDKROOT"` builds for a Device. `xcrun_db` names a file in `$TMPDIR`: xcrun keeps its cache in the per-user temporary folder, which the sandbox denies, and without one takes about 2 s a call. A tool the build runs on the Mac, such as an image scaler, builds with `xcrun --sdk macosx clang`; `sips` doesn't run in the sandbox, which lacks LaunchServices.
- **No actool or ibtool:** they fail in the sandbox, which denies folders they need, and CMake's Ninja generator copies asset catalogs and storyboards into the app uncompiled anyway: delete those copies, and drop upstream's `UILaunchStoryboardName` for the `UILaunchScreen` key. Icons are loose opaque PNGs instead of an asset catalog, `<name>@2x.png` and `<name>@3x.png` for iPhone, `<name>@2x~ipad.png` for iPad, each `<name>` listed in `CFBundleIcons` or `CFBundleIcons~ipad` › `CFBundlePrimaryIcon` › `CFBundleIconFiles`: 120 and 180 px (`AppIcon60x60`), 152 px (`AppIcon76x76`) and 167 px (`AppIcon83.5x83.5`).
- **Info.plist:** CMake's default one lacks iOS's keys, so bring upstream's or write one, with `MinimumOSVersion` equal to `LC_BUILD_VERSION`'s minimum (the deployment target), `UIDeviceFamily`, `CFBundleSupportedPlatforms` (`iPhoneOS`) and `UILaunchScreen`. `CFBundleShortVersionString` and `CFBundleVersion` are at most three integers each, such as `1.1.0` and `7` for `v1.1.0-7-g0609bcf`. A Port whose files are Seeded into `Documents` also gets `UIFileSharingEnabled` and `LSSupportsOpeningDocumentsInPlace`, so Files shows that folder.
- **UIScene:** iOS ends an app linked against the iOS 27 SDK or later that has no scene delegate (`UIApplicationSceneManifest`) as soon as it launches. An engine without one, such as SDL2's UIKit backend, gets its executable stamped with an older SDK, last, after the final link: `vtool -set-build-version ios <minimum> 18.0 -replace -output "$exe.stamped" "$exe" && mv "$exe.stamped" "$exe"`.
- **Output:** exactly one unsigned, flat `$FRONTPORT_OUT/*.app` (no `Contents/`), whose main executable is for iOS on arm64 (`LC_BUILD_VERSION` platform `IOS`, not the Simulator). Libraries are static, or frameworks and dylibs inside it; app extensions, nested apps and other programs are refused. Frontport sets its bundle ID and signs it for each Device. Nothing else in `$FRONTPORT_OUT` is taken: Build Assets for an iOS version aren't supported yet.

To run an iOS Recipe end to end through the Builder (network, Xcode with the iOS platform, a few minutes):

```sh
cd FrontportKit
FRONTPORT_NETWORK_TESTS=1 FRONTPORT_RECIPE=fallout-ce-ios swift test --filter DeviceRecipeIntegrationTests
```

`FRONTPORT_RECIPE_ROOT` and `FRONTPORT_RECIPE_REF` work as above. The test also checks the app against the entry and the points above, as the Device Packager will: iOS on arm64, an SDK before 27 unless it has a scene manifest, the Info.plist keys and versions, its icons, and no code besides its executable but libraries.

## Recipes

| Recipe | Upstream | Tested ref | `buildAssets.path` |
|---|---|---|---|
| `starship.sh` | [HarbourMasters/Starship](https://github.com/HarbourMasters/Starship) | `v2.0.0` | `Contents/Resources/sf64.o2r` |
| `zelda3.sh` | [snesrev/zelda3](https://github.com/snesrev/zelda3) (no macOS Release) | `45a149d8b4bb8098f53d1009f76e76e7d8b79bbf` | `Contents/Resources/zelda3_assets.dat` |
| `smw.sh` | [snesrev/smw](https://github.com/snesrev/smw) (no macOS Release) | `eae20c65c58930c8b62c76188d259579ad4130f1` | `Contents/Resources/smw_assets.dat` |
| `sm.sh` | [snesrev/sm](https://github.com/snesrev/sm) (no Releases), run as its own code only | `578f90b3cc49557bb70060ad033bb90b8cf8ac50` | `Contents/Resources/sm.smc` (the ROM itself) |
| `opengoal.sh` | [open-goal/jak-project](https://github.com/open-goal/jak-project) (its macOS Release is bare tools), for `opengoal-jak1`, `opengoal-jak2` and `opengoal-jak3` | `v0.3.9` | `Contents/Resources/data/out/<game>` (a folder) |
| `dethrace.sh` | [dethrace-labs/dethrace](https://github.com/dethrace-labs/dethrace) (its macOS app ships without SDL), for `dethrace` and `dethrace-splat-pack` | `v0.10.1` | none: the game's folder is a Runtime ROM |
| `fallout-ce.sh` | [alexbatalov/fallout1-ce](https://github.com/alexbatalov/fallout1-ce) (its macOS app plays from the folder it sits in) | `0609bcfd0ec40ff0571d0f57fab2821eb461dc8b` | none: the game's folder is a Runtime ROM |
| `opengothic.sh` | [Try/OpenGothic](https://github.com/Try/OpenGothic) (its macOS Release is a bare executable), with glslang 16.6.0 | `v0.92` | none: the game's folder is a Runtime ROM |
| `xash3d.sh` | [FWGS/xash3d-fwgs](https://github.com/FWGS/xash3d-fwgs) (only rolling builds, no app), with [FWGS/hlsdk-portable](https://github.com/FWGS/hlsdk-portable)'s `master`, `opfor` and `bshift` branches pinned in the Recipe, for `xash3d-half-life`, `xash3d-opposing-force` and `xash3d-blue-shift` | `a7becfdf8d134eb2ae5cd083a45c816e6b4e42fc` | none: the Steam game folders are Runtime ROMs |
| `fallout-ce-ios.sh` | [alexbatalov/fallout1-ce](https://github.com/alexbatalov/fallout1-ce)'s iOS version (its `.ipa` has no digest), for `fallout-ce`'s `ios` | `0609bcfd0ec40ff0571d0f57fab2821eb461dc8b` | none: the game's folder is Seeded into `Documents` |
| `fallout2-ce.sh` | [alexbatalov/fallout2-ce](https://github.com/alexbatalov/fallout2-ce) (its macOS app plays from the folder it sits in) | `e97087b9582f37075db347a89898887320753f8b` | none: the game's folder is a Runtime ROM |
| `arcanum-ce.sh` | [alexbatalov/arcanum-ce](https://github.com/alexbatalov/arcanum-ce) (no Releases; its macOS app plays from the folder it sits in), with SDL3 3.4.8, SDL3_mixer 3.2.2, zlib 1.3.2 and fpattern 1.9.1 | `a7ff41b300ef712f0e7d088183a3d08957110cdd` | none: the game's folder is a Runtime ROM |
| `dhewm3.sh` | [dhewm/dhewm3](https://github.com/dhewm/dhewm3) (no macOS Release), with SDL2 2.32.10 and OpenAL Soft 1.25.2, for `dhewm3-doom-3` and `dhewm3-resurrection-of-evil` | `1.5.5` | none: the Steam game folders are Runtime ROMs |
| `rbdoom3bfg.sh` | [RobertBeckebans/RBDOOM-3-BFG](https://github.com/RobertBeckebans/RBDOOM-3-BFG) (no macOS Release), with MoltenVK 1.4.2, DXC v1.9.2609, SDL2 2.32.10, OpenAL Soft 1.25.2 and a prebuilt ISPC 1.32.0 | `ea29c006e84fedcc0e7c173c383a087ce0a8c0d5` | none: Steam's `base` folder is a Runtime ROM |
| `opensupaplex.sh` | [sergiou87/open-supaplex](https://github.com/sergiou87/open-supaplex) (its macOS Release's frameworks don't sign), with SDL2 2.32.10, SDL2_mixer 2.8.2 and libxmp-lite 4.7.3 | `v7.2.2` | none: the freeware game's files ship in the app |
| `render96ex.sh` | [Render96/Render96ex](https://github.com/Render96/Render96ex)'s `alpha` branch (no Releases, and its Makefile wants Homebrew's GCC and GNU binutils), with SDL2 2.32.10, GLEW 2.3.1, Render96's model pack 3.25 and HD texture pack | `f6e9e1b54f43b2caeffcf71644c6165f2652948c` | `Contents/Resources/res/base.zip` |
| `cannonball.sh` | [djyt/cannonball](https://github.com/djyt/cannonball) (Windows Releases only), with SDL2 2.32.10 and Boost 1.88's headers | `27493ebf62be3498dff93ed6a45e8e2db819bae1` | none: the arcade ROMs are a Runtime ROM |
| `openlara.sh` | [XProger/OpenLara](https://github.com/XProger/OpenLara) (no Mac Release; its Xcode project's app plays from the folder it sits in), compiled with clang, no dependencies | `3b268ca4bf986c380f44a26ffd9218bf6d376249` | none: Steam's Tomb Raider folder is a Runtime ROM |
| `uqm.sh` | [sc2/uqm](https://sourceforge.net/p/sc2/uqm/) through its GitHub copy [0xDEC0DE/sc2-uqm](https://github.com/0xDEC0DE/sc2-uqm) (its Mac Release is Intel-only), built with upstream's `build.sh` against SDL2 2.32.10, libogg 1.3.6, libvorbis 1.3.7 and libpng 1.6.59 | `199e3748cc41b688a65601e3b7b2a74bdb2c917c` | none: the freeware content packages ship in the app |
| `openttd.sh` | [OpenTTD/OpenTTD](https://github.com/OpenTTD/OpenTTD) (its Release is a signed universal DMG without the base sets), built with upstream's CMake against xz 5.8.4 and libpng 1.6.59 | `15.3` | none: OpenGFX 8.0, OpenSFX 1.0.3 and OpenMSX 0.4.2 ship in the app |
| `perfect-dark.sh` | [fgsfdsfgs/perfect_dark](https://github.com/fgsfdsfgs/perfect_dark)'s `port` branch (only a rolling CI build, with SDL2.framework loose beside the executable), with SDL2 2.32.10 | `a4b58e6dd14d5842d588e9841efa8bceb8b86fc3` | `Contents/Resources/data/pd.ntsc-final.z64` (the ROM itself) |
| `innoextract.sh` | [dscharrer/innoextract](https://github.com/dscharrer/innoextract), an unpack Recipe for Inno Setup installers such as GOG's | `6e9e34ed` (with Boost 1.88 and xz 5.8.4) | none: it unpacks, and GOG's `supportData` copies run after |
| `iso.sh` | none: the bsdtar macOS ships, an unpack Recipe for a PC Game's CD image (ISO 9660) | none to pin | none: it unpacks the disc's files into one folder |
