#!/usr/bin/env bash
#
# Bump the app's version. One command, every place it is recorded.
#
#   ./scripts/bump-version.sh patch      # 1.0   -> 1.0.1
#   ./scripts/bump-version.sh minor      # 1.0.1 -> 1.1
#   ./scripts/bump-version.sh major      # 1.1   -> 2.0
#   ./scripts/bump-version.sh 2.5        # set it explicitly
#   ./scripts/bump-version.sh patch --dry-run
#
# The build number (CURRENT_PROJECT_VERSION / CFBundleVersion) is always
# incremented by one, whatever the level. That is the number Sparkle and the App
# Store actually compare; MARKETING_VERSION is only ever shown to a human.
#
# WHY THIS EXISTS
#
# The versions live in project.pbxproj as build settings, duplicated across
# every target × configuration — nine copies of each today. There is no
# Info.plist to edit and agvtool cannot help (it needs VERSIONING_SYSTEM =
# apple-generic, which conflicts with GENERATE_INFOPLIST_FILE here). Editing
# them by hand in Xcode updates whichever target is selected, so it is entirely
# possible to ship `Synesthia Direct` on a stale build number while the App
# Store target looks correct.
#
# It also refuses to leave MARKETING_VERSION alone, because build-direct.sh
# names the DMG `Synesthia-<MARKETING_VERSION>.dmg`. Two releases sharing a
# marketing version collide on that filename in R2 — see publish-release.sh,
# which now hard-fails on exactly that.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

PBXPROJ="Synesthia.xcodeproj/project.pbxproj"
CONSTS="web/src/consts.ts"

step() { printf '\n\033[1;36m==> %s\033[0m\n' "$1"; }
fail() { printf '\n\033[1;31mFAILED: %s\033[0m\n' "$1" >&2; exit 1; }

LEVEL=""
DRY_RUN=0
for arg in "$@"; do
	case "$arg" in
		--dry-run) DRY_RUN=1 ;;
		-h|--help) sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
		-*) fail "unknown option: $arg" ;;
		*) [[ -z "$LEVEL" ]] || fail "give exactly one level or version"; LEVEL="$arg" ;;
	esac
done
[[ -n "$LEVEL" ]] || fail "usage: $0 patch|minor|major|<version> [--dry-run]"

[[ -f "$PBXPROJ" ]] || fail "$PBXPROJ not found"

# ---------------------------------------------------------------- read current
#
# Every copy must already agree. If they have drifted, bumping would paper over
# it — and "which one was right?" is not a question worth answering later.
read_setting() {
	grep -o "$1 = [^;]*;" "$PBXPROJ" | sed "s/.*= //;s/;\$//" | sort -u
}

CUR_MV=$(read_setting MARKETING_VERSION)
CUR_BUILD=$(read_setting CURRENT_PROJECT_VERSION)

[[ $(printf '%s\n' "$CUR_MV" | wc -l | tr -d ' ') -eq 1 ]] \
	|| fail "MARKETING_VERSION disagrees across targets/configurations:
$(printf '%s\n' "$CUR_MV" | sed 's/^/          /')
        Set them all to the same value before bumping."
[[ $(printf '%s\n' "$CUR_BUILD" | wc -l | tr -d ' ') -eq 1 ]] \
	|| fail "CURRENT_PROJECT_VERSION disagrees across targets/configurations:
$(printf '%s\n' "$CUR_BUILD" | sed 's/^/          /')
        Set them all to the same value before bumping."

[[ "$CUR_BUILD" =~ ^[0-9]+$ ]] \
	|| fail "CURRENT_PROJECT_VERSION is '$CUR_BUILD'; expected a plain integer"

NEW_BUILD=$((CUR_BUILD + 1))

