#!/usr/bin/env bash
#
# Regenerate the Sparkle appcast for the direct-download build.
#
# Sparkle clients poll an "appcast" — an RSS feed listing available versions,
# each entry signed with an EdDSA key that only you hold. A client will not
# install an update whose signature doesn't verify against the SUPublicEDKey
# baked into the app, which is what stops a compromised web host from shipping
# malware to your users.
#
#   ./scripts/make-appcast.sh              # fetch current feed, regenerate
#   ./scripts/make-appcast.sh --offline    # don't fetch; use what's in build/releases
#
# Expects the notarized DMG(s) from build-direct.sh in build/. Writes the feed
# to build/releases/appcast.xml and stops there — uploading is a separate step,
# ./scripts/publish-release.sh, so you can read the diff before it goes live.
#
# ONE-TIME SETUP — generate the signing key:
#
#   make sparkle-keys
#
# It stores the private half in your login keychain and prints the public half,
# which goes into Synesthia-Direct-Info.plist as SUPublicEDKey. Back the private
# key up somewhere safe: losing it means you can never ship another update to
# existing installs, and there is no recovery path but asking every user to
# re-download by hand.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"
# shellcheck source=release.env
source "$REPO_ROOT/scripts/release.env"

OFFLINE=0
[[ "${1:-}" == "--offline" ]] && OFFLINE=1

step() { printf '\n\033[1;36m==> %s\033[0m\n' "$1"; }
fail() { printf '\n\033[1;31mFAILED: %s\033[0m\n' "$1" >&2; exit 1; }

SPARKLE_BIN_DIR="$(sparkle_bin)" || fail \
	"Sparkle's tools were not found. Build the 'Synesthia Direct' target once
        (make direct-fast) so SwiftPM fetches them, or download a Sparkle
        release and export SPARKLE_BIN=/path/to/Sparkle-2.x/bin"
echo "Using Sparkle tools from: $SPARKLE_BIN_DIR"

step "Collecting releases"
mkdir -p "$RELEASES_DIR"
shopt -s nullglob
for dmg in build/Synesthia-*.dmg; do
	cp -f "$dmg" "$RELEASES_DIR/"
	echo "  $(basename "$dmg")"
done
shopt -u nullglob
[[ -n "$(find "$RELEASES_DIR" -maxdepth 1 -name '*.dmg' -print -quit)" ]] \
	|| fail "no DMGs found; run build-direct.sh first"

step "Staging release notes"
# generate_appcast reads release notes from a file sitting next to the archive
# whose basename matches it — Synesthia-1.2.dmg -> Synesthia-1.2.html — and
# inlines it into that item's <description> as CDATA, provided it is an HTML
# fragment with no DOCTYPE or body tags.
#
# HTML, not the .md that generate_appcast also accepts: a markdown file is NOT
# embedded, it becomes a <sparkle:releaseNotesLink>, which means a second
# artifact to upload per release and a Pages Function that serves a third file
# type (isSafeArtifactName allows only .dmg and .delta). The notes are
# authored as markdown in docs/releases/<version>.md and rendered here; see
# scripts/release-notes.py.
#
# Only *new* items get notes — generate_appcast never rewrites an item already
# in the feed — so a missing file for an older DMG is expected and silent. A
# missing file for the version being published is not, and says so.
# Newest by mtime, without `ls -t | head -1`: `head` closing the pipe SIGPIPEs
# the producer, and `set -o pipefail` turns that into a failed run. `sed -n
# '1s///p'` reads its input to the end, so there is nothing to SIGPIPE.
NEWEST_DMG=$(find "$RELEASES_DIR" -maxdepth 1 -name '*.dmg' -exec stat -f '%m %N' {} + \
	| sort -rn | sed -n '1s/^[0-9]* //p')
