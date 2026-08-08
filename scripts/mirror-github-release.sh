#!/usr/bin/env bash
#
# Mirror a published release to the GitHub Releases tab.
#
#   ./scripts/mirror-github-release.sh              # the version in VERSION
#   ./scripts/mirror-github-release.sh 1.2.1        # a specific version
#   ./scripts/mirror-github-release.sh 1.2 --dry-run
#   ./scripts/mirror-github-release.sh 1.2 --allow-unmerged
#
# Creates (or updates) the GitHub Release for `v<version>`: title
# "Synesthia <version>", body taken verbatim from docs/releases/<version>.md,
# with Synesthia-<version>.dmg attached.
#
# R2 STAYS AUTHORITATIVE. Sparkle's appcast points at synesthia.app/downloads/…
# and must keep doing so; this is a mirror for humans who land on the repository
# and find an empty Releases tab with no way to see what shipped or when.
# Nothing about the publish order changes, and nothing here is a source Sparkle
# reads. Run it AFTER publish-release.sh, never instead of it.
#
# Two guards, both borrowed from publish-release.sh because they are the same
# two lies told in a more visible place:
#
#   1. `v<version>` must be an ancestor of origin/main. A GitHub Release for an
#      orphaned tag is the exact failure that lost v1.2 — a release whose bytes
#      correspond to a commit no branch can reach — except now it has a download
#      button on the repository's front page.
#
#   2. The attached DMG must be byte-identical to the one R2 serves. Two
#      download buttons for one version that hand out different bytes is worse
#      than one download button, and it is not hypothetical: the DMG is named
#      from MARKETING_VERSION alone, so a rebuilt build number reuses the
#      filename.
#
# Idempotent, like every other script here: re-running against an existing
# release edits it rather than failing, and the asset upload uses --clobber. A
# run that dies partway is recovered by running it again.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"
# shellcheck source=release.env
source "$REPO_ROOT/scripts/release.env"

VERSION=""
DRY_RUN=0
ALLOW_UNMERGED=0
while [[ $# -gt 0 ]]; do
	case "$1" in
		--dry-run) DRY_RUN=1 ;;
		--allow-unmerged) ALLOW_UNMERGED=1 ;;
		-h|--help) sed -n '2,/^set -euo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; exit 0 ;;
		-*) printf 'unknown option: %s\n' "$1" >&2; exit 2 ;;
		*)
			[[ -z "$VERSION" ]] || { printf 'more than one version given: %s\n' "$1" >&2; exit 2; }
			VERSION="$1"
			;;
	esac
	shift
done

step() { printf '\n\033[1;36m==> %s\033[0m\n' "$1"; }
fail() { printf '\n\033[1;31mFAILED: %s\033[0m\n' "$1" >&2; exit 1; }

# Same nonce trick as publish-release.sh: a probe must never be able to install
# a cache entry on the key real clients read. See the long note there — a HEAD
# made before an upload pinned a 404 at the edge for four hours and is how 1.2
# shipped broken.
PROBE_NONCE="$(date +%s)-$$"
probe_url() { printf '%s?probe=%s' "$1" "$PROBE_NONCE"; }

# VERSION holds "<marketing> (<build>)"; the marketing half is what names the
# tag, the notes file and the DMG.
if [[ -z "$VERSION" ]]; then
	VERSION=$(sed -n 's/^\([^ ]*\).*/\1/p' VERSION)
	[[ -n "$VERSION" ]] || fail "could not read a version out of VERSION"
	echo "No version given — using $VERSION from VERSION"
fi

# Two components are still accepted, and must be: bump-version.sh emits
# major.minor.patch for everything from 1.2.1 on, but the earlier names — 1.1,
# 1.2 — are frozen into R2 filenames and git tags and stay as they are. This is
# a shape check only; whether the version really exists is settled by the notes
# file, the tag, and R2 below, all of which are exact.
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]] \
	|| fail "\"$VERSION\" does not look like a marketing version.

        Pass it exactly as it appears in VERSION and on the tag — 1.2.1, or one
        of the frozen two-component names like 1.2. Not the tag itself: this
        takes 1.2.1, not v1.2.1."

