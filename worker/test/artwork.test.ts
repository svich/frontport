import { beforeEach, describe, expect, it } from "vitest";
import { maxAge, serve, type Bucket, type Env, type Stored } from "../src/artwork";
import { imagesURL } from "../src/steamgriddb";

const api = "https://sgdb.test/api/v2/";
const png = new Uint8Array([0x89, 0x50, 0x4e, 0x47]).buffer;

class FakeBucket implements Bucket {
  objects = new Map<string, { data: ArrayBuffer; contentType: string; metadata: Record<string, string> }>();
  async get(key: string): Promise<Stored | null> {
    const object = this.objects.get(key);
    if (!object) return null;
    return {
      arrayBuffer: async () => object.data,
      httpMetadata: { contentType: object.contentType },
      customMetadata: object.metadata,
    };
  }
  async put(key: string, data: ArrayBuffer, options: { httpMetadata: { contentType: string }; customMetadata: Record<string, string> }) {
    this.objects.set(key, { data, contentType: options.httpMetadata.contentType, metadata: { ...options.customMetadata } });
  }
}

/** SteamGridDB as a table of answers, counting what's asked. */
class FakeSteamGridDB {
  answers = new Map<string, () => Response>();
  calls: string[] = [];
  fetch = (async (input: RequestInfo | URL, init?: RequestInit) => {
    const url = String(input);
    this.calls.push(url);
    if (url.startsWith(api)) expect(new Headers(init?.headers).get("Authorization")).toBe("Bearer key");
    else expect(new Headers(init?.headers).get("Authorization")).toBeNull();
    expect(new Headers(init?.headers).get("User-Agent")).toBe("Frontport");
    const answer = this.answers.get(url);
    return answer ? answer() : new Response("missing", { status: 500 });
  }) as typeof fetch;

  list(kind: "grid" | "hero" | "logo" | "icon", game: number, data: unknown[]) {
    this.answers.set(String(imagesURL(api, kind, game)), () => Response.json({ success: true, data }));
  }
  image(url: string, body = png) {
    this.answers.set(url, () => new Response(body, { headers: { "Content-Type": "image/png" } }));
  }
}

let bucket: FakeBucket;
let sgdb: FakeSteamGridDB;
let env: Env;
let now: number;
const clock = { now: () => now };
const get = (path: string, method = "GET", headers: HeadersInit = {}) =>
  serve(new Request(`https://artwork.test${path}`, { method, headers }), env, sgdb.fetch, clock);

beforeEach(() => {
  bucket = new FakeBucket();
  sgdb = new FakeSteamGridDB();
  env = { ARTWORK: bucket, STEAMGRIDDB_KEY: "key", STEAMGRIDDB_API: api };
  now = Date.parse("2026-11-13T12:00:00Z");
});

