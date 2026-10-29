# Let the user add Catalogs by link, each signed with its own key, and read them with Frontport's own as one

**Status:** accepted.

Frontport's own Catalog is built in and signed with the key Frontport ships. Some Ports carry more risk for whoever lists them than others, and some people want Ports that Frontport's Catalog won't list. With one Catalog in one repository, a takedown notice against one Port disables everything. So:

- **The user can add Catalogs.** Settings › Catalogs › Add… takes a Catalog's URL, the folder that holds its `catalog.json`. A `frontport://add-catalog?url=<folder>&key=<public key>` link opens the same sheet from a web page. Frontport never names an added Catalog itself: a Catalog's own pages tell people how to add it.
- **Each added Catalog is signed with its own Ed25519 key.** A link can carry the key. Otherwise Frontport reads `catalog.pub` beside `catalog.json` the first time, so the user trusts the key as much as the URL they were given. Either way, the key is pinned when the user adds the Catalog, and every later document must verify with it. Adding shows the Catalog's name, its key's fingerprint and its Ports before the user confirms.
- **Added Catalogs are untrusted.** Frontport lints each document and refuses one with problems. It reads no Catalog file (document, signature, key or Recipe) past 4 MB, about 100 times the largest today, so a Catalog can't fill memory or the disk. Its Ports run in the sandbox like any other Port, its Recipes run in the build sandbox, and the user sees each Port's Permissions before installing it. The store page says which Catalog lists a Port.
- **Frontport reads every Catalog as one.** Platforms, Genres, Games, ROMs and Ports are merged by id. Frontport's own Catalog comes first, then added ones in the order they were added, and the first to list an id keeps it.
- **A Port belongs to the Catalog it was installed from.** Each entry records the URL of its Catalog (none for Frontport's own), and an Installation keeps it in its entry. Another Catalog listing the same id doesn't make it listed again: it gets no updates, Blocks or Recipes from that Catalog. Otherwise a Catalog could take over a Port that another Catalog stopped listing, and with its bundle ID, the Port's Data.
- **Recipes come from the Catalog that pins them,** and an added Catalog's installers unpack in a workspace of their own, `Builds/unpack-<name>-<catalog>`.
- **The list of added Catalogs is a setting,** in `Catalogs/added.json`. Each added Catalog is cached in `Catalogs/<id>/`, refreshed with Frontport's own, and kept when it can't be reached, with the reason shown in Settings. Removing a Catalog leaves its installed Ports in the Library, not in the Catalog.
- **Frontport's own Catalog lists no Switch Ports.** They move to a Catalog of their own, in its own repository and signed with its own key. Frontport keeps reading Switch files, since any Catalog may list Switch Ports.

## Considered Options

- **Ask at first launch whether to show Switch Ports,** and fetch their Catalog from a URL Frontport knows. That's one click, but Frontport itself would then offer those Ports, and a notice against them would name its repository too.
- **A `frontport://` link in the Catalog's README.** GitHub drops links with schemes other than http and https, so a README can only show the URL to paste, or link to a web page with the `frontport://` link.
- **Sign added Catalogs with Frontport's key.** The user would need nothing but a URL, but Frontport's key would vouch for Catalogs Frontport doesn't list.
- **Prefix each added Catalog's Port ids with its own id.** That makes collisions impossible by construction, but a Recipe reads its Port's id (`FRONTPORT_PORT`), and an id that changes with the URL breaks it.

## Consequences

- **A Catalog taken down stays usable from its cache,** with no updates. Its Ports keep running.
- **A Port installed from Frontport's Catalog before its entry moved to an added one** is no longer listed. It keeps working, and its Data stays, but updating it from the added Catalog means uninstalling and installing it again.
- **The `frontport-catalog` tool signs any Catalog** with `--key`, and verifies it with `--public-key`.