TAG="v$VERSION"
NOTES="docs/releases/$VERSION.md"
DMG_NAME="Synesthia-$VERSION.dmg"
DMG_URL="$DOWNLOAD_BASE/$DMG_NAME"

step "Mirroring $VERSION"
echo "  tag    : $TAG"
echo "  notes  : $NOTES"
echo "  asset  : $DMG_NAME"

[[ -f "$NOTES" ]] || fail "$NOTES does not exist.

        The GitHub Release body is these notes verbatim — there is deliberately
        no fallback to a generated changelog, because two descriptions of one
        release drift. Write the notes first; bump-version.sh drafts them."

command -v gh >/dev/null 2>&1 || fail "the gh CLI is not installed"
gh auth status >/dev/null 2>&1 || fail "gh is not authenticated — run: gh auth login"

# ------------------------------------------------- the version has to be on main
#
# Identical in intent to publish-release.sh's check, and deliberately identical
# in wording where it matters: a tag that is not an ancestor of origin/main
# points at a commit no branch can reach, which is what squash-merging a release
# branch does. Publishing that as a GitHub Release puts a download button on a
# version whose source is unfindable.
step "Checking $TAG reached main"
if [[ $ALLOW_UNMERGED -eq 1 ]]; then
	echo "  --allow-unmerged given — skipping the mainline check"
elif ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
	fail "not a git worktree — the ancestry check cannot run here"
else
	# A stale local main is how this check produces a confident wrong answer in
	# either direction, so fetch first.
	git fetch --quiet --tags --force origin main 2>/dev/null \
		|| echo "  could not fetch origin — comparing against the local refs"

	MAIN_REF=origin/main
	git rev-parse -q --verify "$MAIN_REF^{commit}" >/dev/null || MAIN_REF=main

	git rev-parse -q --verify "refs/tags/$TAG" >/dev/null \
		|| fail "there is no $TAG tag in this repository.

        Every published version is tagged. If the tag exists only on the
        remote, fetch it; if it does not exist at all, this version was never
        released and has nothing to mirror."

	if git merge-base --is-ancestor "$TAG" "$MAIN_REF"; then
		echo "  $TAG is an ancestor of $MAIN_REF"
	else
		fail "$TAG is NOT an ancestor of $MAIN_REF.

        The release was never merged back to mainline, so a GitHub Release for
        it would advertise bytes that correspond to a commit no branch points
        at — the same lie publish-release.sh refuses, in a more visible place.

        Merge the release branch first, with a real merge commit:
            gh pr merge --merge --delete-branch

        NOT --squash: squashing rewrites the commit and orphans $TAG
        permanently. That is how v1.2's tag was lost.

        Override: --allow-unmerged"
	fi
fi

# ------------------------------------------------- the DMG has to match R2
#
# The mirror can never drift from what Sparkle serves, so the bytes attached
# here are proven identical to the bytes at $DMG_URL — and when this checkout
# doesn't have the DMG (a backfill of an old version, a fresh clone), they are
# literally fetched from there.
step "Resolving $DMG_NAME against R2"
LOCAL_DMG="$RELEASES_DIR/$DMG_NAME"
# A temp DIRECTORY, so the download can keep the real filename. `gh release
# upload file#label` sets the asset's *display label*, not its name — the name
# is always the file's basename — so downloading to a bare mktemp file would
# publish an asset called `synesthia-mirror-dmg.XXXXXX`, and that name is what
# the download URL is built from.
WORKDIR=""
cleanup() { [[ -z "$WORKDIR" ]] || rm -rf "$WORKDIR"; }
trap cleanup EXIT

PUBLISHED_STATUS=$(curl -sS -o /dev/null -w '%{http_code}' --head --max-time 30 \
	"$(probe_url "$DMG_URL")" 2>/dev/null || true)
