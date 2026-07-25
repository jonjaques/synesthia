#!/usr/bin/env bash
#
# Build, sign, notarize, staple and package the direct-download build of
# Synesthia — the notarized copy served from synesthia.app, not the Mac App
# Store one. Uses the `Direct` configuration, which includes the Music.app
# source and its Apple Events entitlements.
#
#   ./scripts/build-direct.sh                 # full run, including notarization
#   ./scripts/build-direct.sh --skip-notarize # build + sign + DMG only
#
# One-time setup — store notarization credentials in the keychain:
#
#   xcrun notarytool store-credentials "$NOTARY_PROFILE" \
#       --apple-id you@example.com --team-id 43Z6G73JW8 \
#       --password <app-specific-password>
#
# App-specific passwords come from https://account.apple.com → Sign-In and
# Security. Your normal Apple password will not work.
set -euo pipefail

cd "$(dirname "$0")/.."

# The `Synesthia Direct` target is the one that links Sparkle. The plain
# `Synesthia` target is the App Store build and has no updater — archiving that
# one here would produce a direct download that can never update itself.
SCHEME="Synesthia Direct"
CONFIGURATION="Direct"
APP_NAME="Synesthia"
NOTARY_PROFILE="${NOTARY_PROFILE:-SYNESTHIA_NOTARY}"

BUILD_DIR="build"
ARCHIVE="$BUILD_DIR/$APP_NAME-Direct.xcarchive"
EXPORT_DIR="$BUILD_DIR/direct"
APP="$EXPORT_DIR/$APP_NAME.app"
STAGE="$BUILD_DIR/dmg-stage"

SKIP_NOTARIZE=0
[[ "${1:-}" == "--skip-notarize" ]] && SKIP_NOTARIZE=1

step() { printf '\n\033[1;36m==> %s\033[0m\n' "$1"; }
fail() { printf '\n\033[1;31mFAILED: %s\033[0m\n' "$1" >&2; exit 1; }

step "Cleaning previous output"
rm -rf "$ARCHIVE" "$EXPORT_DIR" "$STAGE"
mkdir -p "$BUILD_DIR"

step "Archiving ($CONFIGURATION)"
xcodebuild archive \
	-project "$APP_NAME.xcodeproj" \
	-scheme "$SCHEME" \
	-configuration "$CONFIGURATION" \
	-archivePath "$ARCHIVE" \
	-destination 'generic/platform=macOS' \
	| grep -E "error:|warning:|ARCHIVE" || true
[[ -d "$ARCHIVE" ]] || fail "no archive produced"

step "Exporting with Developer ID"
xcodebuild -exportArchive \
	-archivePath "$ARCHIVE" \
	-exportOptionsPlist scripts/ExportOptions-Direct.plist \
	-exportPath "$EXPORT_DIR" \
	| grep -E "error:|EXPORT" || true
[[ -d "$APP" ]] || fail "no app exported — check signing identity and profiles"

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")
BUILD_NUM=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$APP/Contents/Info.plist")
DMG="$BUILD_DIR/$APP_NAME-$VERSION.dmg"

step "Verifying the signature"
codesign --verify --deep --strict --verbose=2 "$APP"
# Hardened runtime is required for notarization; fail loudly rather than
# discovering it after a round trip to Apple.
codesign -d --verbose=2 "$APP" 2>&1 | grep -q "flags=.*runtime" \
	|| fail "hardened runtime is not enabled"
# get-task-allow must not survive into a distributed build.
if codesign -d --entitlements - --xml "$APP" 2>/dev/null | grep -q "get-task-allow"; then
	fail "com.apple.security.get-task-allow is present — this is a debug signature"
fi
echo "Signature OK — universal: $(lipo -archs "$APP/Contents/MacOS/$APP_NAME")"

step "Verifying Sparkle"
# Everything below is silent-failure territory: the app launches, looks fine,
# and simply never updates. Cheaper to catch here than in the field.
[[ -d "$APP/Contents/Frameworks/Sparkle.framework" ]] \
	|| fail "Sparkle.framework is not embedded — did you archive the 'Synesthia' target by mistake?"

