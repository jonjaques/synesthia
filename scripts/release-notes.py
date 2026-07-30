#!/usr/bin/env python3
"""Render a release-notes markdown file into the HTML fragment Sparkle embeds.

    ./scripts/release-notes.py path 1.2          # print docs/releases/1.2.md
    ./scripts/release-notes.py render 1.2        # print the HTML fragment
    ./scripts/release-notes.py render 1.2 --out build/releases/Synesthia-1.2.html

WHY A HAND-ROLLED CONVERTER

Sparkle's `generate_appcast` picks up a `.md`, `.txt` or `.html` file sitting
next to an archive and whose basename matches it, and turns it into that item's
release notes. Markdown looks like the obvious choice — it is what we want in
git — but it is *not* embedded in the feed: only HTML without DOCTYPE/body tags
is inlined as CDATA. A markdown file becomes a `<sparkle:releaseNotesLink>`
instead, which would mean uploading a second artifact per release and teaching
`web/functions/downloads/[[file]].ts` to serve something other than a `.dmg`
(`isSafeDmgName` rejects everything else today). Embedding an HTML fragment
keeps a release a single upload.

So the notes are authored as markdown in `docs/releases/<version>.md` — good for
git, GitHub and eventually the website — and converted here. There is no
markdown library in the toolchain (no `markdown` module, no pandoc) and adding
one to ship a ~300-word changelog is not worth a dependency, so this handles the
subset the notes actually use: headings, lists, paragraphs, code fences, rules,
blockquotes, and inline code/bold/italic/links. Anything outside that subset is
escaped and passed through as text rather than silently mangled.

The leading `# Synesthia <version>` title is dropped by default: Sparkle's
update window already shows the version above the notes, so it would read twice.
Pass --keep-title to keep it.
"""

from __future__ import annotations

import argparse
import html
import pathlib
import re
import sys

REPO_ROOT = pathlib.Path(__file__).resolve().parent.parent
RELEASES_DIR = REPO_ROOT / "docs" / "releases"

# ------------------------------------------------------------------ inline


def _inline(text: str) -> str:
    """Escape, then apply inline markdown. Code spans are protected first so
    that `**not bold**` inside backticks survives as literal text."""
    spans: list[str] = []

    def stash(match: re.Match[str]) -> str:
        spans.append(html.escape(match.group(1)))
        return f"\x00{len(spans) - 1}\x00"

    text = re.sub(r"`([^`]+)`", stash, text)
    text = html.escape(text)

    # [label](url) — the label may itself contain the other inline markers, so
    # links go first and their innards get the same treatment below.
    text = re.sub(
        r"\[([^\]]+)\]\((https?://[^)\s]+|[^)\s]+)\)",
        lambda m: f'<a href="{m.group(2)}">{m.group(1)}</a>',
        text,
    )
    text = re.sub(r"\*\*([^*]+)\*\*", r"<strong>\1</strong>", text)
    text = re.sub(r"(?<![\w*])\*([^*\n]+)\*(?![\w*])", r"<em>\1</em>", text)
    text = re.sub(r"(?<![\w_])_([^_\n]+)_(?![\w_])", r"<em>\1</em>", text)

    return re.sub(r"\x00(\d+)\x00", lambda m: f"<code>{spans[int(m.group(1))]}</code>", text)


# ------------------------------------------------------------------- blocks

BULLET = re.compile(r"^(\s*)[-*]\s+(.*)$")
NUMBERED = re.compile(r"^(\s*)\d+[.)]\s+(.*)$")
HEADING = re.compile(r"^(#{1,6})\s+(.*)$")
FENCE = re.compile(r"^\s*```")


