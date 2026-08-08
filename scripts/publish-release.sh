#!/usr/bin/env bash
#
# Publish the direct download: upload the DMGs, the Sparkle appcast, and the
# latest.json manifest to the R2 bucket that synesthia.app serves them from.
#
#   ./scripts/publish-release.sh              # upload
#   ./scripts/publish-release.sh --dry-run    # print what would be uploaded
#
# Nothing here touches the website. The DMGs are deliberately NOT in git and the
# site is not rebuilt to ship a release — web/functions/ reads all three of
# these straight out of R2, so publishing is an upload and a release can go out
# minutes after notarization finishes.
#
# ORDER MATTERS. The DMGs go up before the appcast, because the appcast is the
# announcement: the moment it lists a version, installed copies start fetching
# that URL. Uploading it first would give every user on the internet a 404 for
# as long as the DMG upload takes.
#
# Every step is idempotent, so a run that fails anywhere — a dropped upload, a
# checkout that doesn't have last year's DMGs, a botched verification — is
# recovered by fixing the cause and running the script again. Artifacts already
# in the bucket are recognised by their content and skipped, so a re-run costs
# one HTTP HEAD apiece rather than re-uploading the world.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"
# shellcheck source=release.env
source "$REPO_ROOT/scripts/release.env"

DRY_RUN=0
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=1

step() { printf '\n\033[1;36m==> %s\033[0m\n' "$1"; }
fail() { printf '\n\033[1;31mFAILED: %s\033[0m\n' "$1" >&2; exit 1; }

# Every probe below goes through this, and NONE of them may use the bare URL.
#
# A 404 from /downloads/* is cached at the edge. The Function sends no
# cache-control on its error path, so Cloudflare applies a default Edge TTL —
# four hours, measured — and a HEAD is enough to install it. Probing a URL
# seconds before uploading its bytes therefore publishes a 404 that outlives the
# release: this is exactly how 1.2 shipped to a Sparkle that kept reporting "An
# error occurred while downloading the update" against a bucket that already had
# the DMG.
#
# The Functions now send `no-store` on every error, which removes the trap at
# the source. This stays anyway: it costs one query parameter, it protects
# against the edge default coming back, and a probe has no business writing to
# the cache key that real clients read. The parameter is ignored by the route,
# which keys only on the path, but it is part of Cloudflare's cache key.
probe_url() { printf '%s?probe=%s' "$1" "$PROBE_NONCE"; }
PROBE_NONCE="$(date +%s)-$$"

