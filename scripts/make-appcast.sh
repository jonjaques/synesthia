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
#   ./scripts/make-appcast.sh
#
# Expects the notarized DMG(s) from build-direct.sh in build/, and Sparkle's
# CLI tools. Point SPARKLE_BIN at the directory containing `generate_appcast`
# if it isn't on PATH:
#
#   export SPARKLE_BIN=~/Downloads/Sparkle-2.x/bin
#
# One-time setup — generate the signing key (stores the private half in your
# login keychain and prints the public half):
#
#   "$SPARKLE_BIN/generate_keys"
#
# Put the printed public key in the `Direct` build configuration as
# INFOPLIST_KEY_SUPublicEDKey. Back the private key up somewhere safe: losing
# it means you can never ship another update to existing installs.
set -euo pipefail

cd "$(dirname "$0")/.."

RELEASES_DIR="${RELEASES_DIR:-build/releases}"
FEED_URL="${FEED_URL:-https://synesthia.app/appcast.xml}"
DOWNLOAD_BASE="${DOWNLOAD_BASE:-https://synesthia.app/downloads}"
WEB_PUBLIC="web/public"

step() { printf '\n\033[1;36m==> %s\033[0m\n' "$1"; }
fail() { printf '\n\033[1;31mFAILED: %s\033[0m\n' "$1" >&2; exit 1; }

GENERATE_APPCAST="$(command -v generate_appcast || true)"
if [[ -n "${SPARKLE_BIN:-}" && -x "$SPARKLE_BIN/generate_appcast" ]]; then
	GENERATE_APPCAST="$SPARKLE_BIN/generate_appcast"
fi
[[ -n "$GENERATE_APPCAST" ]] || fail \
	"generate_appcast not found. Download the Sparkle release tools and set SPARKLE_BIN."

step "Collecting releases"
mkdir -p "$RELEASES_DIR"
shopt -s nullglob
for dmg in build/Synesthia-*.dmg; do
	cp -f "$dmg" "$RELEASES_DIR/"
	echo "  $(basename "$dmg")"
done
shopt -u nullglob
[[ -n "$(ls -A "$RELEASES_DIR" 2>/dev/null)" ]] || fail "no DMGs found; run build-direct.sh first"

step "Verifying every release is notarized and stapled"
# An un-stapled DMG in the feed means users get a Gatekeeper warning on update.
for dmg in "$RELEASES_DIR"/*.dmg; do
	xcrun stapler validate "$dmg" >/dev/null 2>&1 \
		|| fail "$(basename "$dmg") is not stapled — notarize it before publishing"
	echo "  $(basename "$dmg"): stapled"
done

step "Generating the appcast"
"$GENERATE_APPCAST" \
	--download-url-prefix "$DOWNLOAD_BASE/" \
	--link "https://synesthia.app" \
	"$RELEASES_DIR"

APPCAST="$RELEASES_DIR/appcast.xml"
[[ -f "$APPCAST" ]] || fail "generate_appcast produced no appcast.xml"

step "Publishing into $WEB_PUBLIC"
mkdir -p "$WEB_PUBLIC/downloads"
cp -f "$APPCAST" "$WEB_PUBLIC/appcast.xml"
cp -f "$RELEASES_DIR"/*.dmg "$WEB_PUBLIC/downloads/"

step "Done"
echo "  Appcast   : $WEB_PUBLIC/appcast.xml  (serve at $FEED_URL)"
echo "  Downloads : $WEB_PUBLIC/downloads/"
echo
echo "Check that the app's SUFeedURL matches $FEED_URL before shipping."
