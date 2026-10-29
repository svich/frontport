# Keep Build Assets outside the app

**Status:** accepted. A prototype on the Jak II app settled its open questions (see Prototype), and Frontport implements it.

Build Assets live inside the Port's app, at the Catalog's `buildAssets.path`, and its signature seals them. That suited Starship's and zelda3's single files, but OpenGOAL's are folders of 1.5 GB (Jak and Daxter) and 5.0 GB (Jak II), and every signature covers them:
- **Signing** hashes all of it: on install, on every update and on every Permission change.
- **First launch** verifies all of it: Jak II showed "Verifying OpenGOAL-jak2.app" for about 4 minutes from an external drive before the game started.

So Frontport keeps Build Assets in `Library/<port>/assets` (and `previous/assets` for Rollback), next to the app, and the Port reaches them through two things the Packager adds when it signs:
- **A relative link** at `buildAssets.path` that leads to `assets/` beside the app, such as `../../../../../assets` for OpenGOAL's `Contents/Resources/data/out/jak2`. It's the one link out of an app Frontport allows, besides the Redirects of [ADR 0005](0005-redirect-app-paths-into-data.md), because Frontport makes it itself after checking the assets. Being relative, it works for `previous/` too.
- **A read-only sandbox exception** for them: under the home folder, `com.apple.security.temporary-exception.files.home-relative-path.read-only` with `/Library/Application Support/Frontport/Library/<port>/assets/`, which names no user; for a Library outside it, `…absolute-path.read-only` with the canonical path. A folder ends in `/`, a file doesn't.

The app shrinks to its code (55 MB for OpenGOAL), signing and first launch no longer read the data, and the Port still can't change it. No Recipe changes: a Port reads the same path it does today.

## Considered Options

- **Keep them in the app,** as today. Sealed and simple, but every signature covers gigabytes.
- **The Port's Data.** No exception needed, but Frontport treats Data as the user's: three Snapshots would each copy gigabytes, "Delete data" would delete the game, and the Port could change its own game files.
- **A path in Info.plist instead of a link.** No link out of the app, but every Recipe would need a patch to read it, including Starship's and zelda3's, which already read `Contents/Resources`.

## Consequences

- **The sandbox widens, read-only.** A Port with Build Assets can read one more folder, its own. It still writes only its container, so this isn't the unsandboxed fallback [ADR 0002](0002-no-unsandboxed-fallback.md) rules out.
- **Data stays in the container.** The Port writes there without any exception, and macOS writes its preferences there anyway, so only read-only data the Packager makes moves out.
- **The data is no longer sealed.** Anyone who could change the folder could already change the app and re-sign it ad-hoc, so the seal guards nothing more than the folder's permissions do.
- **The link rule gets one exception.** Frontport still refuses any link out of an app that upstream or a Recipe made; only the Packager's own link at `buildAssets.path` passes. Redirects, added later, are the second ([ADR 0005](0005-redirect-app-paths-into-data.md)).
- **Strict verification skips links.** `codesign --verify --strict` rejects any link leading out of a bundle. The Packager verifies once after signing: with `--strict=sideband` when the app's link resolves, plain `--verify` while a stop Block has the app aside and the link leads nowhere, and `--strict` for an app without the link. Its own check polices links leading out instead.
- **Rollback and updates are unchanged.** Assets move with their Release as now, and `buildAssets.format` still decides when they're regenerated.

## Possible extension: disc images read at run time

No Port in the Catalog plays straight from a disc image yet, but one could: a recompilation that reads its game from the ISO at every launch, as Zelda 64: Recompiled and Banjo: Recompiled read their ROMs. Frontport would Seed that image into the container like a ROM. On APFS the clone costs no space, but the Port's Data would show gigabytes, and every Snapshot would hold the image. The same mechanism fits better:
- **The image stays in `ROMs/`.** Seeding puts a link at the Requirement's `seedPath` instead of a clone, leading to `ROMs/<sha1>.<format>`.
- **A read-only exception** for that one file, added when the Packager signs, as for Build Assets.

Snapshots and "Delete data" would then copy or remove only the link. Nothing changes until such a Port arrives; decide then.

## Prototype

On macOS 27 on Apple silicon, with OpenGOAL's Jak II app (55 MB) and its 5.0 GB `assets/` beside it, signed ad-hoc under the hardened runtime as the Packager signs:
- **Signing** took 3 seconds, and the first launch started the game within a second, with no "Verifying" dialog.
- **The game** loaded everything through the link, from its menus onwards, with no sandbox denials. Signed without the exception, it stopped at its first read: `GAME.fr3 cannot be opened: Operation not permitted`.
- **Verification:** `codesign --verify` passes; `codesign --verify --strict` fails with "invalid destination for symbolic link in bundle". `spctl` rejects the app, as it rejects every ad-hoc Port, but Gatekeeper only assesses quarantined apps, and Frontport never leaves quarantine on a Port.
- **LaunchServices and the home-relative exception:** a windowless probe app under `~/Library/Application Support/`, launched both through LaunchServices (as from the Dock) and directly, read its file through the link with the home-relative exception, and was denied without it.

Not covered here: the extraction's own peak. OpenGOAL's extractor copies the unpacked disc once more without cloning, so building Jak II needed about 18 GB free.
