#!/usr/bin/env bash
#
# Apply .github/labels.yml to the repository.
#
#   ./scripts/sync-labels.sh              # create or update every label
#   ./scripts/sync-labels.sh --dry-run    # print what would change
#
# Idempotent: `gh label create --force` creates a missing label and updates an
# existing one, so a label recoloured or re-described by hand in the web UI is
# put back. Run it after editing .github/labels.yml, and after cloning into a
# fresh fork.
#
# It never DELETES. A label removed from the yml is left alone in GitHub,
# because deleting one strips it from every issue that carried it — silently,
# and with no undo. Remove those by hand, having looked at what they're on.
#
# WHY THE PARSER IS HAND-ROLLED
#
# There is no `yaml` module in the toolchain (system python3 doesn't ship
# PyYAML) and adding a dependency to read a 60-line list of labels is not worth
# it — the same call this repo already makes in release-notes.py for markdown.
# The format is therefore deliberately a strict subset: a flat sequence of
# mappings, one `- name:` per label, `color:` and `description:` beneath it,
# every value double-quoted. Anything else is rejected loudly rather than
# half-understood, because a parser that silently skips a label would leave the
# queue's state machine missing a state.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

LABELS_FILE=".github/labels.yml"

DRY_RUN=0
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=1

step() { printf '\n\033[1;36m==> %s\033[0m\n' "$1"; }
fail() { printf '\n\033[1;31mFAILED: %s\033[0m\n' "$1" >&2; exit 1; }

[[ -f "$LABELS_FILE" ]] || fail "$LABELS_FILE not found"
command -v gh >/dev/null 2>&1 || fail "gh is not on PATH"
gh auth status >/dev/null 2>&1 || fail "gh is not authenticated — run 'gh auth login'"

step "Reading $LABELS_FILE"

# Tab-separated name/color/description, one label per line. Parsed in python
# rather than awk so the "what did you actually mean" errors can be specific.
LABELS=$(python3 - "$LABELS_FILE" <<'PY'
import re, sys

path = sys.argv[1]
entries, current, line_no = [], None, 0

FIELD = re.compile(r'^\s{2,}(name|color|description):\s*"(.*)"\s*$')
START = re.compile(r'^-\s+name:\s*"(.*)"\s*$')

for line_no, raw in enumerate(open(path), 1):
    line = raw.rstrip('\n')
    if not line.strip() or line.lstrip().startswith('#'):
        continue

    start = START.match(line)
    if start:
        current = {'name': start.group(1)}
        entries.append(current)
        continue

    field = FIELD.match(line)
    if field:
        if current is None:
            sys.exit(f'{path}:{line_no}: "{field.group(1)}" before any "- name:"')
        current[field.group(1)] = field.group(2)
        continue

    sys.exit(f'{path}:{line_no}: not understood by this parser: {line!r}\n'
             '  Expected `- name: "…"` or two-space-indented `color:`/`description:`,\n'
             '  every value double-quoted. See the note in scripts/sync-labels.sh.')

if not entries:
    sys.exit(f'{path}: no labels found')

seen = set()
for entry in entries:
    name = entry['name']
    if name in seen:
        sys.exit(f'{path}: duplicate label "{name}"')
    seen.add(name)
    for required in ('color', 'description'):
        if required not in entry:
            sys.exit(f'{path}: label "{name}" has no {required}')
    if not re.fullmatch(r'[0-9a-fA-F]{6}', entry['color']):
        sys.exit(f'{path}: label "{name}" has color "{entry["color"]}"; '
                 'expected six hex digits with no leading #')
    if '\t' in name or '\t' in entry['description']:
        sys.exit(f'{path}: label "{name}" contains a tab, which is the field separator')
    print('\t'.join((name, entry['color'], entry['description'])))
PY
) || fail "could not parse $LABELS_FILE"

echo "  $(grep -c . <<<"$LABELS") label(s)"

# What GitHub holds now, so the output can say created/updated/unchanged rather
# than shouting "synced" at fifteen labels that were already correct.
EXISTING=$(gh label list --limit 200 --json name,color,description \
	--jq '.[] | [.name, .color, .description] | @tsv' 2>/dev/null || true)

step "$([[ $DRY_RUN -eq 1 ]] && echo "Dry run — nothing written" || echo "Applying")"

while IFS=$'\t' read -r name color description; do
	[[ -n "$name" ]] || continue

	# Herestring, never `printf … | grep`: grep exits on first match, the
	# producer dies of SIGPIPE, and pipefail turns a match into a failed
	# pipeline. Bitten twice in this repo already; see CLAUDE.md.
	CURRENT=$(grep -F "$(printf '%s\t' "$name")" <<<"$EXISTING" | head -1 || true)

	if [[ -z "$CURRENT" ]]; then
		VERB="create"
	elif [[ "$CURRENT" == "$(printf '%s\t%s\t%s' "$name" "$color" "$description")" ]]; then
		printf '  %-22s unchanged\n' "$name"
		continue
	else
		VERB="update"
	fi

	if [[ $DRY_RUN -eq 1 ]]; then
		printf '  %-22s would %s\n' "$name" "$VERB"
		continue
	fi

	gh label create "$name" --color "$color" --description "$description" --force >/dev/null \
		|| fail "could not $VERB the label \"$name\""
	printf '  %-22s %sd\n' "$name" "$VERB"
done <<<"$LABELS"

step "Done"
echo "  Labels: $(gh repo view --json nameWithOwner --jq .nameWithOwner)/labels"
