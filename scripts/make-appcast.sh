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

step "Done"
echo "  Appcast: $APPCAST"
echo
echo "Review it, then publish with:"
echo "      ./scripts/publish-release.sh"