ED_KEY=$(/usr/libexec/PlistBuddy -c "Print :SUPublicEDKey" "$APP/Contents/Info.plist" 2>/dev/null || true)
[[ -n "$ED_KEY" ]] \
	|| fail "SUPublicEDKey is missing from Info.plist — Sparkle cannot verify any update"
[[ "$ED_KEY" != "REPLACE_WITH_SPARKLE_PUBLIC_KEY" ]] \
	|| fail "SUPublicEDKey is still the placeholder. Run 'make sparkle-keys' and paste the
        printed public key into Synesthia-Direct-Info.plist. Shipping the
        placeholder means no update will ever pass signature verification."

FEED=$(/usr/libexec/PlistBuddy -c "Print :SUFeedURL" "$APP/Contents/Info.plist" 2>/dev/null || true)
[[ -n "$FEED" ]] || fail "SUFeedURL is missing from Info.plist"
[[ "$FEED" == https://* ]] || fail "SUFeedURL is not HTTPS: $FEED"

# A sandboxed app needs Installer.xpc plus the two mach-lookup exceptions. If
# the entitlements and the Info.plist switch disagree, updates fail at install
# time — the download succeeds and then nothing happens.
[[ -d "$APP/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/Installer.xpc" ]] \
	|| fail "Installer.xpc is missing from Sparkle.framework"
APP_ENTS=$(codesign -d --entitlements - --xml "$APP" 2>/dev/null)
grep -q -- "-spks" <<<"$APP_ENTS" && grep -q -- "-spki" <<<"$APP_ENTS" \
	|| fail "the -spks/-spki mach-lookup exceptions are missing; a sandboxed app cannot reach Installer.xpc"

# Notarization rejects nested code that isn't hardened, and the error it gives
# names the XPC service rather than the app, which is confusing after the fact.
for xpc in "$APP/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/"*.xpc; do
	codesign -d --verbose=2 "$xpc" 2>&1 | grep -q "flags=.*runtime" \
		|| fail "$(basename "$xpc") is not signed with the hardened runtime"
done
echo "  framework, Installer.xpc, EdDSA key, HTTPS feed and entitlements all present"
echo "  feed: $FEED"

step "Building $DMG"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create \
	-volname "$APP_NAME $VERSION" \
	-srcfolder "$STAGE" \
	-ov -format ULFO \
	"$DMG" >/dev/null
rm -rf "$STAGE"

if [[ $SKIP_NOTARIZE -eq 1 ]]; then
	step "Skipping notarization (--skip-notarize)"
	echo "Unnotarized DMG: $DMG"
	echo "Gatekeeper will reject this on any other Mac."
	exit 0
fi

step "Notarizing (this waits on Apple; usually a few minutes)"
if ! xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait; then
	echo
	echo "If this failed on credentials, run:"
	echo "  xcrun notarytool store-credentials \"$NOTARY_PROFILE\" \\"
	echo "      --apple-id <you@example.com> --team-id 43Z6G73JW8 --password <app-specific>"
	echo "For a rejection, get the details with:"
	echo "  xcrun notarytool log <submission-id> --keychain-profile \"$NOTARY_PROFILE\""
	fail "notarization did not succeed"
fi

step "Stapling the ticket"
# Staple the app too, so a user who drags it out of the DMG still validates
# offline.
xcrun stapler staple "$APP"
xcrun stapler staple "$DMG"

step "Verifying Gatekeeper acceptance"
xcrun stapler validate "$DMG"
spctl --assess --type open --context context:primary-signature -vv "$DMG"

step "Done"
echo "  DMG      : $DMG"
echo "  Version  : $VERSION ($BUILD_NUM)"
echo "  Size     : $(du -h "$DMG" | cut -f1)"
echo
echo "Next: publish the DMG, then regenerate the Sparkle appcast with"
echo "      ./scripts/make-appcast.sh"
