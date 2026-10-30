# Ship a SteamGridDB key in release builds, with SteamGridDB's permission, and let the user's own key come first

**Status:** accepted; no release ships a key until SteamGridDB gives written permission.

Artwork needs a SteamGridDB API key. Until now each user made a SteamGridDB account and pasted their own key into Settings, so a new install showed flat colors. SteamGridDB's terms allow personal, non-commercial use only, and no distribution of the service without their written permission. So:

- **A release build can carry one key,** in its `Info.plist` as `FrontportSteamGridDBKey`. `scripts/release.sh` builds it in from `FRONTPORT_STEAMGRIDDB_KEY` or the login Keychain, and checks the exported app has it. Every other build has an empty value, which counts as no key.
- **The key never goes in the repository.** Forks and local builds use their own.
- **The user's own key comes first.** Settings shows which key Frontport uses. Removing the user's key goes back to the built-in one.
- **Nothing else changes.** Each Mac still fetches artwork for itself, caches it for 7 days and never rehosts it. Every request sends `User-Agent: Frontport`.

## Considered Options

- **Keep per-user keys only.** This needs no permission, but every user has to sign up with SteamGridDB first.
- **A proxy that holds the key.** The key stays private, but Frontport would run a server that rehosts SteamGridDB's answers, and every install would depend on it.
- **Compile the key into the binary, obscured.** It's no harder to extract than from `Info.plist`, only harder to check.

## Consequences

- **Anyone can read the key from a release.** If it's abused, SteamGridDB can revoke it. Releases then fetch nothing with it until an update ships a new one, and a user's own key still works.