for dmg in "$RELEASES_DIR"/*.dmg; do
	base=$(basename "$dmg" .dmg)          # Synesthia-1.2
	version="${base#Synesthia-}"
	if [[ -f "docs/releases/$version.md" ]]; then
		python3 scripts/release-notes.py render "$version" --out "$RELEASES_DIR/$base.html" >/dev/null \
			|| fail "docs/releases/$version.md failed to render"
		echo "  $base.html  <- docs/releases/$version.md"
	else
		rm -f "$RELEASES_DIR/$base.html"
		if [[ "$dmg" == "$NEWEST_DMG" ]]; then
			echo "  no docs/releases/$version.md — $base will ship with NO release notes."
			echo "  (write them, or run ./scripts/bump-version.sh which drafts them)"
		fi
	fi
done

# generate_appcast re-uses an appcast.xml already sitting in the archives
# directory and only *adds* entries to it. That is the whole reason we pull the
# published feed down first: without it, a regeneration from a directory holding
# only the newest DMG would silently produce a feed with a single item and drop
# every older version's entry — including the ones users are updating *from*.
if [[ $OFFLINE -eq 0 ]]; then
	step "Fetching the published appcast so history is preserved"
	# Fetched to a scratch file, not straight over the local appcast. A failed
	# `r2 object get` still creates a zero-byte file, so writing directly would
	# either hand generate_appcast an empty feed to parse or clobber a good local
	# one — losing exactly the history this step exists to preserve.
	FETCHED="$RELEASES_DIR/.appcast-fetched.xml"
	rm -f "$FETCHED"
	if wrangler_r2 r2 object get "$R2_BUCKET/appcast.xml" --file "$FETCHED" 2>/dev/null \
		&& [[ -s "$FETCHED" ]]; then
		mv -f "$FETCHED" "$RELEASES_DIR/appcast.xml"
		echo "  merged with the live feed ($(wc -c <"$RELEASES_DIR/appcast.xml" | tr -d ' ') bytes)"
	else
		rm -f "$FETCHED"
		if [[ -s "$RELEASES_DIR/appcast.xml" ]]; then
			echo "  could not fetch the published feed — keeping the local appcast.xml"
			echo "  (verify it still lists every shipped version before publishing)"
		else
			echo "  no published appcast yet — generating a fresh one"
			echo "  (if this is NOT your first release, stop: publishing now would"
			echo "   truncate the feed. Check your R2 credentials and bucket name.)"
		fi
	fi
fi

step "Verifying every release is notarized and stapled"
# An un-stapled DMG in the feed means users get a Gatekeeper warning on update.
for dmg in "$RELEASES_DIR"/*.dmg; do
	xcrun stapler validate "$dmg" >/dev/null 2>&1 \
		|| fail "$(basename "$dmg") is not stapled — notarize it before publishing"
	echo "  $(basename "$dmg"): stapled"
done

step "Generating the appcast"
# Signing uses the private EdDSA key in the login keychain (account "ed25519").
# Deltas are only produced for versions whose archives are present locally; we
# keep just the newest few, so most updates are full downloads. At ~4 MB that is
# a deliberate trade, not an oversight.
"$SPARKLE_BIN_DIR/generate_appcast" \
	--download-url-prefix "$DOWNLOAD_BASE/" \
	--link "$SITE_URL" \
	"$RELEASES_DIR"

APPCAST="$RELEASES_DIR/appcast.xml"
[[ -f "$APPCAST" ]] || fail "generate_appcast produced no appcast.xml"

# Did the notes actually make it in? generate_appcast only writes a description
# for items it *adds*; an item already present in the fetched feed is left
# exactly as it was. So a note file that arrived late — or one written after the
# first `make appcast` of a version — is silently ignored, and the first anyone
# notices is an empty update window. Report it here instead.
step "Checking the newest item's release notes"
python3 - "$APPCAST" <<'PY'
import sys, xml.etree.ElementTree as ET

SPARKLE = 'http://www.andymatuschak.org/xml-namespaces/sparkle'
items = []
for item in ET.parse(sys.argv[1]).getroot().iterfind('./channel/item'):
    enclosure = item.find('enclosure')
    version = (item.findtext('{%s}version' % SPARKLE) or '').strip()
    if not version and enclosure is not None:
        version = (enclosure.get('{%s}version' % SPARKLE) or '').strip()
    items.append((int(version) if version.isdigit() else -1, item))

if not items:
    sys.exit('the appcast has no items')

_, newest = max(items, key=lambda pair: pair[0])
short = (newest.findtext('{%s}shortVersionString' % SPARKLE) or '?').strip()
description = (newest.findtext('description') or '').strip()
link = newest.find('{%s}releaseNotesLink' % SPARKLE)

if description:
    print(f'  {short}: {len(description)} characters of embedded release notes')
elif link is not None:
    print(f'  {short}: release notes linked at {(link.text or "").strip()}')
    print('     Linked notes are a separate upload; this project embeds instead.')
else:
    print(f'  {short}: NO release notes — the update window will be empty.')
    print('     If docs/releases/<version>.md exists, this version was already in')
    print('     the feed and generate_appcast left it alone. Delete that <item>')
    print('     from build/releases/appcast.xml and re-run to regenerate it.')
PY

step "Done"
echo "  Appcast: $APPCAST"
echo
echo "Review it, then publish with:"
echo "      ./scripts/publish-release.sh"
