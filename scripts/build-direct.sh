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

SCHEME="Synesthia"
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
