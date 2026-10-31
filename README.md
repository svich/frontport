# Frontport

Frontport is a native macOS app that installs, updates and launches Ports:
Mac versions of Games made by decomp, recomp and sourceport Projects. Every
Port runs inside the macOS App Sandbox, the same isolation App Store apps
get.

Frontport has no emulators: every Port runs its Game as native Mac code.
Emulators, such as DOSBox or RetroArch, and compatibility layers, such as
Wine or CrossOver, which run a Game's original binaries, aren't Ports.

Frontport is in development and has no release yet. To try it, build it from
source.

## What it does

- **Catalog:** a curated list of Ports, signed so Frontport can tell it
  hasn't been tampered with. Frontport installs prebuilt Ports from their
  Project's GitHub Releases, and builds the others from pinned sources in a
  build sandbox.
- **Sandbox:** Frontport re-signs every Port so that it runs in the App
  Sandbox with only the Permissions it needs, such as the network, controllers
  or files you pick. Changing a Port's Permissions re-signs it.
- **ROMs:** you add your own game files once. Frontport identifies each ROM
  by its hash and Seeds it into the Data of every Port that needs it. A file
  whose hash the Catalog doesn't list, such as an NSZ, can be kept Unverified
  as the ROM you choose. Games you own on Steam are found in your Steam
  library and added with one click, without your saves or settings.
- **Updates and Rollback:** while it's open, Frontport checks for new
  Releases. It takes a Snapshot of a Port's Data before every update, and a
  Rollback brings back the previous Release with the Data it had then.
- **More Catalogs:** anyone can publish a Catalog of their own, signed with
  their own key. You add one in Settings › Catalogs by pasting its URL, and its
  Ports appear beside Frontport's. Frontport doesn't review them; their Ports
  run in the same sandbox.
- **Run logs and artwork:** each launch keeps a log, and Ports show artwork
  from [SteamGridDB](https://www.steamgriddb.com), fetched with your own API
  key from Settings, or with the key a release ships with.

## Ports in the Catalog

| Project | Games |
|---|---|
| 2 Ship 2 Harkinian | Majora’s Mask |
| Zelda 64: Recompiled | Majora’s Mask |
| Starship | Star Fox 64 |
| Ghostship | Super Mario 64 |
| sm64coopdx | Super Mario 64, online co-op |
| Banjo: Recompiled | Banjo-Kazooie |
| zelda3 | A Link to the Past |
| OpenGOAL | Jak and Daxter, Jak II, Jak 3 |
| UZDoom | Doom, Doom II, Heretic, Hexen |
| Dethrace | Carmageddon, Carmageddon Splat Pack |
| dhewm3 | Doom 3, Resurrection of Evil |
| RBDOOM-3-BFG | Doom 3: BFG Edition |
| Fallout Community Edition | Fallout |
| Fallout 2 Community Edition | Fallout 2 |

[catalog/README.md](catalog/README.md) lists every Port's details and where
each fact comes from, and how to publish a Catalog of your own.

## Bring your own games

Frontport includes no games and downloads none: no ROMs, game files,
firmware or console keys. Each Port needs your own copy of its Game, which
you add to Frontport yourself.

Frontport isn't affiliated with the Projects whose Ports it installs, or with
the companies that own the Games. See [TRADEMARKS.md](TRADEMARKS.md).

## Requirements

- A Mac with Apple silicon, running macOS 26 or later.
- To build it: Xcode 27 and [mise](https://mise.jdx.dev).

## Building

```bash
mise install
mise run generate
mise run run
```

`mise install` installs the pinned XcodeGen, `generate` makes
`Frontport.xcodeproj`, and `run` builds the app and opens it.
`mise run test` runs the FrontportKit tests. A Debug build keeps its files in
the folder `FRONTPORT_ROOT` names, if set, so you can try it on a scratch
Library. [CONTRIBUTING.md](CONTRIBUTING.md) covers signing, the UI tests and
the opt-in tests that install real Ports.

## Documentation

- [docs/DESIGN.md](docs/DESIGN.md): the design, from the components and the
  Catalog format to sandboxing, signing and what has been verified.
- [GLOSSARY.md](GLOSSARY.md): the terms Frontport uses.
- [docs/adr](docs/adr): decisions with lasting trade-offs.
- [catalog/README.md](catalog/README.md): how the Catalog is signed, and the
  source of every ROM hash and upstream fact.

## License and Contributions

Frontport is licensed under the
[GNU General Public License v3.0](LICENSE). You may use, study, modify, fork,
share and sell it under the terms of that license.

Community contributions are welcome. See [CONTRIBUTING.md](CONTRIBUTING.md)
for how to report issues and submit changes. Before your contributions can be
merged, you must accept the [Contributor License Agreement](CLA.md). You keep
the copyright in your work; the CLA lets the project owner distribute it under
GPL-3.0 and under other licenses, including commercial ones.

The code license doesn't grant rights to use the official Frontport name,
logo or icons for unofficial products. See the
[Trademark Policy](TRADEMARKS.md).

Third-party content bundled with Frontport, and its license, is listed in
[CREDITS.md](CREDITS.md).
