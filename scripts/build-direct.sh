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

# NEVER pipe into `grep -q` here. `set -o pipefail` is on, and `grep -q` exits
# the moment it matches — which closes the pipe, kills the producer with SIGPIPE
# (exit 141), and makes the whole pipeline "fail" even though the check passed.
# Worse, for the must-NOT-match assertions below it fails the other way: a real
# leak makes grep match, the pipeline reports non-zero, `if` reads that as
# "clean", and the guard silently doesn't fire. Capture first, match against the
# variable. (Same trap as `tr | head` in take-screenshots.sh.)
#
# Note codesign writes all of this to stderr, hence the 2>&1 on the capture.
SIG_INFO=$(codesign -d --verbose=2 "$APP" 2>&1)

# Hardened runtime is required for notarization; fail loudly rather than
# discovering it after a round trip to Apple.
grep -q "flags=.*runtime" <<<"$SIG_INFO" \
	|| fail "hardened runtime is not enabled"

# Reuse whatever identity actually signed the app to sign the disk image, rather
# than looking one up — they must match, and hardcoding a second copy of the
# certificate name is how they drift apart.
SIGN_ID=$(awk -F'Authority=' '/^Authority=Developer ID Application:/ {print $2; exit}' <<<"$SIG_INFO")
[[ -n "$SIGN_ID" ]] \
	|| fail "the app is not signed by a Developer ID Application certificate"

# get-task-allow must not survive into a distributed build.
APP_ENTS=$(codesign -d --entitlements - --xml "$APP" 2>/dev/null || true)
if grep -q "get-task-allow" <<<"$APP_ENTS"; then
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

# `Current` is a symlink to the real version directory (`B` today). Going
# through the symlink means this keeps working if Sparkle ever bumps it.
SPARKLE_VERSION_DIR="$APP/Contents/Frameworks/Sparkle.framework/Versions/Current"

# A sandboxed app needs Installer.xpc plus the two mach-lookup exceptions. If
# the entitlements and the Info.plist switch disagree, updates fail at install
# time — the download succeeds and then nothing happens.
[[ -d "$SPARKLE_VERSION_DIR/XPCServices/Installer.xpc" ]] \
	|| fail "Installer.xpc is missing from Sparkle.framework"
grep -q -- "-spks" <<<"$APP_ENTS" && grep -q -- "-spki" <<<"$APP_ENTS" \
	|| fail "the -spks/-spki mach-lookup exceptions are missing; a sandboxed app cannot reach Installer.xpc"

# Notarization rejects nested code that isn't hardened, and the error it gives
# names the XPC service rather than the app, which is confusing after the fact.
# Sparkle also ships Autoupdate and Updater.app alongside the XPC services, and
# notarization judges those too — check every nested executable, not just .xpc.
for nested in \
	"$SPARKLE_VERSION_DIR/XPCServices/"*.xpc \
	"$SPARKLE_VERSION_DIR/Updater.app" \
	"$SPARKLE_VERSION_DIR/Autoupdate"
do
	[[ -e "$nested" ]] || continue
	NESTED_INFO=$(codesign -d --verbose=2 "$nested" 2>&1)
	grep -q "flags=.*runtime" <<<"$NESTED_INFO" \
		|| fail "$(basename "$nested") is not signed with the hardened runtime"
	echo "  $(basename "$nested"): hardened"
done
echo "  framework, Installer.xpc, EdDSA key, HTTPS feed and entitlements all present"
echo "  feed: $FEED"

notarize() {
	# Apple's notary service, waited on synchronously. Usually a few minutes.
	if ! xcrun notarytool submit "$1" --keychain-profile "$NOTARY_PROFILE" --wait; then
		echo
		echo "If this failed on credentials, run:"
		echo "  xcrun notarytool store-credentials \"$NOTARY_PROFILE\" \\"
		echo "      --apple-id <you@example.com> --team-id 43Z6G73JW8 --password <app-specific>"
		echo "For a rejection, get the details with:"
		echo "  xcrun notarytool log <submission-id> --keychain-profile \"$NOTARY_PROFILE\""
		fail "notarization did not succeed for $(basename "$1")"
	fi
}

# The app is notarized and stapled BEFORE the disk image is built, because the
# DMG is made from a *copy* of it. Stapling $APP after the copy — which is what
# this script used to do — leaves the app inside the DMG without a ticket, so
# the one the user actually ends up running in /Applications can only be
# validated online. That also matters for Sparkle, which extracts this app out
# of the DMG and installs it directly.
#
# The cost is a second trip to the notary service: the DMG is a different file
# with a different hash and needs its own submission.
if [[ $SKIP_NOTARIZE -eq 0 ]]; then
	step "Notarizing the app (1 of 2)"
	APP_ZIP="$BUILD_DIR/$APP_NAME-app.zip"
	rm -f "$APP_ZIP"
	# ditto, not zip: it preserves the bundle's symlinks and extended attributes,
	# which a plain zip mangles and notarization then rejects.
	ditto -c -k --keepParent "$APP" "$APP_ZIP"
	notarize "$APP_ZIP"
	rm -f "$APP_ZIP"

	step "Stapling the app"
	xcrun stapler staple "$APP"
	xcrun stapler validate "$APP"
fi

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

step "Signing the DMG"
# hdiutil produces an unsigned disk image. Notarizing and stapling it is not a
# substitute: Gatekeeper's primary-signature assessment looks for a signature
# and reports "no usable signature" without one, which is exactly what the
# spctl check below used to trip on. Sign with the same identity as the app.
codesign --sign "$SIGN_ID" --timestamp "$DMG"
codesign --verify --verbose=2 "$DMG"
echo "Signed with: $SIGN_ID"

if [[ $SKIP_NOTARIZE -eq 1 ]]; then
	step "Skipping notarization (--skip-notarize)"
	echo "Signed but unnotarized DMG: $DMG"
	echo "Gatekeeper will reject this on any other Mac."
	exit 0
fi

step "Notarizing the DMG (2 of 2)"
notarize "$DMG"

step "Stapling the DMG"
xcrun stapler staple "$DMG"

step "Verifying Gatekeeper acceptance"
xcrun stapler validate "$DMG"
# --type open is the assessment a user's Mac makes when opening a downloaded
# disk image; --type exec is the one it makes when launching the app inside.
# Both have to pass, and they are separate signatures and separate tickets.
spctl --assess --type open --context context:primary-signature -vv "$DMG"
spctl --assess --type exec -vv "$APP"

step "Done"
echo "  DMG      : $DMG"
echo "  Version  : $VERSION ($BUILD_NUM)"
# `du` reports allocated blocks, which for this DMG reads 5.1M against a real
# size of 4.35 MB — and that number ends up on the website. Report the bytes.
echo "  Size     : $(stat -f '%z' "$DMG") bytes ($(python3 -c "import sys;print(f'{int(sys.argv[1])/1_000_000:.1f} MB')" "$(stat -f '%z' "$DMG")"))"
echo
echo "Next: publish the DMG, then regenerate the Sparkle appcast with"
echo "      ./scripts/make-appcast.sh"
