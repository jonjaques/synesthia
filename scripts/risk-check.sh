#!/usr/bin/env bash
#
# Decide whether a change is one an agent may merge on its own.
#
#   ./scripts/risk-check.sh                 # working branch vs origin/main
#   ./scripts/risk-check.sh --base main     # …vs some other base
#   ./scripts/risk-check.sh --files a b c   # judge an explicit list
#   ./scripts/risk-check.sh --quiet         # print only "high" or "low"
#
# Prints `high` or `low` on stdout and the reasoning on stderr. Exit status is 0
# either way — the ANSWER is the output, not the status, so a caller can't
# mistake "the script broke" for "the change is safe". A genuine failure (no
# patterns file, bad base ref) exits non-zero with nothing on stdout.
#
# Two callers, deliberately:
#
#   .github/workflows/healthcheck.yml   labels the PR risk:high
#   .claude/skills/queue/SKILL.md       refuses to merge
#
# The loop re-derives the answer here rather than reading the label CI applied,
# because a label is a thing the loop itself has permission to change. Reading
# it back would be asking the fox about the henhouse. Both read
# .github/risk-paths.txt, so the two enforcers cannot drift.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

PATTERNS_FILE=".github/risk-paths.txt"
BASE="origin/main"
QUIET=0
EXPLICIT_FILES=()

while [[ $# -gt 0 ]]; do
	case "$1" in
		--base) BASE="${2:-}"; [[ -n "$BASE" ]] || { echo "--base needs a ref" >&2; exit 2; }; shift ;;
		--quiet|-q) QUIET=1 ;;
		--files) shift; while [[ $# -gt 0 && "$1" != --* ]]; do EXPLICIT_FILES+=("$1"); shift; done; continue ;;
		-h|--help) sed -n '2,/^set -euo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; exit 0 ;;
		*) echo "unknown option: $1" >&2; exit 2 ;;
	esac
	shift
done

[[ -f "$PATTERNS_FILE" ]] || { echo "$PATTERNS_FILE not found" >&2; exit 2; }

if [[ ${#EXPLICIT_FILES[@]} -gt 0 ]]; then
	CHANGED=$(printf '%s\n' "${EXPLICIT_FILES[@]}")
else
	# Three dots: what this branch changed relative to where it forked, NOT the
	# difference between two tips. With two dots, anything that landed on main
	# after the branch started would be counted as this branch's work — so an
	# unrelated release commit on main would silently make every open PR look
	# high-risk, and the gate would stop meaning anything.
	git rev-parse -q --verify "$BASE^{commit}" >/dev/null 2>&1 \
		|| { echo "base ref '$BASE' does not resolve — fetch it first" >&2; exit 2; }
	CHANGED=$(git diff --name-only "$BASE...HEAD")
fi

# The changed list goes through a file, not a pipe. `python3 - <<'PY'` already
# uses stdin for the program itself, so a `<<<"$CHANGED"` on the same call is
# read as more source and the script sees an empty file list — which reports
# `low` for every change, i.e. the gate fails open. It did exactly that once.
#
# An explicit XXXXXX template, not `mktemp -t prefix`. Every other script here
# uses the `-t` form and is right to — they only ever run on macOS, where BSD
# mktemp appends the random part for you. This one also runs on ubuntu-latest in
# the risk-gate job, and GNU coreutils treats the argument as a literal template:
# no X's, "too few X's in template", exit 1. The step then failed with no output
# at all, because the error went to the stderr file the script redirects.
CHANGED_FILE=$(mktemp "${TMPDIR:-/tmp}/synesthia-risk-changed.XXXXXX")
HITS_FILE=$(mktemp "${TMPDIR:-/tmp}/synesthia-risk-hits.XXXXXX")
cleanup() { rm -f "$CHANGED_FILE" "$HITS_FILE"; }
trap cleanup EXIT
printf '%s\n' "$CHANGED" >"$CHANGED_FILE"

RESULT=$(python3 - "$PATTERNS_FILE" "$CHANGED_FILE" "$HITS_FILE" <<'PY'
import fnmatch, sys

patterns = []
for raw in open(sys.argv[1]):
    line = raw.split('#', 1)[0].strip()
    if line:
        patterns.append(line)

if not patterns:
    sys.exit('risk-paths.txt contains no patterns; refusing to call everything safe')

changed = [line.strip() for line in open(sys.argv[2]) if line.strip()]

# fnmatch, not pathlib.match: `*` here is meant to cross directory separators so
# that `web/functions/*` covers `web/functions/downloads/[[file]].ts`. That is
# stated at the top of risk-paths.txt because it is the opposite of gitignore.
#
# fnmatch also treats [ ] as a character class, and one real path in this repo
# is literally named `[[file]].ts`. Matching is therefore tried both ways: as a
# pattern, and as a plain prefix/equality, so a bracketed filename can never
# slip through by being unmatchable.
hits = []
for path in changed:
    for pattern in patterns:
        if fnmatch.fnmatch(path, pattern) or path == pattern \
                or (pattern.endswith('*') and path.startswith(pattern[:-1])):
            hits.append((path, pattern))
            break

print('high' if hits else 'low')
with open(sys.argv[3], 'w') as out:
    for path, pattern in hits:
        out.write(f'{path}\t{pattern}\n')
PY
) || exit 2

HITS=$(command cat "$HITS_FILE")

printf '%s\n' "$RESULT"

if [[ $QUIET -eq 0 ]]; then
	FILE_COUNT=$(grep -c . <<<"$CHANGED" || true)
	if [[ "$RESULT" == "high" ]]; then
		{
			echo "risk:high — $(grep -c . <<<"$HITS") of $FILE_COUNT changed file(s) are protected:"
			while IFS=$'\t' read -r path pattern; do
				[[ -n "$path" ]] || continue
				printf '  %-52s matched %s\n' "$path" "$pattern"
			done <<<"$HITS"
			echo
			echo "A human merges this. See .github/risk-paths.txt for why each path is listed."
		} >&2
	else
		echo "risk:low — none of the $FILE_COUNT changed file(s) are protected." >&2
	fi
fi
