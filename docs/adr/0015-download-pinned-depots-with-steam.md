# Have Steam download a Game's depots at the build the Catalog pins

**Status:** accepted with Fallout, downloaded on 2026-10-31 for Fallout CE from the ROMs screen.

[ADR 0014](0014-add-steam-games-by-their-manifests.md) adds what Steam installed. That leaves out a Game the user owns but hasn't installed, and one Steam has updated past the build the Catalog lists. It also leaves out every Windows-only Game: Steam for macOS refuses to install one, with "Invalid platform", from its Library, from `steam://install/<app>` and from its console's `app_install`. Yet its console's `download_depot <app> <depot> <manifest>` downloads any depot the user owns, at any build, whatever its platform. Steam also takes that command on its own command line. A running Steam gets it from the second `steam_osx` process, which then exits. A Steam that isn't running starts and runs it once signed in. So:

- **The Catalog pins the depots,** as a Steam ROM's `steam.depots`: each depot and the manifest of the build its hash comes from, with `app` for a depot of an app `alongside`, in the order Steam installs them, so a file two list is the later one's.
- **Frontport runs `steam_osx +download_depot <app> <depot> <manifest>`,** one depot at a time, and follows Steam's console log (`logs/console_log.txt`) from where it ended. It matches the `ExecCommandLine` line for its command, then reads `Downloading depot <id> (<n> files, <size> MB)` for progress, `Depot download complete` for the end, and `Depot download failed : <reason>` for Steam's reason, such as a depot the user has no license for.
- **It adds what Steam downloaded as it adds what Steam installed.** Steam leaves each depot in `Steam.AppBundle/Steam/Contents/MacOS/steamapps/content/app_<app>/depot_<depot>` and its manifest in `depotcache`. Frontport clones the depots into one folder in its work folder, as one install folder. It checks that folder against the manifests (ADR 0014), and keeps the ROM's files less its Configs. A file ROM is added as any file.
- **What Steam downloaded is removed,** with the `state_<app>_<depot>.patch` Steam keeps beside it, once the ROM is in ROMs or the download failed. ROMs keeps a copy, as for any ROM.
- **The ROMs screen offers it** for a Requirement whose Ports need a ROM Steam hasn't installed: Download from Steam, with a progress bar, and a Port's Add ROM… becomes Download from Steam. Add from Steam, for what Steam installed, comes first. Without Steam, Add ROM… stays, with a link to install Steam beside it. Frontport looks for `Steam.app` in either Applications folder each time it reads Steam's state, when it opens or comes to the front, so Steam installed meanwhile counts.

## Considered Options

- **SteamCMD, DepotDownloader or SteamKit.** Each signs in to Steam itself, with the user's password or a token it keeps. Frontport never handles a Steam sign-in.
- **NotProton,** a third-party library injected into Steam that installs Windows-only apps for CrossOver. It needs Steam re-signed ad hoc, breaks with Steam updates, and installs only the newest build.
- **Typing into Steam's console.** It needs the Accessibility permission, the console window in front and the right display, and a keystroke can land in another app.
- **Only telling the user the command.** It works, but the user would paste it once per depot, and Frontport couldn't tell when the download had ended.

## Consequences

- **Only Steam knows whether the user owns the Game.** Frontport offers the download for every pinned ROM and reports Steam's reason when it fails.
- **Steam's console output is an interface Valve doesn't document.** If its lines change, a download is reported as never started after three minutes, or as never ending, rather than added wrong: the ROM is still checked against the manifests.
- **Steam starts if it isn't running,** as a child of Frontport. It keeps running when Frontport quits.
- **A download takes the whole depot.** A WAD in a 1 GB depot costs the depot. Frontport removes it as soon as the WAD is in ROMs.
- **One ROM downloads at a time.** Steam's log tells downloads apart only by the order of its lines.
