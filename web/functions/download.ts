import {
  LATEST_KEY,
  DOWNLOAD_PREFIX,
  isSafeDmgName,
  plainError,
  type Latest,
} from "../lib/releases";

/**
 * `GET /download` — the stable, linkable URL for "the current version".
 *
 * Redirects to the versioned artifact rather than proxying it, so the download
 * itself is served by the immutable `/downloads/*` route and can be cached hard
 * at the edge. The cost is one extra round trip; the benefit is that a link
 * printed anywhere — the site, a README, a tweet — keeps working across releases.
 *
 * `?json` returns the same information as JSON, which is what lets the site show
 * the real version and size without hardcoding them in consts.ts.
 */
export const onRequest: PagesFunction<Env> = async (ctx) => {
  const { request, env } = ctx;

  if (request.method !== "GET" && request.method !== "HEAD") {
    return plainError(405, "Method not allowed", { allow: "GET, HEAD" });
  }

  const object = await env.RELEASES.get(LATEST_KEY);
  if (!object) {
    // 503, and emphatically not cached — latest.json appears mid-publish, and
    // the edge holding this answer would keep the download button broken well
    // after the release is live.
    return plainError(
      503,
      "No release has been published yet. The Mac App Store build is at https://synesthia.app",
    );
  }

  let latest: Latest;
  try {
    latest = await object.json<Latest>();
  } catch {
    return plainError(500, "The release manifest is corrupt.");
  }

  // latest.json is written by our own publish script, but it is still the one
  // piece of bucket content that steers a redirect — so it gets the same
  // filename check as a user-supplied path.
  if (!latest.file || !isSafeDmgName(latest.file)) {
    return plainError(500, "The release manifest names an unusable file.");
  }

  const target = new URL(`/${DOWNLOAD_PREFIX}${latest.file}`, request.url);

  if (new URL(request.url).searchParams.has("json")) {
    return Response.json(latest, {
      headers: {
        // Short, not immutable: this is the answer that changes on release day.
        "cache-control": "public, max-age=300",
        "access-control-allow-origin": "*",
      },
    });
  }

  return new Response(null, {
    status: 302,
    headers: {
      location: target.toString(),
      "cache-control": "public, max-age=300",
    },
  });
};