# ------------------------------------------------------------- compute the new
# Semver arithmetic in python: bash makes a meal of splitting and rejoining, and
# getting it subtly wrong here is the kind of thing nobody notices until an
# update doesn't offer itself.
NEW_MV=$(python3 - "$CUR_MV" "$LEVEL" <<'PY'
import re, sys

current, level = sys.argv[1], sys.argv[2]

parts = current.split('.')
if not (1 <= len(parts) <= 3) or not all(p.isdigit() for p in parts):
    sys.exit(f'MARKETING_VERSION "{current}" is not 1-3 numeric components')
major, minor, patch = (list(map(int, parts)) + [0, 0, 0])[:3]

if level == 'major':
    major, minor, patch = major + 1, 0, 0
elif level == 'minor':
    minor, patch = minor + 1, 0
elif level == 'patch':
    patch += 1
elif re.fullmatch(r'\d+(\.\d+){0,2}', level):
    explicit = (list(map(int, level.split('.'))) + [0, 0, 0])[:3]
    if explicit <= [major, minor, patch]:
        sys.exit(f'{level} is not greater than the current {current}')
    major, minor, patch = explicit
else:
    sys.exit(f'unknown level "{level}" — use patch, minor, major, or an explicit version')

# CFBundleShortVersionString takes 1-3 components; a trailing .0 is noise, so
# 1.1.0 renders as "1.1". A patch release keeps all three.
print(f'{major}.{minor}.{patch}' if patch else f'{major}.{minor}')
PY
) || fail "could not compute the new version"

step "Bumping $CUR_MV ($CUR_BUILD) -> $NEW_MV ($NEW_BUILD)"
MV_COUNT=$(grep -c "MARKETING_VERSION = " "$PBXPROJ" | tr -d ' ')
BUILD_COUNT=$(grep -c "CURRENT_PROJECT_VERSION = " "$PBXPROJ" | tr -d ' ')
echo "  $PBXPROJ : $MV_COUNT marketing, $BUILD_COUNT build"
echo "  $CONSTS  : RELEASE.version"

if [[ $DRY_RUN -eq 1 ]]; then
	step "Dry run — nothing written"
	exit 0
fi

# ------------------------------------------------------------------- write it
sed -i '' \
	-e "s/MARKETING_VERSION = [^;]*;/MARKETING_VERSION = $NEW_MV;/" \
	-e "s/CURRENT_PROJECT_VERSION = [^;]*;/CURRENT_PROJECT_VERSION = $NEW_BUILD;/" \
	"$PBXPROJ"

# The website shows the marketing version next to the download button. Not
# load-bearing, but it is the number users quote back at you in bug reports.
#
# Both quote styles are matched, and whichever the file already uses is
# preserved (\2 in the replacement). web/ has no Prettier config, so its .ts
# files get Prettier's defaults — double quotes — while the hand-written .astro
# files use single quotes and are never checked at all (prettier-plugin-astro
# isn't installed, so Prettier skips them). A single-quote-only pattern matched
# nothing here, and sed exits 0 on zero substitutions, so the bump silently
# skipped the website until the verify step below caught it.
#
# The closing quote is NOT a back-reference to the opening one: `sed -E` is
# POSIX ERE, which has no back-references in the *pattern* — `\2` there matches
# nothing and the substitution quietly does nothing again. `\2` in the
# replacement is fine, and is what carries the original quote style over.
if [[ -f "$CONSTS" ]]; then
	sed -i '' -E "s/^([[:space:]]*)version: (['\"])[^'\"]*['\"],/\1version: \2$NEW_MV\2,/" "$CONSTS"
fi

# --------------------------------------------------------------------- verify
step "Verifying"
plutil -lint "$PBXPROJ" >/dev/null || fail "project.pbxproj is no longer a valid plist — restore it with git"

AFTER_MV=$(read_setting MARKETING_VERSION)
AFTER_BUILD=$(read_setting CURRENT_PROJECT_VERSION)
[[ "$AFTER_MV" == "$NEW_MV" ]] \
	|| fail "MARKETING_VERSION did not settle on $NEW_MV (got: $AFTER_MV)"
[[ "$AFTER_BUILD" == "$NEW_BUILD" ]] \
	|| fail "CURRENT_PROJECT_VERSION did not settle on $NEW_BUILD (got: $AFTER_BUILD)"
echo "  project.pbxproj : all $MV_COUNT/$BUILD_COUNT settings now $NEW_MV / $NEW_BUILD"

if [[ -f "$CONSTS" ]]; then
	grep -qF "version: \"$NEW_MV\"," "$CONSTS" || grep -qF "version: '$NEW_MV'," "$CONSTS" \
		|| fail "$CONSTS still shows the old version"
	echo "  consts.ts       : RELEASE.version = $NEW_MV"
fi

step "Done"
cat <<EOF
  Version : $NEW_MV
  Build   : $NEW_BUILD

Next:
  make direct           # archive, sign, notarize, staple, DMG
  make appcast          # add it to the feed
  make publish-release  # upload to R2

RELEASE.size in $CONSTS is not updated automatically — the DMG's
size is only known after 'make direct' prints it.
EOF
