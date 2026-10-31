# Add a Steam game as Steam's manifests list it, and leave out the files it rewrites

**Status:** accepted with Gothic II and Half-Life, Opposing Force and Blue Shift.

A PC Game the user owns on Steam is a folder ROM ([ADR 0007](0007-take-a-pc-game-as-a-folder.md)), but adding one was hard. Its folder is in the hidden `~/Library/Application Support/Steam/steamapps/common/`, and a played copy never matched: Half-Life rewrites `config.cfg` and `server.cfg`, and writes `SAVE/` beside the game's files. Yet Steam already lists every file it installed, with its SHA-1, in a depot manifest per depot (`depotcache/<depot>_<manifest>.manifest`). The Catalog's folder hashes were computed from those manifests in the first place. So:

- **The Catalog says where Steam installs a folder ROM:** a `KnownROM`'s `steam` names the app, and `folder` the folder inside its install folder when the ROM is one, such as Half-Life's `valve`.
- **The Catalog lists the files a Game rewrites,** as a folder ROM's `configs`, relative to its folder. Its identity and ROMs leave them out, so a played copy still matches, and the Port writes its own. Steam flags them itself: they're the files a depot manifest marks as user config (flag 1). Files marked as versioned user config (flag 2), such as `liblist.gam`, stay in: the Game reads them and doesn't rewrite them. Gothic II has none.
- **Frontport reads Steam's files, never Steam:** the library list (`steamapps/libraryfolders.vdf`), each app manifest (`appmanifest_<app>.acf`, for its install folder, state and installed depots) and the depot manifests. An app counts as installed only when Steam's state says so (`StateFlags` 4), not while it downloads or updates. Steam needn't be running, and Frontport never signs in.
- **An offer costs no hashing.** The manifests give each file's SHA-1, so Frontport works out the identity an installed ROM has without reading the Game, in under a second for all four Games. The ROMs screen lists them under In Steam, and a Port's Add ROM… becomes Add from Steam.
- **Adding takes just the files the manifests list,** less its `configs`, hashing each. Whatever else the Game wrote there, saves and logs, is never read. A file Steam lists that's missing or changed is named, with Steam's Verify as the way out.
- **Any folder intake leaves out `configs` too.** A folder added from elsewhere, or by dropping it, matches with or without them. A Steam install folder dropped on Frontport is added from Steam.

## Considered Options

- **A Steam ROM Type.** Type says what a ROM is, and a Steam game is still a folder. Steam is where it comes from.
- **Ignore a played copy's changed files at intake by reading Steam's flags alone.** A folder from elsewhere has no manifest, so it would be another ROM. Listing them in the Catalog keeps one identity whatever the folder came from.
- **Keep the user's own configs in ROMs, outside the identity.** The Port would start with their settings, but two copies of one ROM would differ, and ROMs would hold what its hash doesn't cover.
- **Run SteamCMD or ask Steam to download a pinned build.** It needs the user's Steam login, which Frontport never handles. Pointing the user at Steam's console (`download_depot`) for a Windows-only Game is left for later.

## Consequences

- **A Port starts without the Game's own configs.** Xash3D FWGS writes `config.cfg` at its first launch, and the listen server's `server.cfg` is optional.
- **Changing `configs` changes the ROM's hash.** Half-Life's three ROMs got new hashes when they gained theirs, so ROMs added before are no longer listed and are added again, from Steam, once.
- **Steam updating a Game makes another build.** Its manifests then give another identity, which the ROMs screen shows as another build until the Catalog lists it. A ROM already in ROMs is a copy and doesn't change.
- **A depot manifest with encrypted file names can't be read.** Steam keeps installed depots' manifests decrypted in `depotcache`; one it hasn't is refused, with Verify as the way out.
- **A Windows-only Game still needs Steam to install it.** Steam for macOS installed Gothic II from `steam://install/39510`.