# Status of a HEAD request, "000" when it never completed. curl writes its own
# "000" *and* exits non-zero on a connection failure, so the fallback would
# otherwise produce two lines and a status that matches nothing.
http_code() {
	local out
	out=$(curl -sS -o /dev/null -w '%{http_code}' --head --max-time 30 "$(probe_url "$1")" 2>/dev/null || true)
	out=${out##*$'\n'}
	[[ "$out" =~ ^[0-9]{3}$ ]] || out="000"
	printf '%s' "$out"
}

# Bare MD5 hex of a file, for comparison against an R2 single-part ETag.
file_md5() {
	if command -v md5 >/dev/null 2>&1; then
		md5 -q "$1"
	else
		md5sum "$1" | cut -d' ' -f1
	fi
}

APPCAST="$RELEASES_DIR/appcast.xml"
[[ -f "$APPCAST" ]] || fail "$APPCAST is missing — run ./scripts/make-appcast.sh first"

# Read the feed rather than the directory. The appcast is the contract: if a DMG
# is on disk but not in the feed (an aborted build, a version Sparkle pruned into
# old_updates/), publishing it would put an unreferenced file in the bucket, and
# every URL the feed *does* list has to resolve before it goes live.
#
# It does NOT follow that every referenced file must be on disk. The appcast is
# merged with the live feed, so it lists every version still inside the update
# window — old DMGs and the deltas between them — while this checkout only ever
# built the current one. A fresh clone has exactly one DMG in build/releases and
# that is the normal case, not an error.
step "Reading $APPCAST"
MANIFEST=$(python3 - "$APPCAST" <<'PY'
import sys, xml.etree.ElementTree as ET
from urllib.parse import urlsplit, unquote

SPARKLE = 'http://www.andymatuschak.org/xml-namespaces/sparkle'
NS = {'sparkle': SPARKLE}
root = ET.parse(sys.argv[1]).getroot()


def field(item, enclosure, name):
    """Read a sparkle:<name> that may be either an enclosure attribute or a
    child element of the item.

    Sparkle accepts both spellings and generate_appcast has moved between them
    across versions, so reading only one silently yields an empty string — which
    then makes every version sort equal and "latest" become whichever item
    happened to be last in the file."""
    value = enclosure.get('{%s}%s' % (SPARKLE, name))
    if value:
        return value.strip()
    node = item.find('sparkle:%s' % name, NS)
    if node is not None and node.text:
        return node.text.strip()
    return ''


items = []
referenced = []  # (name, url, kind) for every file the feed points at, in order


def remember(url, kind):
    name = unquote(urlsplit(url).path.rsplit('/', 1)[-1])
    if name and not any(n == name for n, _, _ in referenced):
        referenced.append((name, url, kind))
    return name


for item in root.iterfind('./channel/item'):
    enclosure = item.find('enclosure')
    if enclosure is None:
        continue
    url = enclosure.get('url', '')
    name = remember(url, 'full')
    if not name:
        continue

    # Delta enclosures are nested under <sparkle:deltas> and are invisible to
    # find('enclosure'), which only looks at direct children. They are still
    # URLs Sparkle will fetch, so they belong in the referenced set — an
    # unpublished delta is a wasted round trip for exactly the users who are one
    # version behind. They are marked, though, because a missing delta is not a
    # missing update: Sparkle falls back to the full enclosure.
    deltas = item.find('sparkle:deltas', NS)
    if deltas is not None:
        for delta in deltas.iterfind('enclosure'):
            remember(delta.get('url', ''), 'delta')

    # sparkle:version is CFBundleVersion and is the value Sparkle actually
    # compares; shortVersionString is only ever shown to a human.
    build = field(item, enclosure, 'version')
    short = field(item, enclosure, 'shortVersionString')
    length = enclosure.get('length') or '0'
    items.append((build, short, name, length, url))

if not items:
    sys.exit('the appcast contains no enclosures')

if any(not build for build, *_ in items):
    sys.exit('an appcast item has no sparkle:version; refusing to guess which is newest')


def sort_key(entry):
    parts = entry[0].split('.')
    if parts and all(p.isdigit() for p in parts):
        return (0, tuple(int(p) for p in parts))
    return (1, entry[0])


items.sort(key=sort_key)
latest = items[-1]

# Line 1 is the latest (build, short, file, size); the rest are
# "<name>\t<url>\t<full|delta>" for every file the feed references — the exact
# set that must be in the bucket once this publish finishes.
print('\t'.join(latest[:4]))
for row in referenced:
    print('\t'.join(row))
PY
) || fail "could not parse the appcast"

LATEST_LINE=$(head -1 <<<"$MANIFEST")
IFS=$'\t' read -r LATEST_BUILD LATEST_SHORT LATEST_FILE LATEST_SIZE <<<"$LATEST_LINE"
REFERENCED=$(tail -n +2 <<<"$MANIFEST")

echo "  latest      : $LATEST_SHORT (build $LATEST_BUILD) — $LATEST_FILE"
echo "  referenced  : $(grep -c . <<<"$REFERENCED") file(s)"

# Two piles: what this machine can upload, and what it can only vouch for.
LOCAL=()
LOCAL_URLS=()
ABSENT=()
ABSENT_URLS=()
ABSENT_KINDS=()
while IFS=$'\t' read -r name url kind; do
	[[ -n "$name" ]] || continue
	if [[ -f "$RELEASES_DIR/$name" ]]; then
		LOCAL+=("$name")
		LOCAL_URLS+=("$url")
	else
		ABSENT+=("$name")
		ABSENT_URLS+=("$url")
		ABSENT_KINDS+=("$kind")
	fi
done <<<"$REFERENCED"

# `${arr[@]}` on an empty array is an unbound-variable error under `set -u` in
# bash 3.2, which is what /bin/bash still is on macOS. Guard every expansion on
# the count rather than sprinkling `${arr[@]+…}` everywhere.
LOCAL_COUNT=${#LOCAL[@]}
ABSENT_COUNT=${#ABSENT[@]}

step "Checking every referenced file is available"
echo "  local     : $LOCAL_COUNT in $RELEASES_DIR"
echo "  elsewhere : $ABSENT_COUNT to verify against the bucket"

# A file the feed references but this checkout never built has to already be in
# the bucket, and that is checked over HTTP against the very URL the feed hands
# Sparkle — the thing that actually has to work — rather than against the disk.
# Requiring the bytes locally would mean re-downloading every superseded DMG and
# delta into a fresh clone just to republish a feed that already lists them.
#
# Note this reads the enclosure URL, so a rehearsal that overrides R2_BUCKET
# alone still verifies the live site. Override SITE_URL/DOWNLOAD_BASE too if the
# feed is meant to point somewhere else.
PRUNE=()
for ((i = 0; i < ABSENT_COUNT; i++)); do
	name="${ABSENT[$i]}"
	url="${ABSENT_URLS[$i]}"
	CODE=$(http_code "$url")

	if [[ "$CODE" == "200" ]]; then
		echo "  $name: already published"
		continue
	fi

	# A delta that is neither on disk nor in the bucket cannot be published from
	# here — it is a patch between two DMGs this checkout doesn't have. It is
	# also not load-bearing: Sparkle downloads the full enclosure when a delta
	# is missing. Advertising it is strictly worse than not advertising it (a
	# guaranteed 404 on the way to the same download), so drop it from the feed
	# instead of blocking the release on it. This is self-healing: the pruned
	# feed is what the next make-appcast merges against.
	if [[ "${ABSENT_KINDS[$i]}" == "delta" ]]; then
		echo "  $name: unpublished delta (HTTP $CODE) — will be dropped from the feed"
		PRUNE+=("$name")
		continue
	fi

	fail "$name is referenced by the appcast, is not in $RELEASES_DIR, and
        $url answered HTTP $CODE.

        Publishing this feed would offer users an update whose download 404s.
        Either put the DMG back (Sparkle moves superseded builds into
        $RELEASES_DIR/old_updates/) so it gets uploaded, or
        drop that <item> from the appcast.

        A non-200 for *every* file means the Pages Function isn't deployed; 000
        means the request never completed."
done

PRUNE_COUNT=${#PRUNE[@]}
if [[ $PRUNE_COUNT -gt 0 && $DRY_RUN -eq 0 ]]; then
	step "Dropping $PRUNE_COUNT unpublishable delta(s) from the appcast"
	python3 - "$APPCAST" "${PRUNE[@]}" <<'PY' || fail "could not prune the appcast — publish aborted, nothing was uploaded"
import re, sys
from urllib.parse import urlsplit, unquote

path, names = sys.argv[1], set(sys.argv[2:])

# Edited as text, one enclosure per line, rather than re-serialised from an
# ElementTree: a round trip through ET would renumber the namespace prefixes and
# turn the CDATA release notes into escaped markup — a large, unreviewable diff
# in a file whose every other byte is signed content.
kept, dropped = [], 0
for line in open(path).read().splitlines(keepends=True):
    match = re.search(r'url="([^"]+)"', line)
    if match and line.lstrip().startswith('<enclosure'):
        name = unquote(urlsplit(match.group(1)).path.rsplit('/', 1)[-1])
        if name in names:
            dropped += 1
            continue
    kept.append(line)

if dropped != len(names):
    sys.exit('expected to drop %d enclosure(s), matched %d — appcast not modified'
             % (len(names), dropped))

# A <sparkle:deltas> whose every child just went away is not just noise: Sparkle
# reads an empty container as "no deltas" anyway, and leaving it invites the
# next merge to think it is meaningful.
out = re.sub(r'[ \t]*<sparkle:deltas>\s*</sparkle:deltas>\n', '', ''.join(kept))

with open(path, 'w') as f:
    f.write(out)
PY
	echo "  rewrote $APPCAST"
fi

if [[ $DRY_RUN -eq 1 ]]; then
	step "Dry run — nothing uploaded"
	echo "  would upload to r2://$R2_BUCKET/"
	if [[ $LOCAL_COUNT -gt 0 ]]; then
		for name in "${LOCAL[@]}"; do
			echo "    downloads/$name"
		done
	fi
	echo "    appcast.xml"
	echo "    latest.json"
	if [[ $ABSENT_COUNT -gt $PRUNE_COUNT ]]; then
		echo "  would leave in place (already published)"
		# Herestring, never `printf … | grep -q`: grep exits on first match, the
		# producer dies of SIGPIPE, and pipefail turns a match into a failure.
		PRUNE_LIST=$(printf '%s\n' ${PRUNE[@]+"${PRUNE[@]}"})
		for ((i = 0; i < ABSENT_COUNT; i++)); do
			grep -qxF "${ABSENT[$i]}" <<<"$PRUNE_LIST" || echo "    downloads/${ABSENT[$i]}"
		done
	fi
	if [[ $PRUNE_COUNT -gt 0 ]]; then
		echo "  would drop from the appcast (delta, not published)"
		for name in "${PRUNE[@]}"; do
			echo "    $name"
		done
	fi
	exit 0
fi

step "Uploading DMGs"
# Uploaded first, and skipped when already present: a DMG for a given version is
# immutable, so re-uploading it on every release would waste minutes. That skip
# is also what makes this script resumable — a run that died partway through (or
# right after, in the verification step) can simply be run again, and everything
# already in the bucket costs a fingerprint check instead of an upload.
#
# "Already present" is decided by CONTENT, not by name. Skipping on the name
# alone is a silent-corruption trap: build-direct.sh names the DMG from
# MARKETING_VERSION only, so shipping a new build number without bumping the
# marketing version reuses `Synesthia-<same>.dmg`. The appcast would then carry
# the *new* build's signature while R2 kept serving the *old* bytes, and every
# client would fail EdDSA verification and silently never update. Compare
# hashes and refuse rather than skip.
for ((i = 0; i < LOCAL_COUNT; i++)); do
	name="${LOCAL[$i]}"
	url="${LOCAL_URLS[$i]}"

	# Fast path, and the one a resumed run takes: R2 sets the ETag of a
	# single-part upload to the MD5 of the bytes, and the Function passes it
	# through. A match means the bucket already holds exactly this file, proven
	# without pulling ~15 MB back down per DMG. Anything else — a multipart
	# ETag ("<hex>-<n>"), a 404, an undeployed Function — falls through to the
	# authoritative check below, so this can only ever save work, never decide
	# wrongly that two different files are the same.
	HEADERS=$(curl -sS -I --max-time 30 "$(probe_url "$url")" 2>/dev/null || true)
	ETAG=$(awk 'tolower($1) == "etag:" { gsub(/["\r]/, "", $2); print $2 }' <<<"$HEADERS" | tail -1)
	if [[ "$ETAG" =~ ^[0-9a-f]{32}$ && "$ETAG" == "$(file_md5 "$RELEASES_DIR/$name")" ]]; then
		echo "  $name: already published, identical — skipping"
		continue
	fi

	PUBLISHED=$(mktemp -t synesthia-published)
	if wrangler_r2 r2 object get "$R2_BUCKET/downloads/$name" --file "$PUBLISHED" \
		>/dev/null 2>&1 && [[ -s "$PUBLISHED" ]]; then

		LOCAL_SHA=$(shasum -a 256 "$RELEASES_DIR/$name" | cut -d' ' -f1)
		REMOTE_SHA=$(shasum -a 256 "$PUBLISHED" | cut -d' ' -f1)
		rm -f "$PUBLISHED"

		if [[ "$LOCAL_SHA" == "$REMOTE_SHA" ]]; then
			echo "  $name: already published, identical — skipping"
			continue
		fi

		fail "$name is already published with DIFFERENT contents.

        published sha256 : $REMOTE_SHA
        local     sha256 : $LOCAL_SHA

        Two different builds are competing for one filename. The DMG is named
        from MARKETING_VERSION, so this almost always means the build number was
        incremented without bumping the marketing version.

        Bump it and rebuild:
            ./scripts/bump-version.sh patch
            make direct && make appcast

        Overwriting instead would publish an appcast whose signature does not
        match the bytes users download, and every update would fail silently."
	fi
	rm -f "$PUBLISHED"

	echo "  $name: uploading…"
	CONTENT_TYPE=application/octet-stream
	[[ "$name" == *.dmg ]] && CONTENT_TYPE=application/x-apple-diskimage
	wrangler_r2 r2 object put "$R2_BUCKET/downloads/$name" \
		--file "$RELEASES_DIR/$name" \
		--content-type "$CONTENT_TYPE" \
		--cache-control "public, max-age=31536000, immutable" \
		>/dev/null
done

step "Writing latest.json"
# What /download redirects to. Generated here rather than by hand so it can
# never disagree with the feed it was derived from.
LATEST_JSON="$RELEASES_DIR/latest.json"
python3 - "$LATEST_JSON" "$LATEST_SHORT" "$LATEST_BUILD" "$LATEST_FILE" "$LATEST_SIZE" <<'PY'
import json, sys, datetime
path, version, build, file, size = sys.argv[1:6]
manifest = {
    'version': version,
    'build': build,
    'file': file,
    'size': int(size),
    'published': datetime.datetime.now(datetime.timezone.utc)
        .replace(microsecond=0).isoformat().replace('+00:00', 'Z'),
}
with open(path, 'w') as f:
    json.dump(manifest, f, indent='\t')
    f.write('\n')
print(json.dumps(manifest))
PY

wrangler_r2 r2 object put "$R2_BUCKET/latest.json" \
	--file "$LATEST_JSON" \
	--content-type application/json \
	--cache-control "public, max-age=300" \
	>/dev/null

step "Uploading the appcast (this is what goes live)"
wrangler_r2 r2 object put "$R2_BUCKET/appcast.xml" \
	--file "$APPCAST" \
	--content-type "application/rss+xml; charset=utf-8" \
	--cache-control "public, max-age=300" \
	>/dev/null

step "Verifying what users will actually get"
# Check the CONTENT, not just the status code. If the Pages Functions aren't
# deployed, the static site answers these same paths with the homepage HTML and
# a cheerful 200 — indistinguishable from success if you only look at the code.
#
# The feed is edge-cached for five minutes, so this proves reachability and
# shape, not that the bytes are already the ones just uploaded.
FEED_BODY=$(curl -fsS "$FEED_URL" 2>/dev/null || true)
if grep -q "<rss" <<<"$FEED_BODY"; then
	echo "  $FEED_URL → serving the appcast"
else
	echo "  $FEED_URL → NOT the appcast (got $(wc -c <<<"$FEED_BODY" | tr -d ' ') bytes)"
	echo "     The Pages Function is probably not deployed — the static site is"
	echo "     answering instead. Check the latest deployment succeeded."
fi

# Everything this run put in the bucket, fetched back through the site.
#
# The ABSENT files were probed before upload; these were not, and the difference
# used to matter. `Synesthia6-5.delta` uploaded cleanly, sat in R2 intact and
# correctly signed, and 404'd for every client — because the Pages Function's
# filename whitelist only recognised `.dmg`. Nothing in the pipeline looked at a
# delta URL after writing it, so the only symptom was a line in each user's
# Sparkle log; the updates still landed, via the full 4.6 MB enclosure.
#
# Informational, not fatal: a 404 cached at the edge from a probe made before
# the upload is a plausible false alarm, and re-running is the fix either way.
#
# The latest DMG is always checked, even on a republish that uploaded nothing:
# it is the one URL every user in the feed is about to be sent to.
VERIFY_URLS=(${LOCAL_URLS[@]+"${LOCAL_URLS[@]}"})
# Herestring, never `printf … | grep -q`: grep exits on first match, printf dies
# of SIGPIPE, pipefail turns that into a non-zero pipeline — and this one is
# read by `||`, so a match would be misread as "not present" and the latest DMG
# would be probed twice.
VERIFY_LIST=$(printf '%s\n' ${VERIFY_URLS[@]+"${VERIFY_URLS[@]}"})
grep -qxF "$DOWNLOAD_BASE/$LATEST_FILE" <<<"$VERIFY_LIST" \
	|| VERIFY_URLS+=("$DOWNLOAD_BASE/$LATEST_FILE")

for url in "${VERIFY_URLS[@]}"; do
	CODE=$(http_code "$url")
	if [[ "$CODE" == "200" ]]; then
		echo "  $url → 200"
	else
		echo "  $url → $CODE (expected 200)"
		echo "     Uploaded, but not being served. Re-run this script; if it stays"
		echo "     non-200, the Pages Function is rejecting the name — see"
		echo "     isSafeArtifactName in web/lib/releases.ts."
	fi
done

# No -L: /download must answer with a redirect, not render something.
DL_CODE=$(curl -s -o /dev/null -w '%{http_code}' "$SITE_URL/download" || echo "000")
DL_TO=$(curl -s -o /dev/null -w '%{redirect_url}' "$SITE_URL/download" || true)
if [[ "$DL_CODE" == "302" ]]; then
	echo "  $SITE_URL/download → 302 $DL_TO"
else
	echo "  $SITE_URL/download → $DL_CODE (expected 302)"
	echo "     503 means latest.json is missing; 200 means the Function is not deployed."
fi

step "Published"
echo "  Version : $LATEST_SHORT (build $LATEST_BUILD)"
echo "  File    : $LATEST_FILE"
echo "  Feed    : $FEED_URL"
echo "  Direct  : $SITE_URL/download"
