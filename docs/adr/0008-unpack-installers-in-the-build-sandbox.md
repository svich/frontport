# Unpack installers in the build sandbox, with a Recipe the Catalog pins

**Status:** accepted with GOG's Carmageddon Max Pack, for the dethrace Ports.

A PC Game is bought as an installer: GOG sells Carmageddon Max Pack as `setup_carmageddon_max_pack_1.0_gog_(77629).exe`, a Windows program made with Inno Setup. A Mac can't run it, and the folder ROMs the Catalog accepts ([ADR 0007](0007-take-a-pc-game-as-a-folder.md)) are what it would leave on Windows: `innoextract` unpacks it, but GOG's own script then copies its support files into each game's folder, and without them dethrace stops. Asking every user to run `innoextract` and copy folders by hand isn't something Frontport should ask. So:

- **An installer is a ROM the Catalog knows, with an `unpack`.** Its `KnownROM` has its file's SHA-1 like any ROM, plus `unpack: { recipe, recipeSHA256, yields }`: an unpack Recipe, pinned by hash so the Catalog's signature covers it, and the folder ROMs it holds. No Requirement lists the installer; Requirements list what it yields.
- **Intake unpacks it in the build sandbox.** When the user adds a file whose hash is an installer's, Frontport runs its unpack Recipe the way the Builder runs a Port's (`fetch` with network, then `build` without, each under `sandbox-exec`), in `Builds/unpack-<recipe>/`, with the installer as its one ROM. The Recipe leaves what the installer holds in its output. Frontport hashes each folder there as a folder ROM, and keeps those the installer `yields`, as if the user had added them. The installer itself is never kept.
- **`innoextract.sh` builds innoextract from pinned sources** (a commit after its last Release, which current Boost and GOG's newer installers need; Boost 1.88; xz), kept in its workspace for the next installer, and runs a GOG installer's `supportData` actions after unpacking, never replacing a file, as GOG's installer does.

## Considered Options

- **A Swift reader for Inno Setup.** No build step, but a parser for an undocumented, versioned format, with an LZMA decoder Apple's Compression lacks, running unsandboxed in Frontport on files from the Internet.
- **A Build-Stage Requirement in dethrace's Recipe.** The Recipe would unpack the installer into Build Assets, which are read-only, while dethrace writes into its game's folder; and a Requirement couldn't accept either the installer (Build) or the demo's folder (Runtime).
- **Bundling an `innoextract` binary with Frontport.** One more program to sign and update with Frontport, still parsing untrusted files outside the sandbox unless Frontport sandboxes it anyway, which the Builder already does.
- **Leaving it to the user,** as ADR 0007 did at first: `innoextract`, then copying GOG's support folders. Most people buying from GOG on a Mac have neither the tool nor the know-how.

## Consequences

- **The first installer takes minutes.** Building Boost and innoextract needs the Command Line Tools, as source-built Ports do, and the network for the fetch. Later installers reuse them.
- **One installer, several Games.** The Max Pack yields Carmageddon's and the Splat Pack's folders; each goes to its own Port's Requirement.
- **Only listed installers.** An installer is accepted by its hash, so another build of GOG's installer is refused until the Catalog lists it and the folders it yields. A GOG update that changes the game's files makes new folder ROMs too.
- **Everything else stays behind.** What an installer holds beyond its yields, such as GOG's DOSBox, is left in the workspace's output and cleared by the next unpack.
- **Unpack Recipes are pinned like a Port's.** `frontport-catalog sign` hashes them, `bundle` ships them, and Frontport fetches and verifies them on demand. Port ids may not start with `unpack-`, which names their workspaces.
- **A CD image is an installer too.** A PC Game's disc image holds its folder the way an installer does: `iso.sh` unpacks Fallout's with the bsdtar macOS ships, which reads the names a mounted disc shows, so the image yields the folder the CD itself is, and builds nothing.
- **No progress yet.** Adding an installer shows the ROMs screen's busy state for as long as it takes; the unpack's own progress isn't shown.