PUBLISHED_STATUS=${PUBLISHED_STATUS##*$'\n'}
[[ "$PUBLISHED_STATUS" =~ ^[0-9]{3}$ ]] || PUBLISHED_STATUS="000"

if [[ "$PUBLISHED_STATUS" != "200" ]]; then
	fail "$DMG_URL answered HTTP $PUBLISHED_STATUS.

        R2 is authoritative and this is a mirror of it, so there is nothing to
        mirror until the release is actually published. Run:
            make publish-release

        A non-200 for every artifact means the Pages Function isn't deployed;
        000 means the request never completed."
fi

# Downloaded whether or not a local copy exists: this is the artifact the
# comparison is against, and for a backfill it is also the artifact uploaded.
WORKDIR=$(mktemp -d -t synesthia-mirror)
FETCHED="$WORKDIR/$DMG_NAME"
curl -fsSL --max-time 300 -o "$FETCHED" "$(probe_url "$DMG_URL")" \
	|| fail "could not download $DMG_URL"
PUBLISHED_SHA=$(shasum -a 256 "$FETCHED" | cut -d' ' -f1)
echo "  published sha256 : $PUBLISHED_SHA"

if [[ -f "$LOCAL_DMG" ]]; then
	LOCAL_SHA=$(shasum -a 256 "$LOCAL_DMG" | cut -d' ' -f1)
	echo "  local     sha256 : $LOCAL_SHA"
	[[ "$LOCAL_SHA" == "$PUBLISHED_SHA" ]] || fail "$LOCAL_DMG does not match what R2 serves.

        published sha256 : $PUBLISHED_SHA
        local     sha256 : $LOCAL_SHA

        Attaching the local copy would put two download buttons on one version
        handing out different bytes. The DMG is named from MARKETING_VERSION
        alone, so this usually means the build number moved without the
        marketing version — see publish-release.sh, which refuses the same
        mismatch on the way up.

        Republish first, or delete the stale local copy and re-run to mirror
        exactly what is already published."
	ASSET="$LOCAL_DMG"
	echo "  local copy matches — attaching it"
else
	# The backfill path, and the fresh-clone path. Nothing is lost by uploading
	# the downloaded bytes: they are the ones the comparison would have been
	# against anyway.
	ASSET="$FETCHED"
	echo "  not in $RELEASES_DIR — attaching the published bytes"
fi

# ------------------------------------------------- create or update
#
# `gh release create` fails on an existing release and `gh release edit` fails
# on a missing one, so which to call is decided by looking first. Both write the
# same three fields, so a re-run converges whichever way it goes.
step "Writing the GitHub Release"
if gh release view "$TAG" >/dev/null 2>&1; then
	ACTION="update"
else
	ACTION="create"
fi
echo "  $ACTION $TAG"

if [[ $DRY_RUN -eq 1 ]]; then
	step "Dry run — nothing written"
	echo "  would $ACTION release $TAG"
	echo "    title : Synesthia $VERSION"
	echo "    body  : $NOTES ($(wc -l <"$NOTES" | tr -d ' ') lines)"
	echo "    asset : $DMG_NAME ($(wc -c <"$ASSET" | tr -d ' ') bytes, sha256 $PUBLISHED_SHA)"
	exit 0
fi

if [[ "$ACTION" == "create" ]]; then
	# No --latest / --prerelease: GitHub picks the latest release by semver
	# across the non-draft, non-prerelease set, which is the right answer both
	# for a new release and for a backfill landing out of order.
	gh release create "$TAG" \
		--title "Synesthia $VERSION" \
		--notes-file "$NOTES" \
		--verify-tag
else
	gh release edit "$TAG" \
		--title "Synesthia $VERSION" \
		--notes-file "$NOTES"
fi

# --clobber, because the asset name is fixed per version and a re-run must
# replace rather than fail. The bytes were proven identical above, so this is
# never a silent substitution.
#
# No `#label` suffix: that sets the display label, while the asset NAME — which
# is what the download URL is built from — always comes from the basename. Both
# paths above therefore hand this a file already called $DMG_NAME.
[[ "$(basename "$ASSET")" == "$DMG_NAME" ]] \
	|| fail "internal error: about to upload $(basename "$ASSET") as the asset name"
gh release upload "$TAG" "$ASSET" --clobber

step "Mirrored"
echo "  Release : $(gh release view "$TAG" --json url --jq .url)"
echo "  Asset   : $DMG_NAME (sha256 $PUBLISHED_SHA)"
echo "  Source  : R2 remains authoritative — $DMG_URL is what Sparkle reads."
