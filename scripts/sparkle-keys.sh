#!/usr/bin/env bash
#
# Generate (or show) the Sparkle EdDSA signing key.
#
#   ./scripts/sparkle-keys.sh
#
# Run this ONCE, ever. It creates an ed25519 keypair, stores the private half in
# your login keychain, and prints the public half. Paste that public key into
# Synesthia-Direct-Info.plist as SUPublicEDKey; build-direct.sh refuses to build
# while the placeholder is still there.
#
# If a key already exists, generate_keys prints the existing public key instead
# of replacing it — so running this again is safe and is the way to recover the
# public half if you lose track of it.
#
# BACK THE PRIVATE KEY UP. It is the only thing that can sign an update your
# users' copies will accept. Export it with:
#
#   "$(./scripts/sparkle-keys.sh --path)/generate_keys" -x sparkle-private-key.txt
#
# …then put that file somewhere safe and delete the local copy. If it is lost,
# every existing install is stranded on its current version permanently and the
# only fix is asking people to download the app again by hand.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"
# shellcheck source=release.env
source "$REPO_ROOT/scripts/release.env"

fail() { printf '\n\033[1;31mFAILED: %s\033[0m\n' "$1" >&2; exit 1; }

SPARKLE_BIN_DIR="$(sparkle_bin)" || fail \
	"Sparkle's tools were not found. Build the 'Synesthia Direct' target once
        (make direct-fast) so SwiftPM fetches them, or export SPARKLE_BIN."

# `--path` just reports where the tools are, for the backup command above.
if [[ "${1:-}" == "--path" ]]; then
	echo "$SPARKLE_BIN_DIR"
	exit 0
fi

"$SPARKLE_BIN_DIR/generate_keys" "$@"

echo
echo "Next: put the public key above into Synesthia-Direct-Info.plist"
echo "      as the value of SUPublicEDKey, replacing REPLACE_WITH_SPARKLE_PUBLIC_KEY."
