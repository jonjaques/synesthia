#!/usr/bin/env python3
"""Check the App Store metadata drafts against Apple's field limits.

App Store Connect silently truncates nothing — it just refuses to save — so
catching an over-long subtitle here beats discovering it while filling in the
listing.

    python3 scripts/check-metadata.py
"""
import re
import sys
import os

DOC = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                   "docs", "app-store-metadata.md")

# heading fragment -> max length (None = no limit, just report)
LIMITS = {
    "Name": 30,
    "Subtitle": 30,
    "Promotional text": 170,
    "Keywords": 100,
    "Description": 4000,
    "What's New in This Version": 4000,
    "Review notes": None,
}


def sections(text):
    """Yield (heading, first fenced code block) for each ## section."""
    parts = re.split(r"^## ", text, flags=re.M)[1:]
    for part in parts:
        heading = part.split("\n", 1)[0].strip()
        blocks = re.findall(r"^```\n(.*?)^```", part, flags=re.M | re.S)
        yield heading, (blocks[0].rstrip("\n") if blocks else None)


def main():
    text = open(DOC).read()
    found = {}
    for heading, body in sections(text):
        for key in LIMITS:
            if heading.startswith(key) and body is not None and key not in found:
                found[key] = body

    failures = 0
    for key, limit in LIMITS.items():
        body = found.get(key)
        if body is None:
            print(f"  {key:28s} MISSING")
            failures += 1
            continue
        n = len(body)
        if limit is None:
            print(f"  {key:28s} {n:5d} chars  (no limit)")
        elif n > limit:
            print(f"  {key:28s} {n:5d} chars  OVER LIMIT of {limit} by {n - limit}")
            failures += 1
        else:
            print(f"  {key:28s} {n:5d} chars  ok (limit {limit}, {limit - n} spare)")

    kw = found.get("Keywords")
    if kw:
        if " " in kw:
            print("\n  note: keywords contain spaces — each one costs a character")
        print(f"  keywords: {len(kw.split(','))} terms")

    print()
    if failures:
        print(f"{failures} problem(s).")
        sys.exit(1)
    print("All fields within limits.")


if __name__ == "__main__":
    main()