def render(markdown: str, keep_title: bool = False) -> str:
    lines = markdown.replace("\r\n", "\n").split("\n")

    if not keep_title:
        # Drop a single leading H1 and the blank line after it.
        for index, line in enumerate(lines):
            if not line.strip():
                continue
            if line.startswith("# "):
                lines = lines[index + 1 :]
            break

    out: list[str] = []
    # Open list levels, as (tag, indent, nested) — a list is closed when a
    # line's indent drops back to or below the level that opened it. `nested`
    # records that the list was opened *inside* the preceding <li>, which is the
    # only valid place for a sublist and therefore has a </li> owing on close.
    stack: list[tuple[str, int, bool]] = []
    paragraph: list[str] = []

    def close_paragraph() -> None:
        if paragraph:
            out.append(f"<p>{_inline(' '.join(paragraph))}</p>")
            paragraph.clear()

    def close_lists(to_indent: int = -1) -> None:
        while stack and stack[-1][1] > to_indent:
            tag, _, nested = stack.pop()
            out.append(f"</{tag}>" + ("</li>" if nested else ""))

    index = 0
    while index < len(lines):
        line = lines[index]
        index += 1

        if FENCE.match(line):
            close_paragraph()
            close_lists()
            code: list[str] = []
            while index < len(lines) and not FENCE.match(lines[index]):
                code.append(html.escape(lines[index]))
                index += 1
            index += 1  # the closing fence
            out.append("<pre><code>" + "\n".join(code) + "</code></pre>")
            continue

        if not line.strip():
            close_paragraph()
            continue

        heading = HEADING.match(line)
        if heading:
            close_paragraph()
            close_lists()
            level = len(heading.group(1))
            out.append(f"<h{level}>{_inline(heading.group(2).strip())}</h{level}>")
            continue

        if re.fullmatch(r"\s*([-*_])\s*\1\s*\1[\s\-*_]*", line):
            close_paragraph()
            close_lists()
            out.append("<hr>")
            continue

        if line.lstrip().startswith("> "):
            close_paragraph()
            close_lists()
            out.append(f"<blockquote><p>{_inline(line.lstrip()[2:].strip())}</p></blockquote>")
            continue

        item = BULLET.match(line) or NUMBERED.match(line)
        if item:
            close_paragraph()
            indent = len(item.group(1).expandtabs(4))
            tag = "ul" if BULLET.match(line) else "ol"
            close_lists(indent)
            if not stack or stack[-1][1] < indent:
                # A sublist belongs inside the <li> above it, so reopen that one.
                nested = bool(stack) and bool(out) and out[-1].endswith("</li>")
                if nested:
                    out[-1] = out[-1][: -len("</li>")]
                stack.append((tag, indent, nested))
                out.append(f"<{tag}>")
            out.append(f"<li>{_inline(item.group(2).strip())}</li>")
            continue

        # A plain line while a list is open is a continuation of the last item;
        # anything else is paragraph text.
        if stack:
            if out and out[-1].endswith("</li>"):
                out[-1] = out[-1][: -len("</li>")] + " " + _inline(line.strip()) + "</li>"
                continue
            close_lists()
        paragraph.append(line.strip())

    close_paragraph()
    close_lists()
    return "\n".join(out) + "\n"


# ---------------------------------------------------------------------- cli


def notes_path(version: str) -> pathlib.Path:
    return RELEASES_DIR / f"{version}.md"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    sub = parser.add_subparsers(dest="command", required=True)

    path_cmd = sub.add_parser("path", help="print the notes path for a version")
    path_cmd.add_argument("version")

    render_cmd = sub.add_parser("render", help="render the notes to an HTML fragment")
    render_cmd.add_argument("version")
    render_cmd.add_argument("--out", help="write here instead of stdout")
    render_cmd.add_argument(
        "--keep-title",
        action="store_true",
        help="keep the leading '# Synesthia <version>' heading",
    )

    args = parser.parse_args()
    path = notes_path(args.version)

    if args.command == "path":
        print(path)
        return 0

    if not path.is_file():
        print(f"no release notes at {path.relative_to(REPO_ROOT)}", file=sys.stderr)
        return 1

    fragment = render(path.read_text(encoding="utf-8"), keep_title=args.keep_title)
    if not fragment.strip():
        print(f"{path.relative_to(REPO_ROOT)} rendered to nothing", file=sys.stderr)
        return 1

    if args.out:
        out = pathlib.Path(args.out)
        out.parent.mkdir(parents=True, exist_ok=True)
        out.write_text(fragment, encoding="utf-8")
        print(out)
    else:
        sys.stdout.write(fragment)
    return 0


if __name__ == "__main__":
    sys.exit(main())
