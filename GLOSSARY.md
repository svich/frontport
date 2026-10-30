# Frontport

Frontport installs native Mac versions of games, made from their original code, and runs each one isolated from the rest of the user's Mac.

## Language

### Ports

**Port**:
A native Mac version of a Game, made by a Project, that Frontport installs.
_Avoid_: app, game, title

**Project**:
The upstream effort that makes Ports from one source repository and publishes their Releases, such as Ghostship or OpenGOAL. A Project can make Ports of several Games, and they all follow its Releases.
_Avoid_: repo, repository

**Kind**:
How a Port was made: Decomp, Recomp, Recreation or Sourceport.
_Avoid_: type, category

**Decomp**:
A Port built from source code reconstructed by decompiling the Game.

**Recomp**:
A Port produced by translating the Game's original machine code into native code.

**Recreation**:
A Port that reimplements a Game from scratch instead of deriving from its original code.

**Sourceport**:
A Port built from the Game's own source code, released by its developer, such as UZDoom from id Software's Doom source.
_Avoid_: source port, source build

### Games and ROMs

**Game**:
The original title a Port is based on, such as Ocarina of Time.
_Avoid_: title, port

**Platform**:
The system a Game was originally released on, such as the Nintendo 64. Never the Mac a Port runs on, or the operating system a Release targets. Its Games come on cartridges, ISOs or files.
_Avoid_: console, system, original platform

**Base**:
The Game an expansion plays on top of, such as Half-Life for Opposing Force. A Port of the expansion also takes the base Game's ROMs.
_Avoid_: parent, original game

**Genre**:
A kind of Game, such as Platformer or Racing. A Game has one or more, main one first.
_Avoid_: category, type, tag

**ROM**:
One specific dump of a Game, or of a Platform's own files a Game needs, such as a Switch's console keys, identified by the hash of its standard form, so the same dump in another byte order, with a copier header or in another Switch container is the same ROM. A Doom engine game's IWAD, a `.wad` or `.pk3`, is its ROM. A Game that comes as a folder of files, such as Carmageddon, has that folder as its ROM, identified by all of them, and so does a Switch firmware, a folder of NCAs.
_Avoid_: dump, image, game file

**Type**:
What a ROM is: Cartridge, ISO, Folder, File, Key, Firmware, Update or DLC. The Catalog marks a Game's updates and DLC, which nothing else tells from the Game itself. Otherwise a Game's folder is a Folder, its `.iso` an ISO, and any other ROM of it is what its Platform's Games come on, so a Switch game is a Cartridge as an NSP too. A Platform's console keys are a Key, and its other own files, such as a Switch firmware, are Firmware.
_Avoid_: kind, format, media

**Installer**:
A file the Catalog knows that holds ROMs rather than being one, such as a Game's GOG setup program or a PC Game's CD image. Frontport unpacks it in the build sandbox and keeps only the ROMs it holds.
_Avoid_: setup, package, archive

**Unverified**:
A ROM whose hash the Catalog doesn't list, kept as one it does because the user chose that ROM for it, such as an NSZ or a dump a tool made from an XCI. Frontport matches and Seeds it as that ROM but can't vouch for it: if it isn't that ROM, the Port fails to build or run. A ROM the Catalog lists takes its place.
_Avoid_: unchecked, manual, assigned

**Requirement**:
The ROMs a Port needs: one of a set of accepted ROMs, plus optional extras.
_Avoid_: dependency, prerequisite

**Match**:
The ROMs in ROMs that meet a Requirement: the accepted ROM it prefers among those there, plus the extras there. A Requirement without a Match is missing, unless its Port's Build Assets were made from one of its ROMs.
_Avoid_: satisfied, fulfilled, hit

**Stage**:
When a Requirement's ROM is used: Build (consumed while producing the Port, which never sees it) or Runtime (handed to the Port, which uses it itself).
_Avoid_: phase, mode

**Assets**:
Files generated from a ROM for one Port. Assets made during a Build belong to the Installation; Assets a Port makes itself are part of its Data. Never distributed.
_Avoid_: resources, game data, archive

**ROMs**:
Every ROM the user has added, kept privately by Frontport as input for building and updating Ports, and never played directly.
_Avoid_: Vault, ROM library, collection, shelf

### Catalog

**Catalog**:
A curated, signed list of Ports, with what each needs and what it may access. Frontport has its own built in, and the user can add others by link; Frontport reads them as one, and each Port stays with the Catalog it was installed from.
_Avoid_: store, index, feed, source, repository

**Lineup**:
The Catalog as the Library sees it: which Ports are to install and which Unsupported, by Platform, Genre and Game, with New Ports, the Port of the Day, Projects and their Releases. Every Catalog screen shows part of it.
_Avoid_: offering, storefront, shelf

**Survey**:
What Frontport last found in the Catalog, the Library, ROMs and Releases: taken at launch, every 6 hours while Frontport is open, and after each Activity. The Lineup, every Requirement's Match and each Installation's Update or Fallback are read from it.
_Avoid_: state, cache, reading

**Release**:
One version of a Port as its Project publishes it. A Project's Ports share its Releases.
_Avoid_: build, drop

**Blocked**:
A Release the Catalog forbids installing. A block either warns, or stops the Release from launching.
_Avoid_: banned, yanked

**Recipe**:
The Catalog's instructions for building a Port from source.
_Avoid_: script, build file, formula

**Unsupported**:
A Port in the Catalog that cannot work inside the sandbox, so it is never installable.
_Avoid_: broken, incompatible

**Permissions**:
What a Port may access beyond its own data, such as the network, controllers or files the user picks.
_Avoid_: entitlements, capabilities, rights

### Installing

**Library**:
The Ports installed on this Mac.
_Avoid_: installs, collection, apps

**Installation**:
One Port in the Library, at one Release on one Channel. A Port has at most one.
_Avoid_: install, copy, instance

**Channel**:
The stream of Releases an Installation follows, such as stable or nightly.
_Avoid_: track, branch, ring

**Data**:
Everything a Port keeps for itself on this Mac: progress, settings, its Runtime ROMs and anything it extracted. Survives uninstalling.
_Avoid_: saves, container, profile

**Seed**:
To place a Runtime ROM into a Port's Data. A Requirement is Seeded once its Match is there; another accepted ROM in the Match's place makes way for it: a file is replaced, a folder moved aside.
_Avoid_: inject, provision

**Redirect**:
A path inside a Port's app that Frontport links to a folder in that Port's Data, for a Port that writes beside its executable.
_Avoid_: mount, alias, symlink rule

**Move**:
An Installation going from its Release to another on a Channel: forward, or back, which brings back the Data from when the Port was last on that Release. To the Release it's on, it's none.
_Avoid_: transition

**Snapshot**:
A copy of a Port's Data, taken before any Move.
_Avoid_: backup

**Rollback**:
The back Move to an Installation's previous Release.
_Avoid_: downgrade, revert

**Update**:
A forward Move to the newest Release on the Installation's Channel.
_Avoid_: upgrade

**Fallback**:
The newest Release on an Installation's Channel when it's older than the installed one, offered as the way off a Blocked Release when there's no previous Release to Roll Back to that isn't Blocked.
_Avoid_: downgrade

**Activity**:
A change under way on one Port, such as an install, an update, a Rollback or Seeding. A Port has at most one at a time.
_Avoid_: job, task, operation

**Status**:
What a Port is doing or needs, as the user sees it, and which actions that allows now, each with why when it doesn't.
_Avoid_: state, condition
