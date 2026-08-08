/**
 * Shared logic for the three release-serving Pages Functions.
 *
 * This lives outside functions/ on purpose: every file under functions/ becomes
 * a route, and Cloudflare does not document any "ignore underscore-prefixed
 * files" rule, so a helper parked there could end up publicly reachable. The
 * Functions bundler follows imports, so a plain relative import works.
 */

/** R2 keys. The bucket holds nothing else. */
export const APPCAST_KEY = "appcast.xml";
export const LATEST_KEY = "latest.json";
export const DOWNLOAD_PREFIX = "downloads/";

/**
 * `latest.json`, written by scripts/publish-release.sh at upload time.
 *
 * It exists so /download is a single R2 read instead of a list-and-sort, and so
 * "latest" is decided once, by the machine that notarized the build, rather than
 * re-derived from filenames on every request.
 */
export interface Latest {
  /** CFBundleShortVersionString, e.g. "1.1". */
  version: string;
  /** CFBundleVersion, e.g. "7". */
  build: string;
  /** Bare DMG filename, e.g. "Synesthia-1.1.dmg". Never a path. */
  file: string;
  /** Bytes, for the "· 4.2 MB" line on the site. */
  size: number;
  /** ISO 8601, when it was published. */
  published: string;
}

/**
 * Filenames under downloads/ we are willing to look up.
 *
 * Deliberately a whitelist rather than a `..` check: the bucket only ever holds
 * flat `Synesthia-<version>.dmg` and `Synesthia<new>-<old>.delta` files, so
 * anything containing a slash, a dot segment, or a percent-escape is a probe
 * rather than a real request.
 *
 * `.delta` belongs here and its omission was a shipped bug. generate_appcast
 * emits a <sparkle:deltas> enclosure whenever two consecutive DMGs are present
 * when the feed is built, publish-release.sh uploads it like any other
 * referenced artifact — and this route then refused to serve it, because the
 * only extension it recognised was the one a *human* downloads. Every copy of
 * 1.2 therefore requested Synesthia6-5.delta, got a 404, and only reached 1.2.1
 * via Sparkle's fall-back to the full enclosure. That fall-back is why it was
 * invisible: the update completed, 4.6 MB at a time, and the failure existed
 * only in the app's log.
 */
export function isSafeArtifactName(name: string): boolean {
  return (
    /^[A-Za-z0-9][A-Za-z0-9._-]*\.(dmg|delta)$/.test(name) &&
    !name.includes("..")
  );
}

/**
 * …and of those, the ones a browser may be redirected to.
 *
 * /download hands a human a file to double-click, so it must resolve to a DMG
 * even though the same bucket prefix now also holds deltas — which are useless
 * on their own and would be a confusing thing to hand someone.
 */
export function isSafeDmgName(name: string): boolean {
  return isSafeArtifactName(name) && name.endsWith(".dmg");
}

/**
 * Content type for an artifact, keyed off the extension the whitelist above
 * already vouched for.
 *
 * The delta's type matches what generate_appcast writes into the enclosure;
 * Sparkle doesn't check it, but a mismatch between the feed and the response is
 * the kind of thing that costs an afternoon later.
 */
export function contentTypeFor(name: string): string {
  return name.endsWith(".dmg")
    ? "application/x-apple-diskimage"
    : "application/octet-stream";
}

export type ParsedRange =
  | { kind: "none" }
  | { kind: "unsatisfiable" }
  | { kind: "range"; offset: number; length: number };

/**
 * Translate a `Range:` header into R2's offset/length form.
 *
 * R2's `get()` takes an R2Range, not a Headers object — unlike `onlyIf`, which
 * does accept headers directly — so this has to be done by hand. Multi-range
 * requests (`bytes=0-99,200-299`) are answered with the whole file, which is
 * allowed: a server may always ignore Range.
 */
export function parseRange(header: string | null, size: number): ParsedRange {
  if (!header) return { kind: "none" };

  const match = /^bytes=(\d*)-(\d*)$/.exec(header.trim());
  if (!match) return { kind: "none" };

  const [, startText, endText] = match;
  if (startText === "" && endText === "") return { kind: "none" };

  // `bytes=-N`: the final N bytes. N larger than the file means the whole file,
  // not an error.
  if (startText === "") {
    const suffix = Number(endText);
    if (suffix === 0) return { kind: "unsatisfiable" };
    const length = Math.min(suffix, size);
    return { kind: "range", offset: size - length, length };
  }

  const offset = Number(startText);
  if (offset >= size) return { kind: "unsatisfiable" };

  const end = endText === "" ? size - 1 : Math.min(Number(endText), size - 1);
  if (end < offset) return { kind: "unsatisfiable" };

  return { kind: "range", offset, length: end - offset + 1 };
}

/**
 * Does this request's `If-None-Match` already cover the entity we hold?
 *
 * Needed because the edge cache is consulted before R2 is, and the cache key is
 * deliberately normalised to the bare URL — so a cache hit would otherwise
 * return a full 200 to a client that already has the bytes, and the `onlyIf`
 * revalidation R2 would have done never gets a chance to run.
 *
 * Weak validators are compared after stripping `W/`: R2 never issues weak
 * ETags, but a client is free to echo one back that way.
 */
export function matchesEtag(
  ifNoneMatch: string | null,
  etag: string | null,
): boolean {
  if (!ifNoneMatch || !etag) return false;
  if (ifNoneMatch.trim() === "*") return true;

  const strip = (value: string) => value.trim().replace(/^W\//, "");
  const held = strip(etag);
  return ifNoneMatch.split(",").some((candidate) => strip(candidate) === held);
}

/** Long-lived, versioned artifacts: the bytes behind a given URL never change. */
export const IMMUTABLE = "public, max-age=31536000, immutable";

/**
 * The appcast is the one thing that must go stale quickly — it is how an
 * already-installed copy learns a new version exists. Five minutes keeps the
 * edge doing the work while still making a release visible almost immediately.
 */
export const APPCAST_CACHE = "public, max-age=300, s-maxage=300";

/**
 * Every error answer from these routes, without exception.
 *
 * A response with no `cache-control` is not "uncached": Cloudflare applies a
 * default Edge TTL, and for these routes it hands a 404 `max-age=14400`. Four
 * hours. Every 404 here is a transient — the URL exists a few seconds later,
 * once publish-release.sh finishes the upload — so caching one pins a lie over
 * the exact window it is wrong in.
 *
 * That is not hypothetical. Publishing 1.2 shipped a DMG whose URL had been
 * requested moments before it existed, and Sparkle spent the next several
 * minutes reporting "An error occurred while downloading the update" against a
 * bucket that already held the file. The bytes were fine; the edge was serving
 * a cached 404. `no-store` is what keeps a miss from outliving itself.
 */
export const NO_STORE = "no-store";

/** A plain-text error that will never be cached. */
export function plainError(
  status: number,
  message: string,
  extra?: HeadersInit,
): Response {
  return new Response(message, {
    status,
    headers: {
      "content-type": "text/plain; charset=utf-8",
      "cache-control": NO_STORE,
      ...(extra as Record<string, string> | undefined),
    },
  });
}
