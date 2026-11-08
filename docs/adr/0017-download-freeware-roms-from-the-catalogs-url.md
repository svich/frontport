# Download a freeware Game's ROMs from where the Catalog says

**Status:** accepted with Command & Conquer and Red Alert, downloaded on 2026-11-08 for the Vanilla Conquer Ports.

Some Games are free to download: EA made Command & Conquer Gold freeware in 2007 and Red Alert in 2008, as disc images. A Port of one still needs the user to find the files, download them and add them, though nothing about them is the user's own: no purchase, no sign-in, the same bytes for everyone. Steam's download ([ADR 0015](0015-download-pinned-depots-with-steam.md)) does this for a Game the user owns; a freeware Game needs no Steam. So:

- **The Catalog says where to download a ROM,** as a ROM's `download`: an https URL of the file and its size in bytes, for the progress bar when the server doesn't send one. An installer can have one too ([ADR 0008](0008-unpack-installers-in-the-build-sandbox.md)): Requirements then accept the folders it yields, and downloading it gives them.
- **What arrives is added as a file the user picked.** Frontport downloads it into a work folder in ROMs and adds it as Add ROM… would: a zip is unzipped, an installer unpacked in the build sandbox. It's kept only if it gives a ROM the Catalog says the download gives, so a mirror that swaps its file is refused, with the hash Frontport found. Nothing is downloaded twice: once its ROMs are in ROMs, it's no longer offered.
- **The ROMs screen and the Port offer it** for a Requirement whose Ports need a ROM Steam doesn't have: Download, with a progress bar. A Port's Add ROM… becomes Download, which downloads each Requirement's ROM in turn, the GDI disc and then the Nod disc. Add from Steam and Download from Steam come first.
- **The Catalog lists the ROMs, not the downloads.** The ROM's hash is its identity, as for any ROM: the same disc image from anywhere else is the same ROM, and adding it by hand still works.

## Considered Options

- **Downloading in the Port's Recipe,** so the Port needs no ROM, as The Ur-Quan Masters' content is. The game's files would be part of the app, fetched again on every build: a Recipe's fetch keeps nothing between builds, and each disc image is half a gigabyte, from mirrors that can be slow. The Internet Archive served EA's images at about 0.5 MB/s.
- **Leaving it to the user,** with a link in the Port's description. It works, but the user would download, find and add four disc images for two Games that need nothing from them.
- **Pinning the download's SHA-256 too.** What's added is checked by the ROM's own hash, which a changed file can't keep; the zip around it may change without changing the ROM.

## Consequences

- **A mirror can go away.** The ROM stays in the Catalog, and Add ROM… still takes a copy from anywhere; a new mirror is a Catalog update.
- **The mirror sees the request.** Frontport sends it with a `Frontport` User-Agent and nothing about the user, as it does for Release assets.
- **Only freeware.** A ROM gets a `download` only when its publisher lets anyone have it. Frontport doesn't check; the Catalog's review does.
- **One ROM downloads at a time,** Steam's or Frontport's, so the ROMs screen shows one progress bar.
