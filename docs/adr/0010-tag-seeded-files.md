# Tag Seeded files, and let the preferred ROM replace another at a file's seedPath

**Status:** accepted with Matching, which brings Seeding's rules into one module.

A Runtime Requirement whose `seedPath` names a file, such as UZDoom's `Library/Application Support/UZDoom/doom.wad`, has one place for whichever accepted ROM the user has, and Doom accepts eight IWADs there. A Requirement counted as Seeded as soon as any file was at that path, so a user who Seeded the shareware IWAD and then added Ultimate Doom, which the Requirement prefers, kept the shareware. Seeding itself compared the file's SHA-1 with the ROM's, which is the hash of its standard form: the same thing for a cartridge file, but never for an NSP, XCI or NSZ, identified by their NCAs ([ADR 0006](0006-identify-switch-files-by-content.md), [ADR 0009](0009-keep-nsz-files-compressed.md)). So:

- **A Requirement is Seeded once its Match is in the Port's Data.** At a file `seedPath`, another accepted ROM there is replaced by the Match. A Port doesn't write to its ROM file, so nothing it wrote is lost. A folder ROM keeps [ADR 0007](0007-take-a-pc-game-as-a-folder.md)'s rule: another release's folder is moved aside, never replaced. In a `seedPath` folder, where each ROM is `<sha1>.<format>`, other accepted ROMs stay; Seeding removes nothing.
- **Seeding tags each file it places** with an extended attribute, `dev.frontport.rom`, holding the ROM's SHA-1. A file tagged with the Match's SHA-1 is Seeded, with no hashing. A file without the tag, such as one Seeded before this, is compared byte for byte with the ROM's file in ROMs, then tagged when they're the same, and replaced otherwise.

## Considered Options

- **Any file at the path counts,** as before. Cheap, but a preferred ROM added later never reaches the Port.
- **Hash the file at every check.** No tag to trust, but Frontport checks every Port after every change, an N64 ROM is 64 MB and a disc image gigabytes, and the ROM's hash isn't its file's for Switch files.
- **A marker file beside it,** as a folder has `.frontport-rom`. The Port would find a stray file where it may list its folder, as UZDoom does looking for IWADs. A folder's marker sits inside the ROM's own folder, which is why ADR 0007 could use one.
- **Remember what was Seeded where in Frontport's own records.** Nothing in the Port's Data to trust, but the record goes stale whenever the Port, the user or Delete Data changes the folder.

## Consequences

- **The tag is a claim, not proof.** A Port could tag another file, or keep the tag while rewriting the file in place. It only fools itself: the file is in its own Data.
- **A Port that replaces the file drops the tag,** so the next check compares bytes and Seeds the Match again if they differ.
- **Files Seeded before** are compared once, then tagged, not copied again.
- **A Catalog update can change which ROM a Requirement prefers.** The Port then shows as not Seeded, with Try Again; Seeding still runs only after ROMs are added, after a change of Release, and when a Port that was running quits.
