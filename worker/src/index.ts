import { serve, type Env } from "./artwork";

export default {
  async fetch(request: Request, env: Env, ctx: ExecutionContext): Promise<Response> {
    // Cloudflare's edge cache answers repeat requests before R2 is read. It only works on a custom domain.
    const cache = (caches as unknown as { default: Cache }).default;
    if (request.method === "GET") {
      const hit = await cache.match(request);
      const known = request.headers.get("If-None-Match");
      const etag = hit?.headers.get("ETag");
      if (hit && known && etag && known.split(",").some((tag) => tag.trim().replace(/^W\//, "") === etag)) {
        const headers = new Headers(hit.headers);
        headers.delete("Content-Type");
        headers.delete("Content-Length");
        return new Response(null, { status: 304, headers });
      }
      if (hit) return hit;
    }
    const response = await serve(request, env, fetch);
    if (request.method === "GET" && (response.status === 200 || response.status === 404) && response.headers.get("Cache-Control")?.startsWith("public")) {
      ctx.waitUntil(cache.put(request, response.clone()));
    }
    return response;
  },
} satisfies ExportedHandler<Env>;
