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
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"
# shellcheck source=release.env
source "$REPO_ROOT/scripts/release.env"

DRY_RUN=0
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=1

step() { printf '\n\033[1;36m==> %s\033[0m\n' "$1"; }
fail() { printf '\n\033[1;31mFAILED: %s\033[0m\n' "$1" >&2; exit 1; }

APPCAST="$RELEASES_DIR/appcast.xml"
[[ -f "$APPCAST" ]] || fail "$APPCAST is missing — run ./scripts/make-appcast.sh first"

# Read the feed rather than the directory. The appcast is the contract: if a DMG
# is on disk but not in the feed (an aborted build, a version Sparkle pruned into
# old_updates/), publishing it would put an unreferenced file in the bucket, and
# if it is in the feed but not on disk we need to know before we break the link.
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
for item in root.iterfind('./channel/item'):
    enclosure = item.find('enclosure')
    if enclosure is None:
        continue
    url = enclosure.get('url', '')
    name = unquote(urlsplit(url).path.rsplit('/', 1)[-1])
    if not name:
        continue
    # sparkle:version is CFBundleVersion and is the value Sparkle actually
    # compares; shortVersionString is only ever shown to a human.
    build = field(item, enclosure, 'version')
    short = field(item, enclosure, 'shortVersionString')
    length = enclosure.get('length') or '0'
    items.append((build, short, name, length))

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

# Line 1 is the latest (build, short, file, size); the rest are every file the
# feed references, which is the exact set that must exist in the bucket.
print('\t'.join(latest))
for entry in items:
    print(entry[2])
PY
) || fail "could not parse the appcast"

LATEST_LINE=$(head -1 <<<"$MANIFEST")
IFS=$'\t' read -r LATEST_BUILD LATEST_SHORT LATEST_FILE LATEST_SIZE <<<"$LATEST_LINE"
FILES=$(tail -n +2 <<<"$MANIFEST")

echo "  latest      : $LATEST_SHORT (build $LATEST_BUILD) — $LATEST_FILE"
echo "  referenced  : $(wc -l <<<"$FILES" | tr -d ' ') file(s)"

step "Checking every referenced file is present locally"
while IFS= read -r name; do
	[[ -n "$name" ]] || continue
	[[ -f "$RELEASES_DIR/$name" ]] \
		|| fail "$name is referenced by the appcast but missing from $RELEASES_DIR.
        Sparkle keeps only the newest few versions in the feed and moves the
        rest to $RELEASES_DIR/old_updates/ — move this one back, or fetch it
        from the bucket, before republishing."
done <<<"$FILES"
echo "  all present"

if [[ $DRY_RUN -eq 1 ]]; then
	step "Dry run — nothing uploaded"
	echo "  would upload to r2://$R2_BUCKET/"
	while IFS= read -r name; do
		[[ -n "$name" ]] && echo "    downloads/$name"
	done <<<"$FILES"
	echo "    appcast.xml"
	echo "    latest.json"
	exit 0
fi

step "Uploading DMGs"
# Uploaded first, and skipped when already present: a DMG for a given version is
# immutable, so re-uploading it on every release would waste minutes.
#
# "Already present" is decided by CONTENT, not by name. Skipping on the name
# alone is a silent-corruption trap: build-direct.sh names the DMG from
# MARKETING_VERSION only, so shipping a new build number without bumping the
# marketing version reuses `Synesthia-<same>.dmg`. The appcast would then carry
# the *new* build's signature while R2 kept serving the *old* bytes, and every
# client would fail EdDSA verification and silently never update. Compare
# hashes and refuse rather than skip.
while IFS= read -r name; do
	[[ -n "$name" ]] || continue

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
	wrangler_r2 r2 object put "$R2_BUCKET/downloads/$name" \
		--file "$RELEASES_DIR/$name" \
		--content-type application/x-apple-diskimage \
		--cache-control "public, max-age=31536000, immutable" \
		>/dev/null
done <<<"$FILES"

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
