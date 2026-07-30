import {
  DOWNLOAD_PREFIX,
  IMMUTABLE,
  isSafeDmgName,
  matchesEtag,
  parseRange,
  plainError,
} from "../../lib/releases";

/**
 * `GET /downloads/Synesthia-1.0.dmg` — the artifact itself, out of R2.
 *
 * These URLs are what Sparkle's appcast points at (`generate_appcast
 * --download-url-prefix https://synesthia.app/downloads/`), so they must stay
 * on the apex domain and must stay stable forever: an appcast entry for an old
 * version is still live for anyone who hasn't updated in a year.
 *
 * Range support is here for interrupted browser downloads. Sparkle doesn't need
 * it, but a 15 MB DMG on hotel Wi-Fi does.
 */
export const onRequest: PagesFunction<Env> = async (ctx) => {
  const { request, env, params, waitUntil } = ctx;

  if (request.method !== "GET" && request.method !== "HEAD") {
    return plainError(405, "Method not allowed", { allow: "GET, HEAD" });
  }

  // `[[file]]` is a catch-all, so this arrives as an array of path segments.
  // Anything with more than one segment is not a file we serve.
  const segments = Array.isArray(params.file) ? params.file : [params.file];
  const name =
    segments.length === 1 ? decodeURIComponent(segments[0] ?? "") : "";

  if (!isSafeDmgName(name)) {
    return notFound();
  }

  const key = `${DOWNLOAD_PREFIX}${name}`;

  // HEAD is answered from metadata alone — no point streaming bytes the runtime
  // will throw away. Browsers and download managers both probe this way.
  if (request.method === "HEAD") {
    const meta = await env.RELEASES.head(key);
    if (!meta) return notFound();

    const headers = baseHeaders(meta, name);
    headers.set("content-length", String(meta.size));
    return new Response(null, { headers });
  }

  const rangeHeader = request.headers.get("range");

  // Full-file GETs are the common case and the only ones worth caching: the
  // Cache API refuses to store a 206, and a partial response cached under the
  // bare URL would be actively wrong.
  if (!rangeHeader) {
    const cache = caches.default;
    const cacheKey = new Request(new URL(request.url).toString(), {
      method: "GET",
    });

    const hit = await cache.match(cacheKey);
    if (hit) {
      if (
        matchesEtag(
          request.headers.get("if-none-match"),
          hit.headers.get("etag"),
        )
      ) {
        return new Response(null, { status: 304, headers: hit.headers });
      }
      return hit;
    }

    const object = await env.RELEASES.get(key, { onlyIf: request.headers });
    if (!object) return notFound();

    const headers = baseHeaders(object, name);

    if (!("body" in object) || !object.body) {
      return new Response(null, { status: 304, headers });
    }

    const response = new Response(object.body, { headers });
    waitUntil(cache.put(cacheKey, response.clone()));
    return response;
  }

  // Ranged GET. Size has to be known before the header can be interpreted at
  // all — `bytes=-500` and an out-of-bounds start are both defined in terms of
  // it — so this costs one metadata read.
  const meta = await env.RELEASES.head(key);
  if (!meta) return notFound();

  const range = parseRange(rangeHeader, meta.size);

  if (range.kind === "unsatisfiable") {
    return new Response(null, {
      status: 416,
      headers: {
        "content-range": `bytes */${meta.size}`,
        "accept-ranges": "bytes",
      },
    });
  }

  if (range.kind === "none") {
    // A Range we chose not to honour (multi-range, or malformed). Serving the
    // whole file with 200 is the specified fallback.
    const object = await env.RELEASES.get(key);
    if (!object) return notFound();
    return new Response(object.body, { headers: baseHeaders(object, name) });
  }

  const object = await env.RELEASES.get(key, {
    range: { offset: range.offset, length: range.length },
  });
  if (!object || !("body" in object) || !object.body) return notFound();

  const headers = baseHeaders(object, name);
  const end = range.offset + range.length - 1;
  headers.set("content-range", `bytes ${range.offset}-${end}/${meta.size}`);
  headers.set("content-length", String(range.length));

  return new Response(object.body, { status: 206, headers });
};

function baseHeaders(object: R2Object, name: string): Headers {
  const headers = new Headers();
  object.writeHttpMetadata(headers);
  headers.set("etag", object.httpEtag);
  headers.set("cache-control", IMMUTABLE);
  headers.set("accept-ranges", "bytes");
  headers.set("content-type", "application/x-apple-diskimage");
  // Without this Safari helpfully renames the download to the route name.
  headers.set("content-disposition", `attachment; filename="${name}"`);
  return headers;
}

/**
 * Always `no-store`. A 404 here means "not published yet", which stops being
 * true the moment an upload lands — and a cached one would go on failing every
 * client for hours after the release is live. See NO_STORE in lib/releases.
 */
function notFound(): Response {
  return plainError(404, "Not found");
}
