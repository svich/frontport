# Artwork Worker

A Cloudflare Worker that serves SteamGridDB artwork from an R2 bucket, with SteamGridDB's written permission. It holds the SteamGridDB key, so the app needs none.

`GET /v1/<steamgriddb game id>/<grid|hero|logo|icon>`

- **200:** the image. `X-Artwork-Asset`, `X-Artwork-Author` (percent-encoded) and `X-Artwork-Source` are for the credit.
- **404 `{"error":"none"}`:** SteamGridDB has no artwork of this kind for the game. Cached like an image.
- **502:** SteamGridDB failed and nothing is stored.

On a miss, or once a week per game and kind, the Worker asks SteamGridDB the way `FrontportArtwork/SteamGridDB.swift` does, stores the original image in R2 and serves it. When SteamGridDB fails it serves the stored copy. Answers carry `Cache-Control: public, max-age=86400`, and on a custom domain Cloudflare's edge cache answers repeats before R2 is read.

## Develop

```sh
npm install
npm test
echo 'STEAMGRIDDB_KEY=<key>' > .dev.vars   # git-ignored
npm run dev                                 # http://localhost:8787/v1/<id>/hero, with a local R2
```

## Deploy

Once per Cloudflare account:

```sh
npx wrangler login
npx wrangler r2 bucket create frontport-artwork
npx wrangler secret put STEAMGRIDDB_KEY
```

Then `npm run deploy`.
