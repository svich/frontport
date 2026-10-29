# Take a PC Game as a folder of files, and Seed it by filling in

**Status:** accepted with the first PC Port, dethrace's Carmageddon.

A console Game is one file, a cartridge dump or a disc image, and Frontport identifies a ROM by the SHA-1 of that file. A PC Game isn't one file: Carmageddon is a folder of about a thousand files, `DATA/` and its executables, as its CD, its zip or its install leaves them. dethrace plays from that folder and writes into it: its options (`DATA/OPTIONS.TXT`), key maps (`DATA/KEYMAP_<n>.TXT`) and saves (`DATA/SAVEGAME/`). So:

- **A folder is a ROM.** Its standard form is its files, and its hash is the SHA-1 of what `shasum` prints for them, one `<sha1>  <path>` line each, sorted by path: `find . -type f ! -path '*/.*' ! -path '*/__MACOSX/*' | cut -c3- | LC_ALL=C sort | tr '\n' '\0' | xargs -0 shasum | shasum` inside it. Hidden files and a zip's `__MACOSX` are left out, and so are folders that only wrap it, such as `INTRPLAY/CARMDEMO/` in a zip of an early Carmageddon demo, so the folder, its zip and a zip of the folder above it are the same ROM. A link or a special file in it is refused, and so is a folder with no files.
- **ROMs keeps exactly those files** as `ROMs/<sha1>.folder`, read-only, cloned from what the user added.
- **A zip holding several files and no ROM** is a folder. A zip holding one ROM, or one lone file, is still that file.
- **Seeding fills in.** At a `seedPath` without a trailing `/`, the folder at that path receives the ROM's files; with one, `<sha1>.folder` inside it does. Each file missing there, in any form, is cloned in, writable by the Port; every file or folder already there is left as it is, since the Port may have rewritten it, and nothing is removed. A folder ROM is Seeded once none of its files is missing, so a file the Port deleted comes back at the next Seeding.
- **One release per folder.** Filling a folder writes a `.frontport-rom` marker naming the ROM's hash. A folder marked as filled from another ROM, such as the demo before the full game the Requirement prefers, is first renamed to `<name> (<its hash's first 8>)`, with what the Port wrote there, and the new release gets a folder of its own.

## Considered Options

- **A Build-Stage file,** such as the CD's disc image or GOG's installer, unpacked by the Recipe into Build Assets. No change to ROMs, but the Build Assets are read-only, so the Recipe must also give dethrace a writable game folder, and a demo or an install has no such file.
- **Identify a folder by one of its files,** such as the executable. A damaged or missing data file would pass, and the identity wouldn't cover what's Seeded.
- **Hash a zip of the folder.** Zip tools differ in order, dates and compression, so the same files would make many hashes.
- **Replace on Seeding,** as a single-file ROM is replaced when it differs. It would throw away the options and saves dethrace keeps among the game's files.
- **Case-insensitive paths.** DOS ignores case, but the identity would no longer be what `shasum` prints.

## Consequences

- **A folder the Game has written to doesn't match.** An install with saves or changed options has more or other files than the release the Catalog lists; the user adds the release as it came, from its zip or a fresh install. The demo comes as a zip.
- **Switching releases leaves the old folder behind.** A demo's folder, with its saves, stays in Data under its new name until the user deletes Data; Frontport never deletes what a Port wrote.
- **An installer's folder isn't always the game's.** GOG's Max Pack installer (build 77629) keeps the key maps, `OPTIONS.TXT` and empty save slots in `__support/app` and `__support/save` and copies them into the game's folder at install, without replacing anything. `innoextract` leaves them out, and dethrace stops without its key maps ([dethrace-labs/dethrace#1150](https://github.com/dethrace-labs/dethrace/issues/1150)). The Catalog lists the folder as the installer leaves it, and Frontport now takes the installer itself and unpacks it that way ([ADR 0008](0008-unpack-installers-in-the-build-sandbox.md)).
- **Every listed folder must be dumped for the Catalog.** No public database lists folder hashes; the Catalog lists the ones someone checked.
- **A marker is hidden.** Seeding's `.frontport-rom` starts with a dot, so the Port's folder, added again as a ROM, still has the ROM's hash, as long as the Port changed nothing else.
- **Seeding walks the folder.** Checking whether a folder ROM is Seeded stats each of its files; for a thousand files that's milliseconds.
