#!/usr/bin/env bash
#
# Build and validate the Mac App Store submission of Synesthia.
#
# Uses the `Release` configuration, which compiles out the Music.app source
# (no MUSIC_APP_SOURCE) and signs with Synesthia.entitlements — no Apple
# Events entitlements at all. See docs/app-store-launch-plan.md §B5.
#
#   ./scripts/build-appstore.sh            # archive, export, validate
#   ./scripts/build-appstore.sh --upload   # …and upload to App Store Connect
#
# Authentication uses an App Store Connect API key. Either put a .p8 in
# ~/.appstoreconnect/private_keys/ and export:
#
#   export ASC_KEY_ID=XXXXXXXXXX
#   export ASC_ISSUER_ID=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
#
# …or replace the authentication flags below with --apple-id/--password.
set -euo pipefail

cd "$(dirname "$0")/.."

SCHEME="Synesthia"
CONFIGURATION="Release"
APP_NAME="Synesthia"

BUILD_DIR="build"
ARCHIVE="$BUILD_DIR/$APP_NAME-AppStore.xcarchive"
EXPORT_DIR="$BUILD_DIR/appstore"

DO_UPLOAD=0
[[ "${1:-}" == "--upload" ]] && DO_UPLOAD=1

step() { printf '\n\033[1;36m==> %s\033[0m\n' "$1"; }
fail() { printf '\n\033[1;31mFAILED: %s\033[0m\n' "$1" >&2; exit 1; }

step "Cleaning previous output"
rm -rf "$ARCHIVE" "$EXPORT_DIR"
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

ARCHIVED_APP="$ARCHIVE/Products/Applications/$APP_NAME.app"

step "Pre-flight checks on the archive"
# Each of these has bitten this project or is an outright rejection.
ARCH_LIST=$(lipo -archs "$ARCHIVED_APP/Contents/MacOS/$APP_NAME")
echo "  architectures        : $ARCH_LIST"
case "$ARCH_LIST" in
	*arm64*x86_64*|*x86_64*arm64*) ;;
	*) fail "archive is not universal (got: $ARCH_LIST); macOS 26 still supports Intel" ;;
esac

if codesign -d --entitlements - --xml "$ARCHIVED_APP" 2>/dev/null | grep -q "get-task-allow"; then
	fail "com.apple.security.get-task-allow survived into the archive"
fi
echo "  get-task-allow       : absent"

if codesign -d --entitlements - --xml "$ARCHIVED_APP" 2>/dev/null | grep -q "apple-events"; then
	fail "Apple Events entitlements are present — this must be the Direct config, not Release"
fi
echo "  apple-events         : absent (correct for the App Store build)"

if strings "$ARCHIVED_APP/Contents/MacOS/$APP_NAME" | grep -q 'tell application "Music"'; then
	fail "AppleScript source is compiled in — MUSIC_APP_SOURCE leaked into Release"
fi
echo "  Music.app AppleScript: absent"

# Sparkle is linked by the `Synesthia Direct` target only. If it ever shows up
# here, the wrong target was archived — and an App Store app that bundles its
# own updater (and an XPC service that installs code) is a rejection under
# guideline 2.4.5. Check the framework, the link, and the Info.plist keys
# separately: any one of them appearing alone still means something is wrong.
[[ ! -d "$ARCHIVED_APP/Contents/Frameworks/Sparkle.framework" ]] \
	|| fail "Sparkle.framework is embedded — the App Store build must not contain an updater"
if otool -L "$ARCHIVED_APP/Contents/MacOS/$APP_NAME" | grep -qi sparkle; then
	fail "the binary links Sparkle — wrong target archived (want scheme 'Synesthia', not 'Synesthia Direct')"
fi
if /usr/libexec/PlistBuddy -c "Print :SUFeedURL" "$ARCHIVED_APP/Contents/Info.plist" >/dev/null 2>&1; then
	fail "SUFeedURL is in Info.plist — the App Store build must advertise no update feed"
fi
echo "  Sparkle              : absent (framework, link and Info.plist keys)"

[[ -f "$ARCHIVED_APP/Contents/Resources/PrivacyInfo.xcprivacy" ]] \
	|| fail "PrivacyInfo.xcprivacy is missing from the bundle"
echo "  privacy manifest     : present"

[[ -f "$ARCHIVED_APP/Contents/Resources/DemoLoop.m4a" ]] \
	|| fail "the bundled demo track is missing — the zero-permission path would be dead"
echo "  demo track           : present"

/usr/libexec/PlistBuddy -c "Print :ITSAppUsesNonExemptEncryption" \
	"$ARCHIVED_APP/Contents/Info.plist" >/dev/null 2>&1 \
	|| fail "ITSAppUsesNonExemptEncryption is missing; every upload will prompt"
echo "  export compliance    : pre-answered"

step "Exporting for the App Store"
xcodebuild -exportArchive \
	-archivePath "$ARCHIVE" \
	-exportOptionsPlist scripts/ExportOptions-AppStore.plist \
	-exportPath "$EXPORT_DIR" \
	| grep -E "error:|EXPORT" || true

PKG=$(find "$EXPORT_DIR" -maxdepth 1 -name '*.pkg' | head -1)
[[ -n "$PKG" ]] || fail "no .pkg exported — check the Mac App Store provisioning profile"

if [[ -z "${ASC_KEY_ID:-}" || -z "${ASC_ISSUER_ID:-}" ]]; then
	echo
	echo "ASC_KEY_ID / ASC_ISSUER_ID are not set, so validation is being skipped."
	echo "Exported package: $PKG"
	exit 0
fi

step "Validating with App Store Connect"
xcrun altool --validate-app -f "$PKG" -t macos \
	--apiKey "$ASC_KEY_ID" --apiIssuer "$ASC_ISSUER_ID" \
	|| fail "validation rejected the package"

if [[ $DO_UPLOAD -eq 1 ]]; then
	step "Uploading to App Store Connect"
	xcrun altool --upload-app -f "$PKG" -t macos \
		--apiKey "$ASC_KEY_ID" --apiIssuer "$ASC_ISSUER_ID" \
		|| fail "upload failed"
	echo "Uploaded. Processing takes a few minutes before the build appears."
else
	step "Done (not uploaded)"
	echo "  Package: $PKG"
	echo "  Re-run with --upload to send it to App Store Connect."
fi
