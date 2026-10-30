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
| `DEVELOPER_DIR`, `SDKROOT` | The active developer directory and its macOS SDK, so compilers run without the `xcrun` shims. |
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

## Recipes

| Recipe | Upstream | Tested ref | `buildAssets.path` |
|---|---|---|---|
| `starship.sh` | [HarbourMasters/Starship](https://github.com/HarbourMasters/Starship) | `v2.0.0` | `Contents/Resources/sf64.o2r` |
| `zelda3.sh` | [snesrev/zelda3](https://github.com/snesrev/zelda3) (no macOS Release) | `45a149d8b4bb8098f53d1009f76e76e7d8b79bbf` | `Contents/Resources/zelda3_assets.dat` |
| `smw.sh` | [snesrev/smw](https://github.com/snesrev/smw) (no macOS Release) | `eae20c65c58930c8b62c76188d259579ad4130f1` | `Contents/Resources/smw_assets.dat` |
| `opengoal.sh` | [open-goal/jak-project](https://github.com/open-goal/jak-project) (its macOS Release is bare tools), for `opengoal-jak1`, `opengoal-jak2` and `opengoal-jak3` | `v0.3.9` | `Contents/Resources/data/out/<game>` (a folder) |
| `dethrace.sh` | [dethrace-labs/dethrace](https://github.com/dethrace-labs/dethrace) (its macOS app ships without SDL), for `dethrace` and `dethrace-splat-pack` | `v0.10.1` | none: the game's folder is a Runtime ROM |
| `fallout-ce.sh` | [alexbatalov/fallout1-ce](https://github.com/alexbatalov/fallout1-ce) (its macOS app plays from the folder it sits in) | `0609bcfd0ec40ff0571d0f57fab2821eb461dc8b` | none: the game's folder is a Runtime ROM |
| `innoextract.sh` | [dscharrer/innoextract](https://github.com/dscharrer/innoextract), an unpack Recipe for Inno Setup installers such as GOG's | `6e9e34ed` (with Boost 1.88 and xz 5.8.4) | none: it unpacks, and GOG's `supportData` copies run after |
| `iso.sh` | none: the bsdtar macOS ships, an unpack Recipe for a PC Game's CD image (ISO 9660) | none to pin | none: it unpacks the disc's files into one folder |
