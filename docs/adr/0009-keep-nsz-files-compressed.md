# Take nsz's NSZ and XCZ files as the NSP or XCI they were made from, and keep them compressed

**Status:** accepted with nxnative's Link's Awakening, whose dump was an NSZ. Superseded by [ADR 0011](0011-keep-unlisted-files-unverified.md): intake no longer rebuilds NCZs, so an NSZ or XCZ is kept compressed but Unverified, as the ROM the user chooses, and the Recipe decompresses it with nsz.

Switch games are often kept as NSZ or XCZ files, made by [nsz](https://github.com/nicoboss/nsz): an NSP or XCI whose large NCAs are compressed into NCZs. Link's Awakening's base game is 5.84 GB as an NSP and 2 GB as an NSZ. Frontport identifies an NSP or XCI by its NCAs ([ADR 0006](0006-identify-switch-files-by-content.md)), checking each against its content ID, the first half of its SHA-256. An NCZ keeps its NCA's content ID as its name, but its bytes aren't the NCA's, so it can't be checked as it is. Before this, an NSZ was read as an NSP whose NCZs weren't NCAs: its identity covered only the small NCAs left uncompressed, and it was refused as a ROM the Catalog doesn't list.

An NCZ holds the NCA's first 0x4000 bytes (its headers) as they are, then a table of the NCA's sections with the key and counter that encrypt each, then the sections' data, decrypted and compressed with zstd, as one stream or in blocks of a fixed size. So rebuilding the NCA takes zstd and AES-CTR, and no console keys. So:

- **An NSZ is the same ROM as its NSP,** and an XCZ as its XCI. Intake rebuilds each NCZ's NCA as nsz does, hashes it as it goes, without writing it anywhere, and checks it against its content ID like any NCA. The identity is the same SHA-1 of the content IDs, so the Catalog lists the version once, whatever container the user has.
- **ROMs keeps the file compressed,** in format `nsz` or `xcz`, so the base game takes 2 GB there instead of 5.84.
- **Frontport decompresses with zstd's own decoder,** zstd 1.5.7's single-file decompressor (`FrontportKit/Sources/CZstd`, BSD), since Apple's Compression has no zstd. AES-CTR comes from CommonCrypto.
- **The Recipe makes the NSP.** The Builder hands the Recipe the NSZ as `<sha1>.nsz`, and `nxnative.sh` decompresses it into `Builds/<port>/unpacked/<sha1>.nsp` with zstandard and pycryptodome, as nsz does, before upstream's script reads it. nxnative's script would run nsz itself, but nsz's key loader wants keys the standard form of the console keys leaves out (`key_area_key_ocean_source`, `key_area_key_system_source`).

## Considered Options

- **Refuse NSZs, and ask for the NSP.** No new code, but users would need nsz and a terminal to add a game they already have.
- **Store the decompressed NSP.** The Recipe would need nothing new, but ROMs would hold 3.8 GB more for Link's Awakening alone, and intake would write gigabytes it could just hash.
- **List NSZs by their file's hash, as installers ([ADR 0008](0008-unpack-installers-in-the-build-sandbox.md)).** An NSZ's bytes depend on nsz's version, compression level, block size and threads, so a hash would accept only the one file someone hashed for the Catalog, and an unpack Recipe yields only folders.
- **Take the NCZs' names on trust.** The content IDs would come from the file names, with no check that the compressed data makes those NCAs; a damaged NSZ would surface only as a failed build.
- **Run nsz in the Recipe, as nxnative's script would.** It needs keys Frontport drops, and its command line starts a multiprocessing server it doesn't need for decompressing.

## Consequences

- **Adding an NSZ takes as long as decompressing it.** Link's Awakening's 2 GB took 12 seconds from an external SSD.
- **The build needs space for the NSP.** `Builds/<port>/unpacked` keeps it until the Port is uninstalled or the ROM is no longer used, so a rebuild finds the same file and nxnative reuses its extraction.
- **Frontport parses zstd outside the sandbox.** Its own code reads untrusted NSZs at intake, as it reads NSPs; zstd's decoder is fuzzed upstream, and frames are limited to zstd's default 128 MB window, as nsz's decoder is.
- **A converted game card dump in an NSZ is put back as in an NSP** ([ADR 0006](0006-identify-switch-files-by-content.md)). An NCZ keeps its NCA's headers as they are, so with console keys in ROMs, intake hashes the rebuilt NCA with its header marked as from a game card too, and writes that sector into its copy of the NSZ.
- **NCAs are rebuilt exactly as nsz rebuilds them,** each section's data right after the last one's. An NCZ that nsz couldn't turn back into its NCA fails its content ID here too, and is refused.
