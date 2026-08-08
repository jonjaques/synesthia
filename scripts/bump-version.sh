#!/usr/bin/env bash
#
# Cut a release: bump the version everywhere it is recorded, draft the release
# notes, then commit and tag — pausing for you to approve before anything is
# written.
#
#   ./scripts/bump-version.sh patch      # 1.2.1 -> 1.2.2
#   ./scripts/bump-version.sh minor      # 1.2.2 -> 1.3.0
#   ./scripts/bump-version.sh major      # 1.3.0 -> 2.0.0
#   ./scripts/bump-version.sh 2.5        # set it explicitly (normalized to 2.5.0)
#   ./scripts/bump-version.sh patch --dry-run
#
# The marketing version is always three components. A short form given on the
# command line is padded, never emitted: `2.5` sets MARKETING_VERSION = 2.5.0.
# Releases before 1.2.1 were cut as `1.0`, `1.1`, `1.2` — those names are frozen
# into R2 filenames and tags and stay as they are; nothing new is cut that way.
#
# Options:
#   --dry-run        show the plan (and draft the notes) but write nothing
#   -y, --yes        don't pause for confirmation — for scripted releases
#   --since <ref>    base the notes on <ref>..HEAD (default: last tag, else main)
#   --notes <file>   use this markdown file instead of drafting notes
#   --no-notes       skip the notes step entirely
#   --no-commit      write the files but leave them unstaged (implies --no-tag)
#   --no-tag         commit, but don't create the v<version> tag
#   --allow-dirty    proceed with uncommitted changes in the worktree
#   --allow-main     proceed while on main/master
#   --model <name>   model for the notes draft (default: opus)
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
#
# WHAT IT TOUCHES
#
#   Synesthia.xcodeproj/project.pbxproj   9 × MARKETING_VERSION, 9 × CURRENT_PROJECT_VERSION
#   VERSION                               "<version> (<build>)" — the quick human reference
#   web/src/consts.ts                     RELEASE.version, shown next to the download button
#   docs/releases/<version>.md            the release notes (see below)
#   git                                   one commit, and an annotated v<version> tag
#
# RELEASE NOTES
#
# Sparkle shows release notes in its update window, and reads them from the
# appcast: `generate_appcast` embeds any HTML fragment whose basename matches
# the archive. make-appcast.sh renders `docs/releases/<version>.md` into exactly
# that (see release-notes.py), so the markdown file this script produces is the
# single source for what users read when they update.
#
# The draft is written by Claude Code from `<base>..HEAD` — the commit log, the
# diff stat, and whatever it reads of the tree. It is a draft: the script prints
# it and waits, and `e` opens it in $EDITOR. Nothing is committed unread.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

PBXPROJ="Synesthia.xcodeproj/project.pbxproj"
CONSTS="web/src/consts.ts"
VERSION_FILE="VERSION"
NOTES_DIR="docs/releases"

step() { printf '\n\033[1;36m==> %s\033[0m\n' "$1"; }
warn() { printf '\033[1;33m  ! %s\033[0m\n' "$1"; }
fail() { printf '\n\033[1;31mFAILED: %s\033[0m\n' "$1" >&2; exit 1; }

LEVEL=""
DRY_RUN=0
ASSUME_YES=0
SINCE=""
NOTES_FILE=""
WRITE_NOTES=1
DO_COMMIT=1
DO_TAG=1
ALLOW_DIRTY=0
ALLOW_MAIN=0
NOTES_MODEL="${BUMP_NOTES_MODEL:-opus}"
NOTES_TIMEOUT="${BUMP_NOTES_TIMEOUT:-600}"

while [[ $# -gt 0 ]]; do
	case "$1" in
		--dry-run) DRY_RUN=1 ;;
		-y|--yes) ASSUME_YES=1 ;;
		--since) SINCE="${2:-}"; [[ -n "$SINCE" ]] || fail "--since needs a git ref"; shift ;;
		--notes) NOTES_FILE="${2:-}"; [[ -n "$NOTES_FILE" ]] || fail "--notes needs a file"; shift ;;
		--no-notes) WRITE_NOTES=0 ;;
		--no-commit) DO_COMMIT=0; DO_TAG=0 ;;
		--no-tag) DO_TAG=0 ;;
		--allow-dirty) ALLOW_DIRTY=1 ;;
		--allow-main) ALLOW_MAIN=1 ;;
		--model) NOTES_MODEL="${2:-}"; [[ -n "$NOTES_MODEL" ]] || fail "--model needs a name"; shift ;;
		-h|--help) sed -n '2,/^[^#]/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; exit 0 ;;
		-*) fail "unknown option: $1" ;;
		*) [[ -z "$LEVEL" ]] || fail "give exactly one level or version"; LEVEL="$1" ;;
	esac
	shift
