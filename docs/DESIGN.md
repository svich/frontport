# Frontport design

Status: agreed design, first implementation (2026-10-24). Vocabulary is defined in [GLOSSARY.md](../GLOSSARY.md); decisions with lasting trade-offs are in [docs/adr](adr/).

## Goal

Frontport is a native macOS app (SwiftUI) that installs, updates and launches Ports: Mac versions of Games made by decomp, recomp, recreation and sourceport Projects. Every Port runs inside the macOS App Sandbox, the same isolation App Store apps get, without needing an Apple developer account for each Port ([ADR 0001](adr/0001-sandbox-ports-by-ad-hoc-resigning.md)).

## Scope

v1 covers:
- the curated Catalog, with prebuilt and source-built Ports
- ROMs, Frontport's store of the user's ROMs
- installing, updating, Rollback and uninstalling
- Permissions
- Snapshots
- run logs

Deferred:
- mods
- importing the Quiver catalog (see [Deferred](#deferred))
- syncing Data between Macs
- a Library on external drives

Not planned:
- telemetry
- distributing ROMs or Assets
- Mac App Store distribution of Frontport

## Frontport app

- **Signing and distribution:** unsandboxed, Developer ID signed and notarized. It has to run builds, re-sign Ports and write into their containers, which a sandboxed app can't do.
- **Requirements:** Apple silicon only, macOS 26 or later.
- **Hardened runtime:** on whenever Frontport is signed with a Developer ID, for the app and `frontport-primer` together. Builds without one are signed ad-hoc and leave it off in every configuration, because the runtime's library validation rejects ad-hoc nested code such as Sparkle (see [Signing and Permissions](#signing-and-permissions)). `App/Signing.xcconfig` holds this, and a git-ignored `App/Signing.local.xcconfig` sets the identity and team. Release builds never carry `get-task-allow`.
- **Self-updates:** Sparkle, with a signed update feed. It starts only when Info.plist carries `SUPublicEDKey`, so development builds never show a Sparkle error.
- **Releases:** [`scripts/release.sh`](../scripts/release.sh) checks the Developer ID identity, the notarytool profile, the Sparkle key and Info.plist before building, then archives and exports for Developer ID, verifies the signature and the hardened runtime, notarizes, staples, and adds the release to the Sparkle appcast. The one-time setup is in [`scripts/README.md`](../scripts/README.md).
- **Update checks:** only while Frontport is open, at launch and every 6 hours. No background helper and no login item. Each check refreshes the Catalog, enforces Blocks right away, then discovers Releases and refreshes artwork. A failed Catalog refresh is logged and the cached Catalog kept.

### Components

```
Frontport.app (unsandboxed)
├── Catalog     fetch and verify the signed Catalogs, Frontport's own and added ones
├── Releases    discover upstream Releases per Channel, apply Blocks
├── Fetcher     download Release assets and verify GitHub's sha256 digest
├── Builder     run Recipes in the build sandbox
├── ROMs        ROM intake, standardization, hashing
├── Packager    set the bundle ID, link Build Assets and Redirects, sign inside-out
├── Library     Installations, updates, Rollback, Snapshots, uninstall
├── Launcher    launch Ports, capture run logs
└── Artwork     fetch and cache SteamGridDB artwork

Port .app (ad-hoc signed, App Sandbox) -> its Data: ~/Library/Containers/<bundle-id>/Data
```

Each component is a module in the `FrontportKit` Swift package that depends only on `FrontportCore`, which holds the shared types and the service protocols. The Library reaches the others only through those protocols. The app target holds the SwiftUI screens and an `AppModel` that wires the real services together. `Frontport.app/Contents/MacOS/frontport-primer` is the [container primer](#lifecycle).

A Port's Status, a value in `FrontportCore`, says what the Port is doing or needs and what the user can do with it now: the action its state calls for, the others to offer, the ways off a Blocked Release, and for any action whether it's allowed, disabled and why, or unavailable. Every screen renders it and every `AppModel` action checks it, so a button and what it runs never disagree. Two rules hold changes back: one change at a time, and a change to the app or its Data waits for the Port to quit. Seeding is never refused for either; it waits its turn.

A Port's Activities run through one module in `FrontportCore`, `Activities`: each change shows as the Port's Activity from when it starts until the Port's state is reloaded after it, with its progress (newest only) and any Seeding failure it reports. A change asked for during another, such as Seeding for ROMs added during an update, waits its turn and then runs as an Activity of its own, so nothing the Library does runs unseen; Cancel stops the change under way and drops those waiting. The App says what each change does and how it ends, and the module is tested with work that waits for the test.

The Lineup, a value in `FrontportCore`, is the Catalog as the Library sees it: the Ports to install and the Unsupported ones by Platform, Genre and Game, New Ports, the Port of the Day, search, Projects and the Releases worth showing. The Survey makes it once whenever the Catalog, the Library, the known Releases or the first installs under way change, and every Catalog screen reads its answers; the UI tests check the screens against it.

The Survey, one module in `FrontportCore`, holds what Frontport last found: the Catalog, the Library with stand-in entries for Installations the Catalog doesn't list, where every Requirement stands, each Port's newest Release and what it offers the Installation, and the Lineup. It reads them through the service protocols at launch (`load`, no network), on each update check (`refresh`: the Catalog, its Blocks, the Library, then every Port's Releases), after each Activity (the Library, and the Port's Releases when its Release or Channel changed) and when ROMs or a quit Port's Data may have changed. A failed Release lookup keeps what was known, a Matching read overtaken by a later one is dropped, and a check counts once the Catalog or any lookup was reached. It is tested over in-memory services; the App holds one, and views read it directly.

A Move, also a value in `FrontportCore`, is the one rule for an Installation going from its Release to another: none, forward or back. The Library moves by it and the App predicts with it, so a confirmation never says what the Library won't do. It also says what to offer an Installation from the newest Release on its Channel (an Update, or a Fallback off a Blocked Release), which Snapshot a back Move brings back, and which Snapshot a Move took. How a back Move runs, through `previous/` or by fetching the Release again, stays with the Library, which alone reads the disk.

### On-disk layout

```
~/Library/Application Support/Frontport/
├── Catalog/              cached signed Catalog
│   ├── recipes/          its Recipes, each checked against its sha256
│   └── releases/         cached GitHub responses (ETags)
├── Catalogs/             the Catalogs the user added
│   ├── added.json        each one's URL and pinned public key, in the order added
│   └── <id>/             one's cache, laid out like Catalog/
├── ROMs/                 ROM files in standard form, named by hash
│   └── index.json        a record of each ROM
├── Downloads/<port>/     a Release's asset until that Release is installed
├── Toolchain/<version>/  cmake and ninja
├── Builds/<port>/        a Recipe's working folder, which its build step may write anywhere in
│   ├── src/              the source tree, kept while the ref and Recipe stay the same
│   ├── out/              the .app and Build Assets the build leaves, until they're packaged
│   ├── tmp/              the steps' tmp folder, with an empty HOME, only during the build
│   ├── roms/             the Build-Stage ROMs, only during the build
│   ├── prefix/           libraries the Recipe builds, kept between builds
│   └── state.json        the ref and Recipe the source tree was fetched for
├── Snapshots/<port>/     last 3 Snapshots of the Port's Data
├── Logs/<port>/          last 5 run logs, each with its Run record, and the last build's build.log
├── Artwork/<id>/         cached SteamGridDB artwork per SteamGridDB game ID
└── Library/<port>/
    ├── <Port>.app        the current Release
    ├── assets            its Build Assets, a file or folder the app links to
    ├── previous/         the previous Release, its assets and its install.json, kept for Rollback
    ├── staging/          a new Release while it's packaged
    ├── blocked/          the app, moved aside by a stop Block
    └── install.json      Installation record

~/Library/Containers/dev.frontport.port.<port>/Data/   the Port's Data, owned by macOS
```

The Library reads and changes `Library/<port>/` through one module, the Installation's folder, which keeps its parts in step so that whatever fails part way, `install.json` says what's there. The Build Assets go in just before the app and the record follows the app; should either fail, everything goes back. `previous/` follows the record, and is kept for Rollback only while it holds, whole, the Release the record says it does. A change of Release lifts a stop Block, so `blocked/` goes with it.

Build Assets go through one module too, which knows both places an Installation keeps them, beside the app or inside it. For a change of Release it decides whether they're carried forward or the Recipe makes them, and from which ROMs; once ROMs are added, whether they're made again, and it puts those in place itself, re-signing or packaging the app again when that's needed. Should that fail, the Installation stays as it was. The Library only runs the Recipe.

Every Move ends in one place once its app is ready and signed, whether it was fetched, built or kept in `previous/`: the Library chooses the Snapshot a back Move brings back, takes one of the Data as it is, swaps the app in and records it, brings the chosen Data back, prunes the Snapshots, then makes the folders the app's Redirects lead to and Seeds. The Snapshot to bring back is chosen before one is taken, so it's never the one just taken, and Data comes back only once the app it belongs to is in place. Restoring a Snapshot ends with the same last two steps.

## Catalog

The Catalog is a curated JSON document signed with Ed25519. Frontport has the public key built in, so rotating the key requires a Frontport update. Frontport fetches the Catalog during its update checks and rejects it if the signature doesn't verify, if its `version` isn't one Frontport supports, or if its `issued` date is older than the cached one, so a stale copy can't roll the Catalog back. A copy ships inside the app for the first launch.

**Added Catalogs** ([ADR 0012](adr/0012-add-catalogs-by-link.md)): the user can add other Catalogs in Settings › Catalogs, by the URL of the folder holding a `catalog.json`, or by a `frontport://add-catalog?url=…&key=…` link. Each is signed with its own key, pinned when it's added: from the link, or from `catalog.pub` beside the document. Frontport lints each document and refuses one with problems, reads no Catalog file past 4 MB, caches it in `Catalogs/<id>/`, refreshes it with its own, and keeps the cache when it can't be reached. Frontport reads every Catalog as one, its own first: the first to list an id keeps it. Each entry carries the URL of the Catalog that lists it, and an Installation keeps it, so a Port takes updates, Blocks and Recipes only from the Catalog it was installed from, and another Catalog listing its id can't take over its Data. An added Catalog's installers unpack in workspaces of their own. Frontport's own Catalog lists no Switch Ports: they're in a Catalog of their own.

The source lives in [`catalog/`](../catalog/), with the sources for every ROM hash and upstream fact in its README. The `frontport-catalog` tool generates keys, checks and signs the Catalog, and bundles it into the app. The repository's key is a development key.

The document holds `platforms` (each with the `medium` its Games come on: `cartridge`, `iso` or `file`), `games`, `roms` (the known ROMs with their names, and a `type` of `update` or `dlc` for a Game's update or DLC) and `ports`. A prebuilt entry:

```json
{
  "id": "2ship",
  "name": "2 Ship 2 Harkinian",
  "kind": "decomp",
  "game": "majoras-mask",
  "developer": "HarbourMasters",
  "summary": "…", "description": "…",
  "website": "…",
  "source": "https://github.com/2ship2harkinian/2ship2harkinian",
  "bundleId": "dev.frontport.port.2ship",
  "releases": {
    "type": "github-release",
    "repo": "2ship2harkinian/2ship2harkinian",
    "asset": "2Ship-*-Mac.zip",
    "channels": ["stable"]
  },
  "requirements": [
    {
      "label": "Majora’s Mask",
      "stage": "runtime",
      "oneOf": ["<sha1 of standard form>", "…"],
      "extras": ["<sha1>"],
      "seedPath": "Library/Application Support/com.2ship2harkinian.2s2h/"
    }
  ],
  "permissions": { "network": false, "controllers": true, "files": false },
  "artwork": { "steamgriddb": 5453061, "fallback": 34302 },
  "codeSigning": { "exceptions": [] },
  "launch": { "arguments": [], "environment": { "SHIP_HOME": "~/Library/Application Support/com.2ship2harkinian.2s2h" } },
  "strip": [],
  "blocked": [{ "release": "5.0.0", "severity": "warn", "reason": "…" }],
  "screenshots": [],
  "tags": ["randomizer"]
}
```

- **`seedPath`:** relative to Data. A path ending in `/` is a folder that receives each ROM as `<sha1>.<format>`; otherwise it's the exact file, or for a folder ROM the folder its files go in.
- **`launch`:** arguments and environment for the Launcher. `SHIP_HOME` is needed because upstream sets it through `LSEnvironment`, which a direct launch doesn't apply.
- **`strip`:** paths under `Contents/` removed before signing, such as sm64coopdx's self-updater, which would replace an app in /Applications.
- **`artwork.fallback`:** the Game's SteamGridDB ID, used when the Port has no entry of its own.
- **`redirects`:** `[{ "path": "Contents/Resources/…", "to": "Library/Application Support/…" }]`, links from paths inside the app to folders in the Port's Data, for a Port that writes beside its executable, such as OpenGOAL's `data/log` (see [Redirects](#redirects)). Optional.

A source-built entry pins its refs and names its Recipe, whose sha256 the signature covers:

```json
"releases": {
  "type": "git",
  "repo": "HarbourMasters/Starship",
  "refs": { "stable": "v2.0.0" },
  "recipe": "recipes/starship.sh",
  "recipeSHA256": "<sha256>"
},
"buildAssets": { "path": "Contents/Resources/sf64.o2r", "format": "1" }
```

with a Build-Stage Requirement whose Assets the Port reads at `buildAssets.path`. `format` is an opaque string; a Recipe change that alters the Assets bumps it, which makes updates regenerate them.

An Unsupported Port carries `"unsupported": "<reason>"`. It's listed in the Catalog but can't be installed ([ADR 0002](adr/0002-no-unsandboxed-fallback.md)).

- **Ids:** a Port's `id` is lowercase letters, digits and hyphens, and its `bundleId` is always `dev.frontport.port.<id>`. They name the Port's folders and its container, so `frontport-catalog` refuses anything else, and so does the Library, whatever the Catalog says.
- **`bundleId`:** it ties a Port to its Data, so it never changes.
- **`roms`:** every ROM listed is accepted by some Requirement, since intake accepts only those.

## Screens

- **Sidebar:** search, then Catalog, Library, Releases and ROMs, then every installed Port by its Game, with its Project and a status icon (update, running, needs ROM or ROM not Seeded, building).
- **Launch:** Frontport opens on the Library when it has Ports, and on the Catalog when it's empty.
- **Catalog:** only Ports that aren't installed: a Port of the Day hero, New Ports, every Platform, Genre and Project, then All Games. Nothing installed, and nothing time-based beyond the Port of the Day and New Ports. People look for a Game, so the Catalog lists Games and names each Port's Project beside it.
  - **Port of the Day:** the installable, not-installed Port with the highest SHA-256 of `<local date>/<id>`, so it holds all day and installing another Port doesn't change it. Its hero art keeps its 1920×620 shape, so it's never cropped. It's titled with its Game, with its Project and, for a Game with several Ports, "1 of 2 Ports".
  - **New Ports:** the 3 Ports to install whose first Release is newest, leaving out the Port of the Day. All opens New Ports on the Releases screen.
  - **Game cards:** All Games and the Platform and Genre pages show each Game with Ports to install as a card, by name. A chip per Port names its Project and latest version and opens the Port's store page. The card opens the Game page when the Catalog has more than one Port of the Game, and the store page of its one Port otherwise.
  - **Platform page:** one per Platform, reached from the Catalog and the store page. Its Game cards, then its Unsupported Ports.
  - **Genre page:** the same for one Genre, reached from the Catalog. A Game with two Genres shows on both pages.
  - **Projects:** a Project is the Ports whose `releases.repo` is the same repository, so the Catalog needs no field for it. A tile per Project opens its page.
  - **Catalog fields:** `genres` lists the Genres; each Game names its own, main one first, and each entry has the date of its `firstRelease` upstream.
- **Game page:** one per Game the Catalog has more than one Port of. Its art and Platform, then a tile per Port with its Project, developer, Kind, summary, Pills, a link to its store page and the action its state calls for, so the Ports can be compared side by side.
- **Store page:** one per Catalog entry, reached from the Catalog, Releases and the Port page. It's about one Port: titled with its Game, with its Project linking to the Project page.
  - **Other Ports:** when the Game has other Ports, a note names them, with See All Ports opening the Game page.
  - **Content:** screenshots, a description, the Project, the latest Release, Platform, source, website, Permissions, accepted ROMs and system requirements.
  - **ROMs:** what files the Port needs, beside the system requirements: a row per Requirement and extra with its Type, the files it's added from (such as `.nsp, .xci, .nsz or .xcz`, since a Switch game's contents identify it, an NSZ or XCZ kept Unverified, or `folder or .exe` for a folder an installer holds), the versions accepted, counted past two, and whether ROMs has one. A row opens to each accepted ROM, and each installer the Catalog knows that holds one, with its SHA-1 to copy, to check a dump against.
  - **Action:** Install, Add ROM… or Play, depending on state, naming every ROM still missing when the Port needs more than one. Add ROM… is black on yellow everywhere it shows, like a warning sign, since the Port can't go on without its ROM.
  - **Leftover Data:** while a Port that isn't installed still has Data or Snapshots, its store page offers Delete Data….
  - **No donate buttons:** none of the Ports checked accepts donations.
  - **Catalog fields:** this adds a description, screenshot URLs and the website to each entry. Screenshots come from each project, with its permission, not from SteamGridDB.
- **Project page:** what the Project is, its details, its Games as cards, and its Releases, newest first, marking the latest and the one each Library Port has. When a Release updates Library Ports, a banner offers Update for all of them.
- **Library:** installed Ports as a grid or a list.
  - **Not in the Catalog:** an Installation the Catalog no longer lists stays, marked "Not in the Catalog", with the entry its `install.json` kept, so it can still be played, re-signed, rolled back, uninstalled and have its Data deleted.
- **Releases:** New Ports and Updates in a toolbar picker.
  - **New Ports:** every Catalog Port by the year of its first Release, newest first.
  - **Updates:** one card per Project with an update, listing each Library Port it updates with Update for all of them, then every other Catalog Release, once per Project and version, grouped by month. Each shows a short summary of its upstream release notes and links to them.
- **ROMs:** what installed Ports still need (ROMs to add, or to Seed), what's been added, and Add ROMs….
- **Port page:** Overview, Snapshots and Runs in a toolbar picker, with a link to its store page.
  - **Storage:** a row per folder the Port has on disk, with its size, what it holds and Open, which opens it in Finder: Data with Delete Data…, Snapshots, the Installation (its app, Build Assets and previous Release) with Uninstall…, and, for a source-built Port, the build folder with Remove…. A file cloned elsewhere, such as a game a Recipe extracted into the Build Assets, frees nothing when the folder goes, so the build folder's row also says how much removing it frees: what APFS reports no other file shares (`ATTR_CMNEXT_PRIVATESIZE`). The store page of a Port that isn't installed shows the same section while anything is left over.

## Artwork

Covers come from [SteamGridDB](https://www.steamgriddb.com):
- **Lookup:** each Catalog entry pins a SteamGridDB game ID, so Frontport never guesses by name. It uses the Port's own entry when there is one (most Ports have one), and otherwise the Game's.
- **Where each kind goes:** a landscape grid on Library tiles and Catalog cards, the hero and logo on the Port page header, and the icon in the sidebar. Game cards and the Game page show the Game's own grid, from its `steamgriddb` id, and Project tiles and update cards show the Games' icons.
- **Caching:** Frontport caches artwork in `Artwork/` with the asset ID and author for the credit, and re-fetches artwork older than 7 days during update checks. An empty answer is cached too.
- **API key:** the user's own SteamGridDB key, entered in Settings and kept in the Keychain. Without one Frontport never calls the API and shows only cached artwork or the fallback. While Frontport is signed ad-hoc, the Keychain item is tied to each build, so a rebuild asks for Keychain access again.
- **Fallback:** without artwork, a flat color with the Game's name. The color comes from a hash of the Game ID, so it's stable.
- **Terms:** SteamGridDB allows only personal, non-commercial use, and no automated use of the site. So each Mac fetches artwork for its own Library through the v2 API, Frontport never bundles or rehosts it, and the UI credits SteamGridDB.
- **Naming:** call these artwork, never Assets, which are ROM-derived files.

## Releases

- **Prebuilt Ports:** the Catalog pins the repository, the asset pattern and the Permissions, but not versions. Frontport discovers Releases upstream for each Channel and verifies every download against GitHub's sha256 asset digest ([ADR 0003](adr/0003-discover-releases-upstream.md)). A Release whose asset has no digest is listed but never offered, since it can't be verified.
- **Channels:** `stable` follows full Releases and any other Channel also includes prereleases, unless the entry gives a tag glob for every Channel. None of the current Ports publishes prereleases, so every entry offers only `stable`.
- **Asset patterns:** a glob that must match exactly one macOS asset, for example the arm64 zip where a Port also ships an Intel one.
- **Discovery:** GitHub's REST API without a token, with responses cached by ETag so checks every 6 hours stay within the rate limit.
- **Order:** one rule for discovery, updates and Rollback: by creation date, as GitHub orders Releases, so publishing an old draft later doesn't make it the newest; else by publication date, else by version number.
- **Source-built Ports:** these follow refs pinned in the Catalog, because an untested tag can break a Recipe. Any other pinned ref counts as an update: moving to the ref the Catalog pins for the Installation's Channel always takes the update Snapshot and keeps the current ref in `previous/`, whatever the order above says, since pinned refs often have no dates and commit hashes don't compare as versions. That holds even when the new pin is the ref `previous/` held. Only a move to a ref that isn't the current pin, such as another Channel's, can be older.
- **Updates:** a newer Release on the Installation's Channel: a forward Move to it.
- **Prebuilt first:** Frontport builds from source only when the Catalog says so, meaning there is no usable macOS Release or the Port has a Build-Stage Requirement.
- **Blocks:** a Blocked Release is never offered. Its severity decides what happens to an Installation already on it:
  - **warn:** Frontport shows a warning and offers an update or Rollback.
  - **stop:** Frontport disables the Installation by moving the app aside, so even launches from the Dock or Finder fail. Updating or rolling back restores it.
  - **The way off:** with no update and no previous Release that isn't Blocked, Frontport offers the newest Release that isn't Blocked, even an older one, after asking: the Fallback. An older one is installed like a switch to an older Release (see [Lifecycle](#lifecycle)).

## ROMs

- **Intake:** Frontport converts every ROM to its standard form (N64 → `.z64` byte order; SNES → 512-byte copier header stripped; NES → iNES header stripped; disc images and Doom engine `.wad`, `.pk3` and `.ipk3` files as they are), hashes it with SHA-1, and accepts it only if a Catalog Requirement lists that hash and `roms` names it. Anything else is shown with its hash, and ROM hacks aren't accepted unless the Catalog lists them, but the user can keep it Unverified (below). A zip holding one ROM is unpacked first. The Catalog says in one place what a hash is: an installer, a ROM a Requirement accepts, with its Type, or nothing. Intake, the ROMs screen and the store page all read it there, so a ROM shows the same Type everywhere: the format the Catalog lists decides, not the one it was stored in.
- **Unverified** ([ADR 0011](adr/0011-keep-unlisted-files-unverified.md)): a file whose hash the Catalog doesn't list, such as an NSZ, a dump a tool made from an XCI, or another revision, can be kept as a ROM the user chooses, from those some Requirement accepts in its format (any Switch container for a Switch game; never keys, firmware or an Installer). Its record keeps the chosen ROM's SHA-1 as `sha1`, so everything treats it as that ROM, and its own as `ownSHA1`, which the ROMs screen shows with the mark Unverified. A listed ROM added later takes its place. A wrong one shows only when the Port builds or runs.
- **Folders** ([ADR 0007](adr/0007-take-a-pc-game-as-a-folder.md)): a PC Game comes as a folder of files, added as the folder or its zip (one holding several files and no ROM). Its hash is the SHA-1 of `shasum`'s `<sha1>  <path>` lines for its files, sorted by path, leaving out hidden files, a zip's `__MACOSX` and the folders that only wrap it. A link or special file in it is refused. ROMs keeps exactly those files as `ROMs/<sha1>.folder`.
- **Installers** ([ADR 0008](adr/0008-unpack-installers-in-the-build-sandbox.md)): a file whose hash is a `KnownROM` with an `unpack`, such as GOG's Carmageddon Max Pack installer or Fallout's CD image, is unpacked by the Recipe it names, in the build sandbox, in `Builds/unpack-<recipe>/`. Frontport hashes each folder it leaves as a folder ROM and adds the ones the installer `yields`, one result each; neither the installer nor anything else it held is kept. Each ROM in ROMs is a clone of what the unpack left, so that would otherwise keep its space taken even once the ROM is removed.
- **Switch files** ([ADR 0006](adr/0006-identify-switch-files-by-content.md)):
  - **NSP and XCI:** kept as they are, and identified by their NCAs: each is checked against its content ID (the first half of its SHA-256), and the hash is the SHA-1 of the sorted content IDs but the meta NCA's, one per line. The same NCAs in another dumper's container are the same ROM. One with a personalized ticket is refused, since only its console's own keys decrypt it. Nothing is decrypted: an NCA that doesn't match its content ID counts by its own hash, so a dump a tool made from an XCI gets a hash no ROM in the Catalog has, and can only be kept Unverified.
  - **NSZ and XCZ** ([ADR 0011](adr/0011-keep-unlisted-files-unverified.md)): nsz's compressed NSP and XCI, told by their NCZs, which count by their own hash, and kept compressed as `.nsz` and `.xcz`, Unverified. The Recipe decompresses them with nsz.
  - **Console keys** (`prod.keys`): reduced to the keys every console shares that decrypting games needs, five keys and sources then `master_key_00` onwards, so the console's own keys are never stored. Each count of master keys is one standard form; intake keeps the longest one the Catalog lists, so a console with newer firmware still matches. Their `KnownROM` names the Platform instead of a Game.
- **Links:** a link the user adds is followed once, to the file or folder it leads to. Anything but a regular file or a folder is rejected, and the user's file is never changed.
- **Types:** the Catalog marks a Game's update or DLC with its `KnownROM`'s `type`, since nothing in the file tells it from the Game itself without console keys. Otherwise a Platform's `.keys` is a Key and its other files Firmware; a Game's folder is a Folder, its `.iso` an ISO, and any other ROM of it takes its Platform's `medium`: a Cartridge (an N64 `.z64`, a Switch NSP or XCI), an ISO or a File (a Doom IWAD, a GOG installer). A Game the Catalog no longer lists is a File. The ROMs table shows it, with the format on hover, and a ROM of no Game shows its Type's symbol in place of artwork.
- **Kept:** every accepted ROM stays in ROMs, read-only, so builds, Asset regeneration and updates never ask for it again.
- **Requirements:** a Requirement is met by its Match: the accepted ROM it prefers among those in ROMs, with the extras there.
  - **Build Stage:** the ROM is fed to the Recipe's build step. The installed Port never sees it.
  - **Runtime Stage:** the ROM is Seeded into the Port's Data.
- **Matching:** one module in FrontportROMs, reached through `ROMStoring`, says where each Port's Requirements stand and does the Seeding, so the two never disagree. One reading of ROMs and the installed Ports' Data gives each ROM of each Requirement a state: missing, in ROMs, built in (the Installation's Build Assets were made from it, whether or not it's still in ROMs), Seeded or not Seeded. A Build Requirement that's built in isn't missing: the Port runs without its ROM, and only a rebuild asks for it again. The same reading says whether an update can carry the Build Assets forward (same `format`, made from every Build Match's ROM) and which Ports would ask for a ROM again were it removed. The Library decides when to Seed; Matching decides what and how. The index in `ROMs/` is the truth: a record whose file is gone is dropped when it loads.
- **Seeding:**
  - **How:** an APFS clone (`clonefile`) of the ROM in ROMs is placed at the entry's `seedPath`, so it costs no extra disk space and the Port can't modify the copy in ROMs. The seeded copy is writable by the Port; a write splits only the blocks it touches. A different volume falls back to a normal copy.
  - **Seeded files** ([ADR 0010](adr/0010-tag-seeded-files.md)): each file Seeding places is tagged with an extended attribute, `dev.frontport.rom`, naming its ROM's SHA-1 (an Unverified ROM's own), so checking it costs no hashing. A file without the tag is compared with the copy in ROMs once, and tagged when it's the same. At a file `seedPath`, another accepted ROM there gives way to the Match, as the full Ultimate Doom replaces the shareware IWAD at `doom.wad`. In a `seedPath` folder, where each ROM has its own name, the others stay.
  - **Folders:** created with mode `700`, which macOS doesn't set by itself.
  - **Folder ROMs:** filled in rather than replaced: each of the ROM's files missing at the `seedPath`, in any form, is cloned in, and everything already there is left alone, since a PC Game keeps its options and saves among its files. A `.frontport-rom` marker names the ROM a folder was filled from; a folder filled from another ROM (a demo, before the full game) is renamed to `<name> (<hash's first 8>)` first, so releases never mix. A folder ROM counts as Seeded once its folder is marked as its own and none of its files is missing.
  - **Symlinks:** Seeding never follows a link, because the Port can put one anywhere in its Data and macOS puts links to the user's home folders (Desktop, Downloads and so on) there. It opens each folder on the path from the one before, refusing a link, and writes only relative to the open folder, so a folder swapped for a link afterwards can't redirect the write.
  - **When:** Seeding may happen before the Port's first launch, but never while the Port runs: ROMs added while it runs are applied once it quits. If Data was deleted, Frontport [primes](#lifecycle) the container first. The app keeps this rule in one value in `FrontportCore`, the Seeding wait: fed what happens to each Port (ROMs added or Try Again, the Library refusing, an Activity ending, a quit), it says what comes next. ROMs added during another change are Seeded after it, as an Activity of their own. macOS may still list a Port for a moment after it quits, and the Library then refuses: that's tried again after 1, 2, 4 and 8 seconds, then the ROMs wait for the next quit or Try Again.
  - **Failures:** after an install, update or Rollback the change is complete, so a Seeding failure is reported rather than failing it. Matching reports the ROMs still to Seed, the Port shows them as not Seeded until they are, and applying ROMs tries again. Nothing Seeds on its own when a reading finds a ROM not Seeded, such as after a Catalog update changes which ROM a Requirement prefers: the Port shows Try Again.
  - **Lifetime:** Seeded ROMs stay in Data and are never cleaned up automatically.
- **Extras:** an extra ROM added later is applied right away: Seeded for the Runtime Stage, or Assets regenerated for the Build Stage. Once the Catalog's Recipe makes Build Assets in another `format` than the installed ones, they're left to the next update, which regenerates them anyway: the installed app wasn't built for that format.
- **Removal:** removing a ROM from ROMs is allowed. Frontport first lists which Ports would ask for it again on an update that regenerates Assets. Installed Ports keep working.

## Assets

- **Build Assets:**
  - **Where:** made by a Recipe and kept beside the app, in `Library/<port>/assets`, so signing and first launch never read them ([ADR 0004](adr/0004-keep-build-assets-outside-the-app.md)). The Port reads them at the path the Catalog declares, through the Packager's link. They travel with the Release they were made for, into `previous/assets` and back.
  - **Updates:** an update clones them into the new Release if the ROM and the asset format haven't changed, and otherwise regenerates them from ROMs.
  - **Extras:** regenerated ones replace `Library/<port>/assets` and leave the app and its signature alone, unless they turn from a file into a folder or back, or were missing: the exception names one or the other, so the app is re-signed.
  - **Older Installations:** have them inside the app. Whether an app holds the Packager's link, not what's beside it, says which. The next update or extra moves them beside it, and a Rollback to such a Release moves only the app.
  - **Delete data:** leaves them alone.
- **Runtime Assets:** a Port that extracts its own Assets (for example 2Ship on first launch) keeps them in its Data.

## Redirects

A Redirect is a link the Packager puts at a path inside a Port's app, leading to a folder in that Port's own Data ([ADR 0005](adr/0005-redirect-app-paths-into-data.md)).
- **Link:** absolute and canonical, `<containers>/<bundleId>/Data/<to>`, since the app's depth differs in `staging/`, `previous/` and `blocked/`. No exception: the container is already the Port's writable home, and the sandbox checks where a link leads.
- **Folders:** a Redirect that leads nowhere fails the app's verification, so Frontport creates `Data/<to>`: the Packager whenever it packages or re-signs an app, the Library after every Move, right after Delete Data and after restoring a Snapshot, and the Launcher before each launch. They all go through one module, `PortData`, which finds the folders in the app's own links (or, before they're placed, the entry's Redirects), prepares Data first when it's gone, through the primer that each of them holds, and never follows a link there, opening each folder from the one before as Seeding does; a link or a file on the way is refused. Once a Move, Delete Data or a restore has changed Data, the change is already done, so a failure there is only reported: the Launcher tries again.
- **Policing:** `path` is inside `Contents/Resources/`, and clear of `buildAssets.path` and the other Redirects. Every component of `path`, `to` and `buildAssets.path` is plain ASCII (letters, digits, spaces, `.`, `_` and `-`, never `.` or `..`): the volume folds case and Unicode, so `Contentſ` would name `Contents`. Neither a Redirect nor `buildAssets.path` may sit at, above or inside a code location (`MacOS`, `Frameworks`, `PlugIns`, `XPCServices`, `Helpers`, `Library/LoginItems`) or `_CodeSignature`, `Info.plist`, `CodeResources` or `PkgInfo`, under the app's `Contents/` or a nested app's, compared without case: through a link there, the Port could swap in, from its Data, a program that runs unsandboxed. The lint checks this, and the Packager again. Re-signing finds Redirects in the app, by their destinations, not from the Catalog, and refuses one anywhere a Redirect may not be.

## Install and update pipeline

1. **Resolve:** pick the newest Release on the Installation's Channel that isn't Blocked and has a digest.
2. **Requirements:** satisfy them from ROMs, or ask the user to add a ROM. A missing Build-Stage ROM stops the install; a missing Runtime ROM doesn't, and is Seeded once it's added.
3. **Fetch:** for prebuilt Ports, download and verify the digest, then unpack it. The download stays in `Downloads/<port>/` until its Release is installed, so a failed change can try again without it. Upstream archives nest: a zip holding a disk image (2Ship, Ghostship), a zip inside a zip (Zelda64Recomp, Banjo) or a tarball. A disk image with a license agreement is converted before it's attached. For source-built Ports, run the Recipe in the [build sandbox](#build-sandbox).
4. **Package:** set `CFBundleIdentifier` to the entry's `bundleId`, remove upstream signatures, provisioning profiles and the entry's `strip` paths, clone the Build Assets beside the app as `assets`, put a link to them at `buildAssets.path`, and put each [Redirect](#redirects)'s link at its `path`, each in place of whatever is there. Every path must stay inside the app.
   - **Untrusted until signed:** an app that is a link, or holds a link leading out of it, is refused after unpacking, after building and again by the Packager itself, because Frontport runs unsandboxed and would follow it. Build Assets get the same check.
   - **The links out:** only the Packager's own. The one at `buildAssets.path` leads `../` once per path component, then to `assets`: relative, so it holds wherever the app is, in `staging/`, `Library/<port>/` or `previous/`. Redirects lead, absolute and canonical, into the Port's own Data, with no `..`; never another Port's. Upstream or a Recipe can't plant one: every check (after unpacking, after building, the Packager's before it places anything and after, re-signing, and on Build Assets) follows each other link from inside the app one component at a time, as `openat2`'s `RESOLVE_BENEATH` would, reading and expanding every link on the way from its own folder. It refuses the link when any text on the way is absolute, when `..` would climb above the app, when the way is or passes through one of the Packager's links, or after 40 links; the link must then also resolve inside the app. So a link shaped like a Redirect is refused, absolute or relative, and so is one that reaches the Port's Data through a Redirect or by climbing out through other links, even when it lands back inside the app through a link the Port left there, which the Port could retarget later. The Packager then lets through only the links it has just placed, with exactly those destinations. Re-signing finds them in the app by their destinations, not from the Catalog, which may have changed since: the app was packaged by Frontport and lives where the Port can't write, and each must still be exactly one of the Packager's shapes, from a path it may link. While a stop Block has the app aside, the link to the Build Assets leads nowhere.
5. **Sign:** see [Signing and Permissions](#signing-and-permissions).
6. **Snapshot:** on an update, take a Snapshot of the Data.
7. **Swap:** stage the new app and its Build Assets, and a copy of the current app and its Build Assets. Swap the new Build Assets in (or move the current ones out, for a Release without any), then atomically swap the new app in, putting the Build Assets back if that fails. Write `install.json`, and only then swap the copy in as `previous/`, so `previous/` never holds a Release `install.json` doesn't name. A new app name that differs only in case moves the current app aside first, since a case-insensitive volume treats both names as one.
8. **Seed** the Runtime ROMs.

`install.json` also keeps the entry the Port was installed from, so it can still be launched, re-signed and rolled back once the Catalog no longer lists it.

Launching goes through the Launcher, which creates the folders the app's Redirects lead to, then runs the app's executable directly with the entry's `launch` arguments and environment, and captures stdout and stderr into run logs (the last 5 per Port). When a cleaner app or Finder has removed the Port's Data, the Launcher makes it again first, as the Library does (the primer, or a plain folder before the Port's first launch): otherwise a Port like OpenGOAL's `gk` finds its log's link leading nowhere, fails to make the folder inside its bundle, and quits. The sandbox applies however a Port is launched, because it lives in the signature. A Port started from the Dock or Finder is still seen as running, and every change of Release, Permissions or Data is refused while it runs.

## Signing and Permissions

Frontport signs inside-out, never with `--deep`, which would stamp the app's entitlements onto every library. It finds nested code by its Mach-O magic, not by file extension:

```sh
codesign -f -s - -o runtime <each nested dylib and framework>
codesign -f -s - -o runtime --entitlements helper.entitlements <every other program, anywhere in the app>
codesign -f -s - -o runtime --entitlements port.entitlements Port.app
```

- **Library validation:** under the hardened runtime, an ad-hoc signed app can't load an ad-hoc signed library ("different Team IDs"). So Frontport adds `com.apple.security.cs.disable-library-validation` automatically to any Port that contains a library or framework. Keeping the runtime still blocks `DYLD_*` injection and gates JIT behind `allow-jit`; signing without it would lose both.
- **Nested executables:** every Mach-O program in the app, wherever upstream put it (helpers, nested apps, a tool in `Resources`), gets `app-sandbox` plus `inherit`, with the Catalog's exceptions. It then runs only when the sandboxed Port spawns it, and crashes if started any other way, so it can never run unsandboxed.

| Permission | Entitlement | Default |
|---|---|---|
| (always) | `com.apple.security.app-sandbox` | on |
| Network | `com.apple.security.network.client` | off |
| Files the user picks | `com.apple.security.files.user-selected.read-only` | off |
| Controllers | `com.apple.security.device.usb` | on |

- **Redirects** need no exception: they lead into the Port's own container.
- **Build Assets:** an app linking to them also gets one read-only exception, for `Library/<port>/assets` and never staging: `com.apple.security.temporary-exception.files.home-relative-path.read-only` with `/Library/Application Support/Frontport/Library/<port>/assets`, relative to the home folder so it names no user, and a trailing `/` for a folder. A Library outside the home folder gets `…absolute-path.read-only` with the canonical path. Either is canonicalized through `Library/<port>`, so a link planted at `assets` can't steer it. Nested programs don't get it: they inherit the app's sandbox. Re-signing keeps it.
- **Signer:** the Packager signs and verifies through a `Signer`: `codesign` in the app, and in the Library's tests one that records what it's asked, so those tests run the Packager's own checks and links rather than a stand-in's.
- **Verification:** `codesign --verify --strict` after signing. Only an app where the Packager placed the Build Assets link or a Redirect gets `--strict=sideband` instead, because `--strict`'s `symlinks` check rejects any link leading out of the bundle; when packaging, that's decided from the links it just placed, never from what's in the app. Dropping it also drops codesign's rejection of dangling or unsealed links inside the bundle; the Packager's own check covers links leading out. While a stop Block has the app aside the link leads nowhere, and a re-sign then verifies without `--strict`. codesign opens what each Redirect leads to, so the Packager walks to the folders again right before (a missing one would fail it, and a FIFO in a folder's place would hang it), and stops it after 10 minutes awake (SIGTERM, then SIGKILL 5 seconds later), asking the user to try again.
- **Code-signing exceptions:** the `cs.*` exceptions (for example `allow-jit`) come only from the Catalog, mirroring what upstream declares (or, for an upstream signed without the hardened runtime, what its code needs under it), plus the automatic `disable-library-validation` above. The user can't toggle them.
- **Permission changes:** a change re-signs the Port, but only while it isn't running. It takes effect on the next launch. Re-signing works in place on a clone kept beside the app, which takes its place again if signing or verifying fails, so the signature always matches `install.json`.
- **Never unsandboxed:** a Port that can't work in the sandbox is Unsupported ([ADR 0002](adr/0002-no-unsandboxed-fallback.md)).
- **No quarantine:** Frontport never leaves `com.apple.quarantine` on a Port, because Gatekeeper rejects quarantined ad-hoc apps. Trust comes from the signed Catalog and GitHub's digests.
- **Privacy grants:**
  - **The cost of ad-hoc signing:** an ad-hoc signature's designated requirement is its cdhash, so privacy grants (microphone, camera, Bluetooth) are requested again after every re-sign.
  - **Why that's acceptable:** gamepads don't trigger Input Monitoring, and controllers need an entitlement rather than a grant.
  - **Fallback:** switch to a per-machine signing certificate if a Port ever needs a grant.

## Lifecycle

- **Updates:** Frontport notifies the user and updates with one click, never automatically. It takes a Snapshot before any Move.
- **Snapshots:** Frontport keeps the last 3 for each Port, and removes older ones whole, read-only folders and all, along with any folder a removal cut short left without its record. They're APFS clones of the contents of Data, so they're cheap until the Data changes. Each records why it was taken (update, Rollback, Channel switch or restore) and the Release at the time.
- **Restoring a Snapshot:** only one of the Port's own Snapshots. Frontport first takes a Snapshot of the current Data, then replaces the contents of Data. It never touches the container folder itself.
- **Rollback:** the back Move to the previous Release, whatever the order says, since a newly pinned ref can be older than the one it replaced.
  1. Snapshot the current Data, so progress made since the update isn't lost.
  2. Swap `previous/` back in, its Build Assets just before its app, using `previous/install.json` to restore the Channel and Build Assets record. Its Release must be the one `install.json` says is kept, with its Build Assets, or the Rollback is refused. A changed Permission re-signs the kept app first. `previous/` is then empty.
  3. Restore the Snapshot taken before the update. Data changes only once the app it belongs to is in place, so a failed swap leaves the Data alone; a failed restore leaves the Snapshot from step 1.
- **Switching Channel:** a switch that lands on an older Release is treated like a Rollback: Frontport takes a Snapshot, warns that the Data may not load, and offers the Snapshot from before the Channel change: the newest one recording the Release it left and the one it went to. If the older Release is the one in `previous/`, it's an actual Rollback; otherwise Frontport fetches it and, once it's in place, restores the newest Snapshot taken on it.
- **Updating to an older Release:** handled the same way, for example when the newest Release is stop-Blocked and the newest one that isn't is older.
- **Uninstall:** removes the Installation, Build Assets included, the Port's `Builds/<port>/`, any download and its logs, and keeps the Data and Snapshots. The build folder holds only what the next build would reuse, such as the source tree and a game the Recipe extracted, whose clones in the Build Assets would otherwise keep its space taken. Removing it makes every folder in it writable first and follows no link.
- **Delete data:** removes the `Data` folder and the Snapshots. macOS keeps the container folder and its protected `.com.apple.containermanagerd.metadata.plist`. A container macOS doesn't manage yet, which Frontport made before the Port's first launch, goes whole, since nothing has run there. Removing `Data` itself, rather than emptying it, matters: macOS rebuilds its standard layout on the next launch only when the folder is gone. An installed Port with Redirects gets `Data` back at once, from the primer, with the Redirects' folders, so a launch from the Dock finds them.
- **Removing the build folder:** the user can remove an installed Port's `Builds/<port>/` from its Port page. The Installation keeps working, and its next build fetches and builds from scratch. It waits for any change under way, such as a build.
- **Leftovers:** a first install that fails removes the `Library/<port>/` it started and any container it made for its Redirects, and keeps its download, build folder and build log for another try. Removing a folder makes every folder in it writable first, so one left read-only can't stop it part way and block the next change. At launch, when nothing is under way, Frontport removes every `staging/`, every download, a `Library/<port>/` without its `install.json`, and the build folder and logs of each Port that isn't installed. An unpack Recipe's `Builds/unpack-<recipe>/` keeps the unpacker it built.
- **Container primer:** Seeding or restoring into a container whose `Data` is gone would leave a folder without macOS's layout. So Frontport first runs a primer: a stand-in app with the Port's bundle ID and a trivial executable (`frontport-primer`), ad-hoc signed with `app-sandbox`. Running it once makes macOS recreate `Data` with its layout, without running any Port code.

## Build sandbox

A Recipe is a shell script stored with the Catalog, whose signature covers its sha256. It runs as two `sandbox-exec` invocations, `recipe.sh fetch` and `recipe.sh build`, under profiles built on Apple's `system.sb`:

- **fetch:** outbound connections to remote hosts and name lookups, but no Unix sockets, which would reach local agents. It may write only `Builds/<port>/src` and `Builds/<port>/tmp`, and can't read ROMs while the network is on.
- **build:** no network. It can read the system, the Command Line Tools, `Toolchain/` and all of `Builds/<port>/`. It can write only `Builds/<port>/`, its tmp folder included, and has no access to the rest of `$HOME`.
- **Metal toolchain:** Xcode 26 and later download the Metal compiler as a component, mounted inside the home folder (`~/Library/Developer/DVTDownloads/MetalToolchain/mounts/…`), where `xcrun` in the build sandbox can't find it. Frontport finds it with `xcrun --find metal` outside the sandbox, lets the build step read and run that `Metal.xctoolchain`, and names its `bin` folder in `$FRONTPORT_METAL`. The compiler then needs `-fmodules-cache-path` inside `$TMPDIR`, since its default cache is in the per-user cache folder.
- **GPU:** the build step may open Apple silicon's Metal device (`AGXDeviceUserClient`) and IOSurface (`IOSurfaceRootUserClient`, without which Metal 4 command queues fail), so a Recipe can run the game to capture what it makes only at run time, such as the shaders it compiles at boot. The Port's app runs the same upstream code with the GPU anyway. Fetch has no GPU.
- **Neither** can see `/usr/local`, `/opt` or `/Library/Frameworks`, so Homebrew can't leak into a build.
- **Leftover processes:** a step's shell runs the Recipe, then kills every other process in the step's sandbox, also when the step is cancelled. A sandboxed process can signal only processes in its own sandbox, which they can't leave, so this reaches those that left the step's process group (`setsid`, job control) too. Frontport then kills whatever is left in the group.
  - **What's left:** a Recipe written to evade this can kill the shell first and keep a process outside the group. That process stays in the build sandbox, the step fails, and Frontport waits for it to close the step's output.
- **Untrusted folder:** a Recipe can leave links anywhere in `Builds/<port>/`, and a process that evades the sweep can outlive its step, so Frontport never follows a link there. It reads only regular files, fetches again when `src` isn't a plain folder, refuses a step whose folders were swapped for links (the profiles grant folders by their resolved path), and checks the app and Build Assets once they're cloned out. The build log is in `Logs/<port>/`, out of the Recipe's reach.

The Recipe contract is in [`catalog/recipes/README.md`](../catalog/recipes/README.md):
- **Environment:** the port, ref, source, output, toolchain and ROMs folders, plus an empty `HOME`, `DEVELOPER_DIR` and `SDKROOT`. `PATH` points at the developer tools' own `bin` folders rather than the `/usr/bin` shims, because the shims write an `xcrun` cache that a build could poison for later unsandboxed use.
- **ROMs:** the Build-Stage ROMs are cloned into the build folder after fetch and removed after the build. An empty list means "build the app without Build Assets", which updates use when the Assets can be carried forward.
- **Output:** exactly one `.app`, with any Build Assets in `out/assets`.
- **Upstream downloads:** anything upstream's build would download is fetched and checked against a pinned sha256 in the fetch step instead.

The toolchain is the Xcode Command Line Tools plus pinned cmake and ninja in `Toolchain/`, verified by sha256; Homebrew isn't used. Each Recipe builds the libraries it needs from pinned, verified source tarballs into `Builds/<port>/prefix`, so a Catalog update can change them without a Frontport release. Frontport asks for the Command Line Tools the first time the user installs a source-built Port, so users who only install prebuilt Ports never need them. `sandbox-exec` is deprecated but still ships, and Chromium, Codex CLI and Claude Code use it. Tools that need LaunchServices or the per-user temp folder, such as `sips` and `iconutil`, don't work in the build sandbox, though ImageIO called from a Recipe's own tool does.

## Verified facts

Spike apps were built and run on 2026-10-24 on macOS 27.0.1 (26A434), arm64, with Swift 6.4.

| Test | Result |
|---|---|
| Ad-hoc sign plus `app-sandbox` | Sandbox applied: `HOME` is the container, reading outside it is denied, and writing to Application Support works |
| `MAP_JIT` without hardened runtime | Works |
| `MAP_JIT` with hardened runtime, no `allow-jit` | `mmap` fails with `EINVAL` |
| `MAP_JIT` with hardened runtime and `allow-jit` | Works |
| Re-sign with a new cdhash and the same bundle ID | Reads the previous version's Data; no prompt |
| Unsandboxed process writes into an existing container | The Port reads it; no prompt |
| Container folder created before the Port's first launch | Adopted in place, but folders keep mode `755` |
| File in `Contents/Resources` before signing | Readable |
| Symlink from the container to an outside file | Denied (`EPERM`); the sandbox checks the target |
| Hard link from the container to an outside file (same volume) | Readable, but it's one shared, writable file |
| `rm -rf` of a container from an unsandboxed shell | Data is removed; the metadata plist and the folder are protected |
| Ad-hoc app under hardened runtime loading an ad-hoc nested dylib | dyld aborts ("different Team IDs"); works with `disable-library-validation`, which still strips `DYLD_INSERT_LIBRARIES` and keeps `MAP_JIT` gated by `allow-jit` |
| Nested helper signed with `app-sandbox` but no `inherit`, spawned by a sandboxed parent | Crashes (`SIGTRAP`); with `inherit` it runs, and started any other way it crashes |
| `clonefile` from ROMs into a container | A true clone (shares all blocks); the Port reads it, and its writes leave the ROMs copy unchanged |
| Unsandboxed Seeding into an ad-hoc Port's container | No TCC request (the container's owner is `signer:none`) |
| Emptying `Data` vs removing it | macOS never refills an emptied `Data`; a removed one is rebuilt with its layout on the next launch |
| Primer app with the Port's bundle ID, run after Delete Data | `Data` is recreated with its full layout; the real Port then reads it |
| Zelda64Recomp 1.2.2 and Shipwright 9.3.0 installed, launched directly | Sandboxed (`sandbox_check` = 1), Data created in the container, update and Rollback restore Data |
| Build profiles with real scripts | Writes outside the allowed folders fail, `~/Documents` can't be read, only fetch can connect, and not to a Unix socket; the compiler runs |
| A fetch step that swaps its tmp folder for a link | The build step's profile would grant the link's target, outside `Builds/<port>/`; Frontport now refuses the step |
| Signals from the build sandbox | Reach only the step's own processes, not its parent, another process or another step under the same profile. `set -m` and `setsid` leave the step's process group, and `kill -1` kills the sender too |
| Starship v2.0.0 and zelda3 Recipes, without a ROM | Build to a working `.app` in 168 s (cold) and 26 s |
| A link out of an ad-hoc app to a file beside it, with a read-only `absolute-path` exception for it (2026-10-25) | The sandboxed app reads through the link, and is denied (`EPERM`) without the exception. `codesign --verify --strict` rejects the link; `--strict=sideband` passes, unless the link leads nowhere. ADR 0004's prototype covers the `home-relative-path` exception |
| Xcode 27's Metal toolchain in the build sandbox (2026-10-25) | `xcrun -sdk macosx metal` reports the toolchain missing, since it's mounted in `~/Library/Developer/DVTDownloads`. Granted read and execute, `metal` and `metallib` run from there by path and make a byte-identical `.metallib`, once `-fmodules-cache-path` points inside `$TMPDIR` |
| .NET 10 in the build sandbox | `dotnet restore` can't reach nuget.org from the fetch sandbox ("bad certificate format": .NET's TLS needs more of the Security framework than the profile allows), so packages come through `curl` into a local feed. Restore and build then run offline |
| A sandboxed launcher that execs a nested program signed with `app-sandbox`, `inherit` and `allow-unsigned-executable-memory` | The program runs sandboxed, with the container as its home, can't read the home folder, and runs code it wrote into memory it then made executable. But an AppKit program aborts in its LaunchServices check-in (`_RegisterApplication`, signal 6), so a Port's windowed program must be the app's own executable |
| Metal in the build sandbox (2026-10-25) | Without the GPU rule, `MTLCreateSystemDefaultDevice` returns nil. With `AGXDeviceUserClient` alone the device and a compute pipeline work, but a Metal 4 command queue and shared events fail, which a game's host can abort on; `IOSurfaceRootUserClient` makes both work |

The synthetic end-to-end test (`SyntheticEndToEndTests` in `FrontportIntegrationTests`, opt-in with `FRONTPORT_SYNTHETIC_TESTS=1`) ran on 2026-10-25 on the same Mac. It composes every real module over a test Catalog signed with a key it generates, fake GitHub releases, a Recipe and a toolchain package, all served over HTTP from the loopback interface, and runs stand-in Ports in their real containers. Its ROMs are synthetic (noise with the right magic and sizes) and its Ports are a small Swift app and a C app built by its Recipe, so it proves the pipeline, not that any real game or real Recipe works.

| Test | Result |
|---|---|
| Catalog `refresh()` over HTTP | Accepted when signed with the trusted key; one signed by another key, or changed after signing, is rejected; an older `issued` is ignored; a 404 keeps the cache; the cache is verified again at the next launch |
| A Recipe fetched by `recipe(for:)` | Taken only when it matches the signed Catalog's `recipeSHA256` |
| An 8 MiB N64 ROM added as `.v64`, a SNES ROM with a copier header | Stored read-only in standard form under that form's SHA-1; the `.z64` file of the same dump is the same ROM |
| Prebuilt Port with a Runtime Requirement, installed before its ROM is added | Install succeeds and the Requirement is missing; once the ROM is added it's listed as not Seeded until `applyROMs` |
| `applyROMs`, then launching through the Launcher | Seeded at `seedPath` as an APFS clone (sharing all blocks). The sandboxed Port, whose home is its container, reads the right SHA-1 there and can rewrite its own copy; it can't read the copy in ROMs, which stays unchanged |
| Update, Rollback, Delete Data, then `applyROMs` | The update takes a Snapshot and the Port's Data follows it. After Delete Data, applying ROMs runs the primer, macOS lays `Data` out again, and a fresh clone is Seeded that the Port reads. A reinstall with the ROM present Seeds during the install |
| Source-built Port with a Build-Stage Requirement | The Recipe builds the app with clang in the build sandbox, using the pinned toolchain from `Toolchain/`; Build Assets made from the ROM land beside the app, which reads them in its sandbox through its link at `buildAssets.path`; the ROMs are gone from `Builds/` afterwards. An extra added later remakes them for the same Release without fetching again |
| Update to another pinned ref with the same `format` | The Build Assets are cloned forward and the Recipe gets no ROM, even with every ROM removed from ROMs |
| A Redirect from inside the source-built Port's app into its Data | What the sandboxed Port writes beside its executable lands in `Data/<to>`. After Delete Data the folder is back at once, with the layout the primer has macOS make |
| A PC Game's zip, the Carmageddon demo of April 1997, added as a folder ROM, then dethrace v0.10.1 built from its Recipe and installed (2026-10-25) | Intake finds the hash `shasum` prints for the folder; the install fills its 1501 files into the Port's folder in the container, where dethrace finds them with no `dethrace.ini`, runs sandboxed to its main menu and writes `DATA/OPTIONS.TXT`. GOG's Max Pack (build 77629), unpacked with innoextract and its `__support` folders copied in, did the same for both its Games: Carmageddon raced its attract demo and the Splat Pack reached its menu, each in its own container. The February 1997 demo crashes dethrace outside anything Frontport does ([dethrace-labs/dethrace#498](https://github.com/dethrace-labs/dethrace/issues/498)), and so does `Hires = 1` with the demo, which has no 640×480 graphics |
| Fallout's Russian CD image (1C, 2008) added through intake, then Fallout CE built from its Recipe at `0609bcf` and installed (2026-10-25) | `iso.sh` unpacks the image in the build sandbox into the disc's folder, with the hash the mounted CD has, and the image isn't kept. The install fills its 367 files into `Library/Application Support/Fallout` in the container, where the sandboxed game plays its intro, menu and level music from them, starts a new game at Vault 13 and saves into `DATA/SAVEGAME/SLOT01`. The disc's files are read-only, which intake now makes writable before removing their quarantine |
| An update with a `format` bump and a changed Recipe | Needs the ROM again and regenerates the Build Assets. Extras added while it waits leave the installed app's Build Assets alone. Rollback brings back the previous Release with the Build Assets made for it, and Delete Data leaves them |

The UI tests (`mise run uitest`) ran on 2026-10-24 on the same Mac, driving the Debug app on its real services. Testport, a stand-in Port in `App/Testport`, came from a local server; the real Ports came from GitHub. All ran in their real containers.

| Test | Result |
|---|---|
| Testport published from a local server: a test Catalog signed with another key, a GitHub-style release list and a zip with its digest | Installed, re-signed when Network is turned on, Seeded with a synthetic ROM that it reads inside its sandbox, stopped cleanly, uninstalled, and its Data deleted |
| A real Ocarina of Time (USA) dump added as a zip, then Ship of Harkinian 9.3.1 installed | The install Seeds the ROM into SoH's folder in its container. Sandboxed, SoH finds it there and builds `oot.o2r` from it, once someone answers its prompts. After Stop the ROM is still Seeded |
| Zelda64Recomp 1.2.2 launched with a stand-in ROM Seeded | It removes a stored ROM it doesn't recognize, so Frontport then lists the ROM as not Seeded |
| A Port started by Frontport | macOS lists it as a running app a moment after it starts. Frontport is its responsible process, so XCTest reports the Port's crashes against the app under test, and UI tests can't find it by bundle ID |

From primary sources:
- **SteamGridDB:** its v2 API rejects requests without an API key (HTTP 401). 7 of the 8 Ports checked have their own entry; Starship doesn't, so it falls back to Star Fox 64.
- **Release digests:** GitHub release assets carry `sha256:` digests on recent Releases only: Shipwright from 9.0.3, Zelda64Recomp from v1.2.1.
- **Disk images:** `hdiutil attach` and `detach` print a deprecation warning on macOS 27 but still work. Images are mounted under `/private/tmp`, because a volume mounted inside the per-user temporary items folder can't be read.
- **Archive safety:** `ditto -x -k` keeps `../` and absolute-path entries inside the destination.
- **Ad-hoc signatures and privacy grants:** an ad-hoc designated requirement is `cdhash H"…"`, so TCC treats every re-sign as new code (Apple TN3127).
- **Controllers:**
  - SDL3 routes Xbox, PlayStation, Switch Pro, Steam and some 8BitDo pads through IOKit HIDAPI. Inside the sandbox that needs `device.usb`; `device.bluetooth` isn't needed.
  - Input Monitoring applies only to keyboard, mouse and touchpad devices.

Not yet verified:
- Whether a Developer ID–signed Frontport gets an "access data from other apps" prompt when it Seeds or takes Snapshots. A terminal process got none.
- Build Assets and gameplay with a real ROM. One real Port has read a real Seeded ROM (Ship of Harkinian, above); no real Recipe has made Build Assets.
- Whether Zelda64Recomp crashes when stopped during play rather than at a prompt.
- Gameplay that needs JIT in the Recomp Ports.
- The Catalog refresh from its real URL, which now serves the Catalog. `refresh()` is verified only against a local server.
- A Developer ID release. `scripts/release.sh` is written and its dry run works, but no identity, notarytool profile or Sparkle key exists here, so signing, notarization, stapling and the appcast haven't run.

## Port landscape (2026-10-24)

The full Catalog, with sources, is in [`catalog/README.md`](../catalog/README.md).

| Port | Latest Release | macOS asset | Notes |
|---|---|---|---|
| Zelda64Recomp | v1.2.2, 2025-08-27 | `*-macOS.zip`, holding another zip | Runtime Stage; declares `allow-jit`, `allow-unsigned-executable-memory`, `disable-executable-page-protection` and `disable-library-validation`. Removes a stored ROM it doesn't recognize. Upstream crashes on quit (RT64) |
| Starship (Star Fox 64) | v2.0.0, 2025-05-25 | none | Source build with a Build-Stage Requirement. The Recipe works around Xcode 27's Clang and makes it read `sf64.o2r` from `Contents/Resources` |
| zelda3 (A Link to the Past) | v0.3, 2023-08-17 | Windows only | Source build at a pinned commit; Build Assets from the ROM |
| OpenGOAL (Jak and Daxter, Jak II, Jak 3) | v0.3.9, 2026-10-15 | tarball of command-line tools, no app | Source build, one Port per Game; the extractor turns the disc image into the game during the Build |
| sm64coopdx | v1.5.1, 2026-06-01 | arm64 zip | Self-updater stripped; no bundle ID upstream; hosting a game would need `network.server` |
| Fallout CE (Fallout) | v1.1.0, 2024-03-03 | universal DMG whose app plays from the folder it sits in | Source build at commit `0609bcf`, 2025-01-15, patched to play from `Library/Application Support/Fallout` and to find music where the CD keeps it. Runtime Stage: the CD's folder, or its image, which `iso.sh` unpacks ([ADR 0008](adr/0008-unpack-installers-in-the-build-sandbox.md)), Seeded there; it writes `fallout.cfg` and its saves among the game's files |
| Dethrace (Carmageddon, Splat Pack) | v0.10.1, 2026-02-22 | universal DMG that loads SDL from `/Library/Frameworks` or beside its executable, and ships none | Source build against a static SDL2, with no patches, one Port per Game. Runtime Stage: the game's folder ([ADR 0007](adr/0007-take-a-pc-game-as-a-folder.md)), Seeded into `Library/Application Support/dethrace`, which dethrace uses without a `dethrace.ini` and writes its options, key maps and saves into |

## How Steam compares

Steam keeps games in a library folder it owns, with an install record for each game. It downloads content-hashed chunks, so updates fetch only what changed, and "verify" rehashes files against the manifest. Games run unsandboxed.

Frontport borrows the owned Library, the Installation record and hash verification. It can't do chunk-level updates, because GitHub Releases are whole archives. It adds the sandbox, ROMs and Snapshots.

## Deferred

- **Quiver catalog import:** ask the author's permission first.
  - **Why ask:** the API (`api.quiverlauncher.com/api/v1`, public and read-only) has no data license, and `TRADEMARKS.md` restricts use of the name.
  - **Agreed policy:** import only entries with a macOS asset, query the API live rather than copying it, and credit Quiver. Imported Ports get every Permission off except Controllers, an Untested label, and are never built from source.
- **Mods:** native-code mods run into quarantine and library validation inside the sandbox.
- **Data sync, external Libraries.**

## Open questions

Answered during the first implementation: the build profiles ([Build sandbox](#build-sandbox)), Channels ([Releases](#releases)), the Build Assets `format` and per-Port quirks (`launch` and `strip` in the [Catalog](#catalog); patches stay in Recipes).

1. Catalog curation: who reviews entries, how Permissions are tested, and the release signing key. The Catalog is served from `catalog/` on `main`.
2. Whether Seeding or taking Snapshots from a Developer ID–signed Frontport triggers a privacy prompt.
3. SteamGridDB API access: the user's own key (what v1 does), or a shared Frontport key with SteamGridDB's permission. Also whether entries pin specific artwork or take the top-rated.
4. Permissions not yet modeled: `network.server` for hosting (sm64coopdx), and whether Recomp Ports need Files for their in-app pickers.
5. Requirements that a single `oneOf` can't express: Starship's voice-pack extras and zelda3's language ROMs.
