// The parts of the SteamGridDB v2 API Frontport uses: one list of images per kind and game.
// Mirrors FrontportKit/Sources/FrontportArtwork/SteamGridDB.swift, so the proxy picks what the app would.

export type Kind = "grid" | "hero" | "logo" | "icon";
export const kinds: readonly Kind[] = ["grid", "hero", "logo", "icon"];

export interface Image {
  id: number;
  url: string;
  mime?: string;
  width?: number;
  height?: number;
  author?: { name?: string };
}

export class Unauthorized extends Error {}
export class Failed extends Error {}

/** Sent with every request, so SteamGridDB can tell Frontport's traffic apart. */
export const userAgent = "Frontport";
export const defaultBase = "https://www.steamgriddb.com/api/v2/";

const endpoints: Record<Kind, string> = { grid: "grids", hero: "heroes", logo: "logos", icon: "icons" };

export function imagesURL(base: string, kind: Kind, game: number): URL {
  const url = new URL(`${endpoints[kind]}/game/${game}`, base);
  url.searchParams.set("types", "static");
  if (kind === "grid") url.searchParams.set("dimensions", "920x430,460x215");
  if (kind === "icon") url.searchParams.set("mimes", "image/png");
  for (const flag of ["nsfw", "humor", "epilepsy"]) url.searchParams.set(flag, "false");
  return url;
}

/** Static images of a kind for a game, best first. Empty when SteamGridDB has none or doesn't know the game. */
export async function images(fetcher: typeof fetch, base: string, kind: Kind, game: number, key: string): Promise<Image[]> {
  const response = await fetcher(imagesURL(base, kind, game), {
    headers: { Authorization: `Bearer ${key}`, "User-Agent": userAgent },
  });
  if (response.status === 404) return [];
  if (response.status === 401 || response.status === 403) throw new Unauthorized(`SteamGridDB: ${response.status}`);
  if (response.status !== 200) throw new Failed(`SteamGridDB: ${response.status}`);
  const body = (await response.json().catch(() => null)) as { success?: boolean; data?: Image[] } | null;
  if (!body?.success) throw new Failed("SteamGridDB: malformed answer");
  return body.data ?? [];
}

/** Downloads an image without credentials; they're only for the API. */
export async function download(fetcher: typeof fetch, image: Image): Promise<{ data: ArrayBuffer; mime: string }> {
  if (!image.url.startsWith("https://")) throw new Failed("SteamGridDB: image URL isn't https");
  const response = await fetcher(image.url, { headers: { "User-Agent": userAgent } });
  const data = response.status === 200 ? await response.arrayBuffer() : new ArrayBuffer(0);
  if (data.byteLength === 0) throw new Failed(`SteamGridDB image: ${response.status}`);
  const mime = response.headers.get("Content-Type")?.split(";")[0]?.trim() || image.mime || "application/octet-stream";
  return { data, mime };
}

/** The image to use: for grids the 920×430 landscape, else 460×215, else SteamGridDB's top pick. */
export function choose(images: Image[], kind: Kind): Image | undefined {
  if (kind !== "grid") return images[0];
  return (
    images.find((i) => i.width === 920 && i.height === 430) ??
    images.find((i) => i.width === 460 && i.height === 215) ??
    images[0]
  );
}