done
[[ -n "$LEVEL" ]] || fail "usage: $0 patch|minor|major|<version> [options] (--help for the list)"

[[ -f "$PBXPROJ" ]] || fail "$PBXPROJ not found"
if [[ -n "$NOTES_FILE" && ! -f "$NOTES_FILE" ]]; then
	fail "--notes file not found: $NOTES_FILE"
fi

# --------------------------------------------------------------- git preflight
#
# A release is a commit and a tag, so the worktree has to be in a state where
# both mean something. A dirty tree would sweep unrelated edits into the release
# commit — or, worse, leave them out and produce a tag that doesn't describe any
# buildable state. A detached HEAD would put the commit somewhere no branch
# points at, which is very easy not to notice until the tag is the only thing
# holding the release.
step "Checking the working tree"
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || fail "not a git repository"

BRANCH=$(git symbolic-ref --quiet --short HEAD || true)
[[ -n "$BRANCH" ]] || fail "HEAD is detached — check out a branch before releasing.
        A release commit on no branch is reachable only from the tag."
echo "  branch      : $BRANCH"

if [[ "$BRANCH" == "main" || "$BRANCH" == "master" ]] && [[ $ALLOW_MAIN -eq 0 ]]; then
	fail "on $BRANCH — cut the release on a branch and merge it, or pass --allow-main."
fi

DIRTY=$(git status --porcelain)
if [[ -n "$DIRTY" ]]; then
	if [[ $ALLOW_DIRTY -eq 0 ]]; then
		fail "the working tree is not clean:
$(sed 's/^/          /' <<<"$DIRTY")
        Commit or stash first — the release commit should contain the version
        bump and nothing else. Pass --allow-dirty to override (the commit still
        only stages the files this script writes)."
	fi
	warn "working tree is dirty; --allow-dirty given, committing only the bumped files"
else
	echo "  worktree    : clean"
fi

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

# ALWAYS three components, including the trailing .0.
#
# This used to print `f'{major}.{minor}'` whenever patch was 0, on the reasoning
# that "1.1.0" is noise — CFBundleShortVersionString accepts 1-3 components, so
# both are legal. What it actually produced was a version line that changes
# shape depending on the level: 1.1, 1.2, then 1.2.1, then 1.3 again. Every
# consumer that has to *match* a version then has two forms to handle —
# docs/releases/<version>.md, the v<version> tag, resolve_base's lookup of
# refs/tags/v$CUR_MV, Synesthia-<version>.dmg in R2 and the appcast enclosure
# URL that points at it. Nothing enforced the correspondence, so a mismatch
# would surface as a missing file at publish time rather than here.
#
# Three components always, so the shape never changes. 1.2.1 -> 1.3.0, not 1.3.
print(f'{major}.{minor}.{patch}')
PY
) || fail "could not compute the new version"

TAG="v$NEW_MV"
NOTES_TARGET="$NOTES_DIR/$NEW_MV.md"

if [[ $DO_TAG -eq 1 ]] && git rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then
	fail "tag $TAG already exists — that version has been cut before."
fi

# ------------------------------------------------------------ the notes' base
#
# What the notes describe is <base>..HEAD. Prefer the previous release's tag;
# fall back to the newest tag reachable from here, then to the fork point from
# main. Whatever it lands on is printed, because a wrong base silently produces
# notes for the wrong range.
resolve_base() {
	local ref
	if [[ -n "$SINCE" ]]; then
		git rev-parse -q --verify "$SINCE^{commit}" >/dev/null \
			|| fail "--since $SINCE is not a commit"
		echo "$SINCE"
		return
	fi
	if git rev-parse -q --verify "refs/tags/v$CUR_MV" >/dev/null; then
		echo "v$CUR_MV"
		return
	fi
	ref=$(git describe --tags --abbrev=0 --match 'v*' 2>/dev/null || true)
	if [[ -n "$ref" ]]; then
		echo "$ref"
		return
	fi
	for candidate in main master origin/main origin/master; do
		if git rev-parse -q --verify "$candidate^{commit}" >/dev/null; then
			git merge-base "$candidate" HEAD
			return
		fi
	done
	# No tags and no main: describe everything.
	git rev-list --max-parents=0 HEAD | tail -1
}