describe("serve", () => {
  it("fetches from SteamGridDB once, stores in R2 and serves the copy afterwards", async () => {
    sgdb.list("hero", 42, [{ id: 7, url: "https://cdn.test/7.png", author: { name: "Zoë" } }]);
    sgdb.image("https://cdn.test/7.png");

    const first = await get("/v1/42/hero");
    expect(first.status).toBe(200);
    expect(first.headers.get("Content-Type")).toBe("image/png");
    expect(first.headers.get("X-Artwork-Asset")).toBe("7");
    expect(decodeURIComponent(first.headers.get("X-Artwork-Author")!)).toBe("Zoë");
    expect(first.headers.get("X-Artwork-Source")).toBe("https://cdn.test/7.png");
    expect(first.headers.get("Cache-Control")).toBe("public, max-age=86400");
    expect(new Uint8Array(await first.arrayBuffer())).toEqual(new Uint8Array(png));
    expect(bucket.objects.has("42/hero")).toBe(true);

    const second = await get("/v1/42/hero");
    expect(second.status).toBe(200);
    expect(second.headers.get("X-Artwork-Asset")).toBe("7");
    expect(sgdb.calls).toHaveLength(2);
  });

  it("answers 304 when the app already has SteamGridDB's pick", async () => {
    sgdb.list("hero", 42, [{ id: 7, url: "https://cdn.test/7.png", author: { name: "artist" } }]);
    sgdb.image("https://cdn.test/7.png");
    expect((await get("/v1/42/hero")).headers.get("ETag")).toBe('"7"');

    const same = await get("/v1/42/hero", "GET", { "If-None-Match": '"7"' });
    expect(same.status).toBe(304);
    expect(same.headers.get("X-Artwork-Asset")).toBe("7");
    expect(same.headers.get("X-Artwork-Author")).toBe("artist");
    expect(await same.text()).toBe("");

    const other = await get("/v1/42/hero", "GET", { "If-None-Match": '"6"' });
    expect(other.status).toBe(200);
  });

  it("prefers the 920×430 grid, as the app does", async () => {
    sgdb.list("grid", 1, [
      { id: 1, url: "https://cdn.test/1.png", width: 600, height: 900 },
      { id: 2, url: "https://cdn.test/2.png", width: 460, height: 215 },
      { id: 3, url: "https://cdn.test/3.png", width: 920, height: 430 },
    ]);
    sgdb.image("https://cdn.test/3.png");
    const response = await get("/v1/1/grid");
    expect(response.headers.get("X-Artwork-Asset")).toBe("3");
  });

  it("caches that a game has no artwork of a kind", async () => {
    sgdb.list("logo", 5, []);
    const first = await get("/v1/5/logo");
    expect(first.status).toBe(404);
    expect(await first.json()).toEqual({ error: "none" });
    expect(first.headers.get("Cache-Control")).toBe("public, max-age=86400");
    const second = await get("/v1/5/logo");
    expect(second.status).toBe(404);
    expect(sgdb.calls).toHaveLength(1);
  });

  it("treats a game SteamGridDB doesn't know as having none", async () => {
    sgdb.answers.set(String(imagesURL(api, "icon", 9)), () => new Response("{}", { status: 404 }));
    expect((await get("/v1/9/icon")).status).toBe(404);
  });

  it("asks again after a week, keeping the stored image when the asset is unchanged", async () => {
    sgdb.list("icon", 3, [{ id: 11, url: "https://cdn.test/11.png" }]);
    sgdb.image("https://cdn.test/11.png");
    await get("/v1/3/icon");
    now += maxAge;
    const response = await get("/v1/3/icon");
    expect(response.status).toBe(200);
    expect(sgdb.calls.filter((c) => c === "https://cdn.test/11.png")).toHaveLength(1);
    expect(Number(bucket.objects.get("3/icon")!.metadata.fetched)).toBe(now);
  });

  it("downloads the new image when SteamGridDB's pick changed", async () => {
    sgdb.list("icon", 3, [{ id: 11, url: "https://cdn.test/11.png" }]);
    sgdb.image("https://cdn.test/11.png");
    await get("/v1/3/icon");
    now += maxAge;
    sgdb.list("icon", 3, [{ id: 12, url: "https://cdn.test/12.png" }]);
    sgdb.image("https://cdn.test/12.png");
    const response = await get("/v1/3/icon");
    expect(response.headers.get("X-Artwork-Asset")).toBe("12");
    expect(bucket.objects.get("3/icon")!.metadata.asset).toBe("12");
  });

  it("serves a stale copy when SteamGridDB fails", async () => {
    sgdb.list("hero", 4, [{ id: 20, url: "https://cdn.test/20.png" }]);
    sgdb.image("https://cdn.test/20.png");
    await get("/v1/4/hero");
    now += maxAge + 1;
    sgdb.answers.set(String(imagesURL(api, "hero", 4)), () => new Response("down", { status: 503 }));
    const response = await get("/v1/4/hero");
    expect(response.status).toBe(200);
    expect(response.headers.get("X-Artwork-Stale")).toBe("1");
    expect(response.headers.get("Cache-Control")).toBe("public, max-age=3600");
  });

  it("answers 502 when SteamGridDB fails and nothing is stored, storing nothing", async () => {
    sgdb.answers.set(String(imagesURL(api, "hero", 4)), () => new Response("no", { status: 401 }));
    const response = await get("/v1/4/hero");
    expect(response.status).toBe(502);
    expect(response.headers.get("Cache-Control")).toBe("no-store");
    expect(bucket.objects.size).toBe(0);
  });

  it("stores nothing when the image download fails", async () => {
    sgdb.list("hero", 6, [{ id: 30, url: "https://cdn.test/30.png" }]);
    sgdb.answers.set("https://cdn.test/30.png", () => new Response("", { status: 404 }));
    expect((await get("/v1/6/hero")).status).toBe(502);
    expect(bucket.objects.size).toBe(0);
  });

  it("rejects other paths and methods without calling SteamGridDB", async () => {
    for (const path of ["/", "/v1/42", "/v1/42/cover", "/v1/abc/hero", "/v1/0/hero", "/v1/42/hero/x", "/v2/42/hero"]) {
      expect((await get(path)).status, path).toBe(404);
    }
    expect((await get("/v1/42/hero", "POST")).status).toBe(405);
    expect(sgdb.calls).toHaveLength(0);
  });
});
