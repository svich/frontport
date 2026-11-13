// Serves SteamGridDB artwork from R2, asking SteamGridDB only on a miss or once a week per game and kind.
// GET /v1/<steamgriddb game id>/<grid|hero|logo|icon>
//   200: the image, with X-Artwork-Asset, X-Artwork-Author (percent-encoded) and X-Artwork-Source for the credit,
//        and the asset id as its ETag.
//   304: If-None-Match names the asset SteamGridDB still picks; the same headers, no image.
//   404 {"error":"none"}: SteamGridDB has no artwork of this kind for the game; cached like an image.
//   502: SteamGridDB failed and nothing is cached.

import { choose, defaultBase, download, images, kinds, type Kind } from "./steamgriddb";

/** The R2 calls this uses; an R2Bucket satisfies it. */
export interface Bucket {
  get(key: string): Promise<Stored | null>;
  put(key: string, value: ArrayBuffer, options: { httpMetadata: { contentType: string }; customMetadata: Metadata }): Promise<unknown>;
}

export interface Stored {
  arrayBuffer(): Promise<ArrayBuffer>;
  httpMetadata?: { contentType?: string };
  customMetadata?: Record<string, string>;
}

/** What R2 keeps beside each image. `none` marks a game with no artwork of the kind. */
type Metadata = { fetched: string; none?: "1"; asset?: string; author?: string; source?: string };

export interface Env {
  ARTWORK: Bucket;
  STEAMGRIDDB_KEY: string;
  /** Overrides the API base, for tests. */
  STEAMGRIDDB_API?: string;
}

export interface Clock {
  now(): number;
}

/** Cached artwork older than this is fetched again, as the app did. */
export const maxAge = 7 * 24 * 60 * 60 * 1000;
/** How long Cloudflare's edge and the app may reuse an answer before asking the Worker again. */
const edgeSeconds = 24 * 60 * 60;

export function route(url: URL): { game: number; kind: Kind } | null {
  const match = /^\/v1\/(\d{1,10})\/([a-z]+)$/.exec(url.pathname);
  if (!match) return null;
  const game = Number(match[1]);
  const kind = match[2] as Kind;
  if (!Number.isSafeInteger(game) || game <= 0 || !kinds.includes(kind)) return null;
  return { game, kind };
}

export async function serve(request: Request, env: Env, fetcher: typeof fetch, clock: Clock = Date): Promise<Response> {
  if (request.method !== "GET" && request.method !== "HEAD") {
    return new Response(null, { status: 405, headers: { Allow: "GET, HEAD" } });
  }
  const target = route(new URL(request.url));
  if (!target) return json(404, { error: "not found" }, "no-store");

  const key = `${target.game}/${target.kind}`;
  const known = request.headers.get("If-None-Match");
  const cached = await env.ARTWORK.get(key);
  const fetched = Number(cached?.customMetadata?.fetched);
  if (cached && clock.now() - fetched < maxAge) return answer(known, cached.customMetadata as Metadata, () => cached.arrayBuffer(), cached.httpMetadata?.contentType);

  try {
    const fresh = await refresh(env, fetcher, clock, key, target.game, target.kind, cached);
    return answer(known, fresh.metadata, async () => fresh.data, fresh.contentType);
  } catch (error) {
    console.error(`artwork ${key}:`, error);
    if (cached) {
      const stale = answer(known, cached.customMetadata as Metadata, () => cached.arrayBuffer(), cached.httpMetadata?.contentType, 60 * 60);
      return stale.then((response) => (response.headers.set("X-Artwork-Stale", "1"), response));
    }
    return json(502, { error: "SteamGridDB unavailable" }, "no-store");
  }
}

/** Asks SteamGridDB and stores the answer in R2, keeping the stored image when the asset hasn't changed. */
async function refresh(env: Env, fetcher: typeof fetch, clock: Clock, key: string, game: number, kind: Kind, cached: Stored | null) {
  const list = await images(fetcher, env.STEAMGRIDDB_API ?? defaultBase, kind, game, env.STEAMGRIDDB_KEY);
  const image = choose(list, kind);
  const fetched = String(clock.now());

  if (!image) {
    const metadata: Metadata = { fetched, none: "1" };
    await env.ARTWORK.put(key, new ArrayBuffer(0), { httpMetadata: { contentType: "application/octet-stream" }, customMetadata: metadata });
    return { metadata, data: new ArrayBuffer(0), contentType: undefined };
  }

  const credit: Metadata = { fetched, asset: String(image.id), source: image.url };
  if (image.author?.name) credit.author = encodeURIComponent(image.author.name);

  let data: ArrayBuffer;
  let contentType: string;
  if (cached && !cached.customMetadata?.none && cached.customMetadata?.asset === String(image.id)) {
    data = await cached.arrayBuffer();
    contentType = cached.httpMetadata?.contentType ?? image.mime ?? "application/octet-stream";
  } else {
    ({ data, mime: contentType } = await download(fetcher, image));
  }
  await env.ARTWORK.put(key, data, { httpMetadata: { contentType }, customMetadata: credit });
  return { metadata: credit, data, contentType };
}

async function answer(known: string | null, metadata: Metadata, body: () => Promise<ArrayBuffer>, contentType: string | undefined, seconds = edgeSeconds): Promise<Response> {
  const cacheControl = `public, max-age=${seconds}`;
  if (metadata.none) return json(404, { error: "none" }, cacheControl);
  const headers = new Headers({
    "Content-Type": contentType ?? "application/octet-stream",
    "Cache-Control": cacheControl,
    "X-Artwork-Fetched": new Date(Number(metadata.fetched)).toISOString(),
  });
  if (metadata.asset) {
    headers.set("X-Artwork-Asset", metadata.asset);
    headers.set("ETag", `"${metadata.asset}"`);
  }
  if (metadata.author) headers.set("X-Artwork-Author", metadata.author);
  if (metadata.source) headers.set("X-Artwork-Source", metadata.source);
  if (metadata.asset && known?.split(",").some((tag) => tag.trim().replace(/^W\//, "") === `"${metadata.asset}"`)) {
    headers.delete("Content-Type");
    return new Response(null, { status: 304, headers });
  }
  return new Response(await body(), { status: 200, headers });
}

function json(status: number, body: unknown, cacheControl: string): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json", "Cache-Control": cacheControl },
  });
}
