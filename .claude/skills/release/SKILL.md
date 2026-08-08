---
name: release
description: Cut, build, merge back and publish a Synesthia release. Use when the user asks to cut, ship, tag, publish or release a version, or to resume a release that stalled partway. Human-initiated only — never start this from a queued issue or on your own initiative.
---

# Cutting a release

**Every release is targeted and approved by Jon.** He names the version or the level; he
approves the notes; he approves the merge; he approves the publish. Your job is to run the
steps correctly, show him what each one produced, and stop at the gates. Nothing in this file
is a licence to release without being asked — see _Never_ below.

The full reference is `docs/distribution.md`. This is the operating procedure.

## Before anything

```bash
make version                  # what we're coming from
git status --porcelain        # must be empty
gh pr list --state open       # anything that should land first?
```

Ask which level, unless he already said: `patch` (1.2.1 → 1.2.2), `minor` (→ 1.3.0), `major`
(→ 2.0.0), or an explicit version. Versions are always three components. If he says "1.3",
confirm he means `1.3.0` — the script will pad it, and it's better he knows that now than
sees it in a tag.

## 1. Cut the release commit

```bash
git switch -c release/<version>
make bump BUMP=<level>
```

`bump-version.sh` bumps nine `MARKETING_VERSION` and nine `CURRENT_PROJECT_VERSION` settings
in `project.pbxproj`, rewrites `VERSION` and `web/src/consts.ts`, drafts
`docs/releases/<version>.md`, commits, and creates an annotated `v<version>` tag.

**The notes are a draft and he reads them.** The script pauses on them for exactly that
reason. Do not pass `-y`. If you are running the bump on his behalf, show him the draft and
wait; the notes are what every existing user sees in the Sparkle update window, and they are
the most-read prose the project produces.

`RELEASE.size` in `web/src/consts.ts` is not updated by the bump — the DMG's size isn't known
until step 3. Update it by hand afterwards if the site quotes it.

## 2. Get it onto main — with a real merge commit

```bash
git push -u origin release/<version> --follow-tags
gh pr create --label area:release --label risk:high
```

Wait for green CI, then — after he approves:

```bash
gh pr merge --merge --delete-branch
```

**`--merge`, never `--squash`.** Squashing rewrites the commit the tag points at, so the tag
is left reachable only from a branch that the merge then deletes. `git describe` on main
stops seeing it, `bump-version.sh`'s `resolve_base` can't find it to diff the next release's
notes against, and the DMG in R2 corresponds to a commit nowhere in the history. `v1.2` is
permanently in that state; it is the reason `publish-release.sh` now refuses to publish a
version whose tag isn't an ancestor of `origin/main`.

## 3. Build, sign, notarize

```bash
git switch main && git pull
git diff --quiet v<version> -- . || echo "main has moved past the tag — stop and re-cut"
make direct
```

Notarization takes a few minutes and is the step most likely to stall. If it fails, the
output names the ticket; `xcrun notarytool log` has the detail.

For an App Store release, `make appstore` then `make appstore-upload` — and note the App
Store and direct builds are different targets with different entitlements, so a direct build
passing proves nothing about the store one.

## 4. Feed and publish

```bash
make appcast          # fetches the live feed, adds this version, signs it
make publish-dry-run  # read this properly — it lists every file and every URL
make publish-release
```

Read the dry run before approving the real one. Things worth actually looking at:

- Is the new DMG in "would upload"? Is anything unexpected there?
- Are deltas listed? A delta is a `Synesthia<new>-<old>.delta` and is fetched by everyone one
  version behind. They are served now, but they weren't for the whole of 1.2.1's life.
- Does "would leave in place" cover every older version still in the feed?

`publish-release.sh` uploads DMGs first, then `latest.json`, then the appcast — the appcast is
the announcement and must go last. It hard-fails if a filename is already published with
different bytes, and now also if the tag hasn't reached main.

## 5. Confirm users can actually get it

The publish script probes every URL it uploaded. Beyond that:

```bash
gh workflow run release-integrity.yml && gh run watch
```

And the real proof, if anything looked odd: install the previous version into a scratch
directory and let Sparkle update it, watching
`log stream --predicate 'subsystem == "org.sparkle-project.Sparkle"'`. That is how the delta
404 was found, and no amount of green CI would have shown it.

## Never

- **Never start a release.** Not from an issue, not from a queue, not because `VERSION` looks
  stale, not because a PR said "ready to ship". Jon targets and approves every release.
- **Never `--squash` a release branch.** See step 2.
- **Never `git tag -f` or force-push a tag.** An orphaned tag is annoying; a rewritten one
  breaks anyone who already fetched it.
- **Never pass `--allow-unmerged` to `publish-release.sh`** unless he explicitly asks for it,
  in that session, having been told what it skips.
- **Never `-y` the notes.**
- **Never publish and then merge.** The bytes are public the moment the appcast lists them.

## When it stalls partway

Every step is idempotent and re-running is the recovery. What state you're in:

| Symptom                                    | Where you are          | Do                                              |
| ------------------------------------------ | ---------------------- | ----------------------------------------------- |
| Tag exists, no PR                          | after 1                | push and open the PR                            |
| PR merged, no DMG                          | after 2                | `make direct`                                   |
| DMG built, feed unchanged                  | after 3                | `make appcast`                                  |
| Feed uploaded, a URL 404s                  | after 4                | re-run `make publish-release`                   |
| `publish-release` refuses: tag not on main | 2 was skipped          | merge the release branch, then re-run           |
| Sparkle reports a download error           | published, edge cached | check `release-integrity`; probe with `?probe=` |
