# Keep a file the Catalog doesn't list as the ROM the user chooses, Unverified, and decrypt nothing in Frontport

**Status:** accepted, superseding [ADR 0009](0009-keep-nsz-files-compressed.md) and [ADR 0006](0006-identify-switch-files-by-content.md)'s amendment for converted game card dumps.

Frontport accepts a ROM only when the Catalog lists its hash. Two kinds of Switch file never have a listed hash as they are, so Frontport's own code decrypted them at intake to check them:
- **A game card dump a tool converted to an NSP** marks each NCA's header as downloaded, so no NCA matches its content ID. Intake decrypted the header with the shared `header_key` (AES-128-XTS), set the byte back, and encrypted it again (ADR 0006).
- **An NSZ or XCZ** holds NCZs: NCAs decrypted and compressed. Intake rebuilt each NCA with zstd and AES-CTR to check it (ADR 0009).

That made Frontport itself a program that decrypts game files, beside the builds that have to. The builds need decryption anyway, and get it from the Projects' own tools and pinned upstream tools such as hactool and nsz, inside the build sandbox. Frontport shouldn't ship decryption code of its own. So:

- **Nothing in Frontport decrypts.** Intake hashes each NCA as it is. One that doesn't match its content ID, and an NCZ, count by the first half of their own SHA-256 instead. The identity is still the file's own, but no ROM in the Catalog has it, and intake says why: made from an XCI or damaged, or compressed with nsz. `CZstd`, the NCZ reader and the XTS code are gone.
- **A file whose hash the Catalog doesn't list can be kept as a ROM the user chooses, Unverified.** Intake offers the ROMs some Requirement accepts in the file's own format, or in any Switch container for a Switch game. It never offers console keys, firmware or an Installer, whose hash alone says what they are. The record keeps the chosen ROM's SHA-1 as `sha1` and the file's own as `ownSHA1`, so Matching, Seeding and the Builder treat it as the chosen ROM. Its file is `ROMs/<sha1>.<format>` in its own format, so an NSZ stays compressed as `.nsz`.
- **Hashes still attach ROMs by themselves.** A file the Catalog lists is added as always, and takes the place of an Unverified ROM kept as the same ROM. Nothing takes a listed ROM's place.
- **Seeded files are tagged with the file's own hash** ([ADR 0010](0010-tag-seeded-files.md)). A listed ROM that replaces an Unverified one is then Seeded over it.
- **Switch Recipes decrypt with upstream tools only.** They decompress an NSZ or XCZ with nsz and derive the keys they need with hactool. Before the long steps, they check each game's title ID and version, read from its meta NCA, so a wrong file fails within a minute instead of after an hour.

## Considered Options

- **Take only plain NSPs and XCIs.** This needs no decryption either. But a user with an NSZ, or with a dump a tool converted, would need nsz or another dump.
- **List more hashes in the Catalog:**
  - the converted form of each game card dump, since conversion always gives the same bytes;
  - each NSZ's contents after zstd alone, since an NCZ's data is already decrypted.

  Each version listed would need a dump in that form to hash.
- **Move the decryption into Recipes, or have Frontport download hactool for intake.** Frontport would still decrypt at intake, only through another program. hactool also neither writes NCAs nor reads NCZs.
- **Keep Frontport's decryption.** This gives the strongest check, at the cost above.

## Consequences

- **A wrong Unverified file shows only at build or run time.** The Recipe's early check catches another Switch game or version. Many Ports check their own ROM, as Zelda 64: Recompiled does. The ROMs screen marks the ROM Unverified and shows the file's own SHA-1.
- **An Unverified ROM counts as the chosen ROM everywhere:** on the store page, in what's Needed and in the Build Assets record.
- **Any Platform's file can be kept Unverified,** such as another revision of an N64 ROM, at the user's risk.
- **Converted dumps and NSZs no longer get their Catalog hash.** Fire Emblem: Three Houses' converted game card base and Link's Awakening's NSZs, accepted before, are Unverified when added again. ROMs that already hold them keep them as they are.
- **Intake no longer reads zstd,** so Frontport parses only container headers outside the sandbox.