BASE=$(resolve_base)
BASE_SHORT=$(git rev-parse --short "$BASE")
COMMIT_COUNT=$(git rev-list --no-merges --count "$BASE..HEAD")

# ---------------------------------------------------------------- the plan
step "Bumping $CUR_MV ($CUR_BUILD) -> $NEW_MV ($NEW_BUILD)"
MV_COUNT=$(grep -c "MARKETING_VERSION = " "$PBXPROJ" | tr -d ' ')
BUILD_COUNT=$(grep -c "CURRENT_PROJECT_VERSION = " "$PBXPROJ" | tr -d ' ')
echo "  $PBXPROJ : $MV_COUNT marketing, $BUILD_COUNT build"
echo "  $VERSION_FILE : $NEW_MV ($NEW_BUILD)"
echo "  $CONSTS  : RELEASE.version"
if [[ $WRITE_NOTES -eq 1 ]]; then
	echo "  $NOTES_TARGET : release notes, drafted from $BASE_SHORT..HEAD ($COMMIT_COUNT commits)"
fi
if [[ $DO_COMMIT -eq 1 ]]; then
	echo "  git : commit on $BRANCH$([[ $DO_TAG -eq 1 ]] && echo ", annotated tag $TAG")"
fi

# ------------------------------------------------------------------- the notes
#
# Drafted into a temp file. Nothing lands in docs/releases until it has been
# read and accepted, and --dry-run stops right after showing it.
DRAFT=""
cleanup() { [[ -z "$DRAFT" ]] || rm -f "$DRAFT"; }
trap cleanup EXIT

