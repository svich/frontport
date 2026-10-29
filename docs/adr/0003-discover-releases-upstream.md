# Discover prebuilt Releases upstream instead of pinning them in the Catalog

For prebuilt Ports, the Catalog pins the repository, the asset pattern and the Permissions, but not the versions. Frontport discovers new Releases upstream and verifies each download against GitHub's sha256 asset digest, and the Catalog can Block bad Releases. Pinning a hash for every Release would make each upstream release wait for a Catalog update. The risk we accept is that a compromised upstream Release gets installed, and the sandbox contains it.

## Consequences

- Source-built Ports are the exception: their refs stay pinned in the Catalog, because an untested tag can break a Recipe.
