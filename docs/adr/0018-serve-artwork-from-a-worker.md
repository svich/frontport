# Serve SteamGridDB artwork from a Worker that holds the key

**Status:** accepted with SteamGridDB's written permission, deployed on 2026-11-13. Supersedes [ADR 0013](0013-ship-a-steamgriddb-key-in-releases.md).

ADR 0013 shipped a SteamGridDB key inside release builds and let users paste their own. Anyone could read the key out of a release, a new install without one showed flat colors, and every Mac asked SteamGridDB for the same images. SteamGridDB has since given written permission for Frontport to fetch artwork with one key on a server and serve it from there. So:

- **A Cloudflare Worker holds the key.** `worker/` answers `GET /v1/<SteamGridDB game ID>/<grid|hero|logo|icon>` with the image SteamGridDB picks, chosen as the app chose before: the 920×430 grid, then 460×215, else the top pick; static images only, no NSFW, humor or epilepsy-flagged ones. The key is a Worker secret and never reaches a Mac.
- **R2 keeps each image.** The first request for a game and kind fetches it from SteamGridDB and stores the original in an R2 bucket, with its asset ID, author and source. The Worker asks SteamGridDB again only when a request comes after a week, and serves the stored copy while SteamGridDB fails. That SteamGridDB has none of a kind is stored too, and answered as 404 `{"error":"none"}`.
- **The app asks only the Worker.** `ArtworkStore` fetches from it, still caches in `Artwork/` and scales as before, and takes the credit from `X-Artwork-Asset`, `X-Artwork-Author` and `X-Artwork-Source`. A week later it asks again with `If-None-Match` naming the asset it has, and the Worker answers 304 while SteamGridDB still picks it, so an unchanged image isn't downloaded twice.
- **No key in the app.** Settings no longer takes one, releases no longer carry one, and `scripts/release.sh` no longer reads one.

## Considered Options

- **Keep ADR 0013.** It needs no server, but the shipped key is public, users who don't paste one see no artwork until a release carries a key, and each Mac fetches every image from SteamGridDB itself.
- **Proxy only the API calls,** letting each Mac download images from SteamGridDB's CDN. The key would stay private, but SteamGridDB would still serve each image once per Mac.
- **Vercel instead of Cloudflare.** Its Hobby plan allows 100 GB of transfer a month and stops the project beyond it; R2 charges nothing for egress, and its free tier covers the storage and requests artwork needs.
- **Keep the user's own key as an option.** Nothing would need it, and it would keep the Keychain item, the Settings field and two code paths for one source.

## Consequences

- **Artwork depends on the Worker.** If it's down or gone, Macs keep what's in `Artwork/` and show flat colors for the rest.
- **The Worker sees which artwork each Mac asks for,** with the Mac's IP address, as Cloudflare logs it. Requests carry a `Frontport` User-Agent and nothing about the user.
- **Anyone can call the Worker,** for any SteamGridDB game ID, and so spend the key's quota. Limiting it to IDs a Catalog pins, rate-limiting per IP, or both, is an open question in [DESIGN](../DESIGN.md#open-questions).
- **The credit still goes to SteamGridDB's artists,** in the app as before.
- **A key a user saved before stays in their Keychain,** unused, under `dev.frontport.Frontport.steamgriddb`.