draft_with_claude() {
	local out="$1" prompt log status=0 pid waited=0
	log=$(mktemp -t synesthia-notes-log)

	prompt=$(cat <<EOF
You are drafting the user-facing release notes for Synesthia $NEW_MV (build
$NEW_BUILD), a macOS music visualizer. They ship in three places: the Sparkle
update window every existing user sees when they update, docs/releases/$NEW_MV.md
in this repository, and the annotated git tag $TAG.

The release is everything in $BASE..HEAD on branch $BRANCH. Investigate it —
read the diff, read the files it touches, and work out what actually changed
for someone using the app.

Commits ($COMMIT_COUNT, oldest first):
$(git log --no-merges --reverse --format='  %h %s' "$BASE..HEAD")

Files changed:
$(git diff --stat "$BASE..HEAD" | tail -60)

Write GitHub-flavored markdown, and output the markdown ONLY — no preamble, no
commentary, no code fence around the whole thing. Follow this shape:

# Synesthia $NEW_MV

One or two sentences on what this release is about. No marketing voice; say what
changed.

## New
## Improved
## Fixed

- Bullets under whichever of those sections apply — omit a section entirely if
  it would be empty. Lead each bullet with a bolded subject, then an em-dash and
  the detail: "- **Bars visualizer** — a classic spectrum analyzer, …".

Rules:
- Write for someone who uses the app and has never read the source. Describe the
  visible change, not the implementation ("system audio no longer drops out when
  the display sleeps", not "moved the SCStream restart into AppState").
- Skip pure refactors, formatting, CI, docs and website-only changes unless a
  user would notice. A short release is fine; a padded one is not.
- Never invent a feature. If the diff does not support a claim, leave it out.
- Group related commits into one bullet rather than transcribing the log.
- Note anything that changes behaviour users rely on, or that needs a new
  permission, and mention macOS version requirements only if they changed.
- Keep it to roughly 12 bullets at the very most. Plain, concrete, specific.
EOF
	)

	printf '  drafting with claude (%s), up to %ss…' "$NOTES_MODEL" "$NOTES_TIMEOUT"

	# Read-only tools only, and --permission-mode dontAsk so a tool outside that
	# list is denied rather than blocking on a prompt nobody is there to answer.
	claude -p "$prompt" \
		--model "$NOTES_MODEL" \
		--permission-mode dontAsk \
		--allowed-tools "Read Grep Glob Bash(git log:*) Bash(git diff:*) Bash(git show:*)" \
		--output-format text \
		>"$out" 2>"$log" &
	pid=$!

	# No `timeout` on macOS, so watch it by hand: a release script that hangs
	# forever on a stalled model is worse than one that gives up and lets you
	# write the notes yourself.
	while kill -0 "$pid" 2>/dev/null; do
		if [[ $waited -ge $NOTES_TIMEOUT ]]; then
			kill "$pid" 2>/dev/null || true
			wait "$pid" 2>/dev/null || true
			printf ' timed out\n'
			rm -f "$log"
			return 1
		fi
		sleep 2
		waited=$((waited + 2))
		printf '.'
	done
	wait "$pid" || status=$?
	printf '\n'

	if [[ $status -ne 0 ]] || [[ ! -s "$out" ]]; then
		warn "claude exited $status$([[ -s "$log" ]] && echo ": $(head -3 "$log" | tr '\n' ' ')")"
		rm -f "$log"
		return 1
	fi
	rm -f "$log"

	# Strip a stray fence if the model wrapped the whole document in one anyway.
	if [[ "$(head -1 "$out")" == '```'* ]]; then
		sed -i '' '1d' "$out"
		if [[ "$(tail -1 "$out")" == '```' ]]; then
			sed -i '' '$d' "$out"
		fi
	fi
	return 0
}

write_stub() {
	cat >"$1" <<EOF
# Synesthia $NEW_MV

_Draft — replace this with what actually changed._

## New

$(git log --no-merges --reverse --format='- %s' "$BASE..HEAD")
EOF
}

if [[ $WRITE_NOTES -eq 1 ]]; then
	step "Release notes"
	DRAFT=$(mktemp -t synesthia-notes)

	if [[ -n "$NOTES_FILE" ]]; then
		cp "$NOTES_FILE" "$DRAFT"
		echo "  using $NOTES_FILE"
	elif [[ -f "$NOTES_TARGET" ]]; then
		cp "$NOTES_TARGET" "$DRAFT"
		echo "  $NOTES_TARGET already exists — editing that instead of drafting"
	elif command -v claude >/dev/null 2>&1; then
		if ! draft_with_claude "$DRAFT"; then
			warn "falling back to a stub built from the commit log"
			write_stub "$DRAFT"
		fi
	else
		warn "claude is not on PATH — writing a stub from the commit log"
		write_stub "$DRAFT"
	fi

	# Review loop. This is the point of the whole step: notes go out to every
	# user, and a model's first draft is a draft.
	while true; do
		printf '\n\033[1m--- %s ---\033[0m\n' "$NOTES_TARGET"
		cat "$DRAFT"
		printf '\033[1m--- end ---\033[0m\n'

		if [[ $ASSUME_YES -eq 1 || $DRY_RUN -eq 1 ]] || [[ ! -t 0 ]]; then
			break
		fi

		printf '\n[a]ccept, [e]dit in %s, [r]edraft, [q]uit? ' "${EDITOR:-vi}"
		read -r answer </dev/tty
		case "${answer:-a}" in
			a|A|"") break ;;
			e|E) "${EDITOR:-vi}" "$DRAFT" </dev/tty >/dev/tty ;;
			r|R)
				if command -v claude >/dev/null 2>&1; then
					draft_with_claude "$DRAFT" || warn "redraft failed; keeping what you had"
				else
					warn "claude is not on PATH"
				fi
				;;
			q|Q) fail "aborted — nothing written" ;;
			*) ;;
		esac
	done

	[[ -s "$DRAFT" ]] || fail "the release notes are empty"
fi

# ------------------------------------------------------------------- confirm
if [[ $DRY_RUN -eq 1 ]]; then
	step "Dry run — nothing written"
	exit 0
fi

if [[ $ASSUME_YES -eq 0 ]]; then
	[[ -t 0 ]] || fail "not a terminal and --yes was not given; refusing to write unattended"
	step "Ready to write"
	echo "  $CUR_MV ($CUR_BUILD) -> $NEW_MV ($NEW_BUILD) on $BRANCH"
	echo "  files : $PBXPROJ, $VERSION_FILE, $CONSTS$([[ $WRITE_NOTES -eq 1 ]] && echo ", $NOTES_TARGET")"
	if [[ $DO_COMMIT -eq 1 ]]; then
		echo "  git   : commit$([[ $DO_TAG -eq 1 ]] && echo " + tag $TAG")"
	else
		echo "  git   : nothing (--no-commit)"
	fi
	printf '\nProceed? [y/N] '
	read -r confirm </dev/tty
	[[ "$confirm" =~ ^[yY] ]] || fail "aborted — nothing written"
fi

# ------------------------------------------------------------------- write it
step "Writing"
sed -i '' \
	-e "s/MARKETING_VERSION = [^;]*;/MARKETING_VERSION = $NEW_MV;/" \
	-e "s/CURRENT_PROJECT_VERSION = [^;]*;/CURRENT_PROJECT_VERSION = $NEW_BUILD;/" \
	"$PBXPROJ"

# The one place a human can read the current version without opening Xcode or
# grepping a 2000-line pbxproj. Nothing builds from it — it is a mirror, and the
# verify step below is what keeps it honest.
printf '%s (%s)\n' "$NEW_MV" "$NEW_BUILD" >"$VERSION_FILE"

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

if [[ $WRITE_NOTES -eq 1 ]]; then
	mkdir -p "$NOTES_DIR"
	cp "$DRAFT" "$NOTES_TARGET"
	# docs/ is not in .prettierignore, so `make lint` (and CI) checks this file.
	# A model's markdown is usually close but rarely exact, and failing the
	# healthcheck on the release commit is a silly way to find that out.
	if [[ -x node_modules/.bin/prettier ]]; then
		node_modules/.bin/prettier --write "$NOTES_TARGET" >/dev/null 2>&1 \
			|| warn "prettier could not format $NOTES_TARGET — run 'make format' before pushing"
	else
		warn "prettier not installed (run 'make install'); $NOTES_TARGET is unformatted"
	fi
	echo "  $NOTES_TARGET"
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

[[ "$(cat "$VERSION_FILE")" == "$NEW_MV ($NEW_BUILD)" ]] \
	|| fail "$VERSION_FILE does not read '$NEW_MV ($NEW_BUILD)'"
echo "  VERSION         : $NEW_MV ($NEW_BUILD)"

if [[ -f "$CONSTS" ]]; then
	grep -qF "version: \"$NEW_MV\"," "$CONSTS" || grep -qF "version: '$NEW_MV'," "$CONSTS" \
		|| fail "$CONSTS still shows the old version"
	echo "  consts.ts       : RELEASE.version = $NEW_MV"
fi

if [[ $WRITE_NOTES -eq 1 ]]; then
	# Render now rather than at `make appcast` time: a markdown construct this
	# converter doesn't handle should fail here, while the notes are in front of
	# you, not two steps before an upload.
	python3 scripts/release-notes.py render "$NEW_MV" >/dev/null \
		|| fail "$NOTES_TARGET does not render to HTML for the appcast"
	echo "  release notes   : $NOTES_TARGET renders for the appcast"
fi

# ----------------------------------------------------------------- commit/tag
#
# Only the files above are staged, by path. `git commit -a` would sweep in
# whatever else is in the tree — which --allow-dirty makes a real possibility.
if [[ $DO_COMMIT -eq 1 ]]; then
	step "Committing"
	PATHS=("$PBXPROJ" "$VERSION_FILE")
	if [[ -f "$CONSTS" ]]; then PATHS+=("$CONSTS"); fi
	if [[ $WRITE_NOTES -eq 1 ]]; then PATHS+=("$NOTES_TARGET"); fi
	git add -- "${PATHS[@]}"

	MESSAGE_FILE=$(mktemp -t synesthia-commit-msg)
	{
		printf 'Release %s (build %s)\n\n' "$NEW_MV" "$NEW_BUILD"
		if [[ $WRITE_NOTES -eq 1 ]]; then
			# The notes minus their title line: the subject above already says it.
			tail -n +2 "$NOTES_TARGET" | sed '/./,$!d'
		fi
	} >"$MESSAGE_FILE"
	git commit --file "$MESSAGE_FILE" --quiet
	rm -f "$MESSAGE_FILE"
	echo "  $(git log -1 --oneline)"

	if [[ $DO_TAG -eq 1 ]]; then
		if [[ $WRITE_NOTES -eq 1 ]]; then
			# --cleanup=verbatim, because a tag message defaults to --cleanup=strip
			# and that drops every line beginning with '#' as a comment — which in
			# markdown is the title and every heading. The tag would carry the
			# bullets with nothing to group them, and nothing warns you.
			git tag -a "$TAG" --cleanup=verbatim -F "$NOTES_TARGET"
		else
			git tag -a "$TAG" -m "Synesthia $NEW_MV (build $NEW_BUILD)"
		fi
		echo "  tagged $TAG"
	fi
fi

step "Done"
cat <<EOF
  Version : $NEW_MV
  Build   : $NEW_BUILD
$([[ $WRITE_NOTES -eq 1 ]] && echo "  Notes   : $NOTES_TARGET")

Next:
  git push --follow-tags   # the tag is local until you do
  make direct              # archive, sign, notarize, staple, DMG
  make appcast             # add it to the feed, with these notes embedded
  make publish-release     # upload to R2

RELEASE.size in $CONSTS is not updated automatically — the DMG's
size is only known after 'make direct' prints it.
EOF
