# Queued work, and what needs a human

How to hand an agent a stack of work and leave, and how to find the things it couldn't
decide when you come back. Everything is tracked in GitHub — there is no second system, no
board to keep in sync, and nothing that only exists in a chat log.

The two skills that operate this live in `.claude/skills/`: **`queue`** works the backlog,
**`release`** ships a version. They are separate on purpose, because the second one is never
autonomous.

---

## The three queries

Bookmark these. They are the whole status surface.

| What                                | Query                                                                                                                       |
| ----------------------------------- | --------------------------------------------------------------------------------------------------------------------------- |
| **Decisions waiting on you**        | [`is:open label:needs:human`](https://github.com/jonjaques/synesthia/issues?q=is%3Aopen+label%3Aneeds%3Ahuman)              |
| **PRs an agent can't merge itself** | [`is:open is:pr label:needs:human`](https://github.com/jonjaques/synesthia/pulls?q=is%3Aopen+is%3Apr+label%3Aneeds%3Ahuman) |
| **Where an agent gave up, and why** | [`is:open label:agent:blocked`](https://github.com/jonjaques/synesthia/issues?q=is%3Aopen+label%3Aagent%3Ablocked)          |

If all three are empty, nothing is waiting on you.

## Queueing work

File issues with the **Agent task** template (or **Carry out a plan**, for anything already
designed in `docs/plans/`). Both land with `agent:ready`, which is the only thing the loop
looks for.

The fields exist to remove guesses:

- **Acceptance criteria** are a contract. An agent may not reword them to make its work pass
  — if one is wrong, it stops and says so. Write them so someone who didn't write the code
  can check each one.
- **Open questions** is the escape hatch. Anything you put there guarantees the agent asks
  instead of choosing.
- **Depends on** is honoured: the loop skips an issue until the issues it names are closed.
- **Risk** says whether an agent may merge its own PR. It is intent, not permission — see
  below.

Then: `/queue`, and walk away.

## The states

One `agent:*` label at a time, and `needs:human` orthogonal to all of them.

```
                    ┌──────────────┐
   you file it ───► │ agent:ready  │
                    └──────┬───────┘
                           │ claimed
                    ┌──────▼───────┐
                    │ agent:working│
                    └──┬────────┬──┘
          green CI,    │        │   anything needing judgment
          risk:low     │        │
              ┌────────▼──┐  ┌──▼──────────────┐
              │  merged   │  │ agent:blocked   │ + needs:human
              │  (closed) │  └─────────────────┘
              └───────────┘
                       or  ┌─────────────────┐
                           │ agent:review    │  PR open, yours to merge
                           └─────────────────┘
```

An issue found sitting in `agent:working` at the start of a run is a crashed session, not
work in progress. The loop comments on it and resets it rather than assuming.

## What an agent may merge

Two independent gates, both reading `.github/risk-paths.txt`:

1. **`risk-gate`** in `healthcheck.yml` classifies the PR's diff and labels it `risk:high`.
   It never fails the PR — that would make protected paths unmergeable by anyone, you
   included.
2. **The loop runs `scripts/risk-check.sh` itself** before merging, and refuses on `high`.

The second exists because the first produces a label, and a label is something the loop has
permission to change. Reading it back would be circular. Both read one file, so they can't
drift.

Protected paths, and why each is there, are documented inline in `.github/risk-paths.txt`.
The short version: code signing and entitlements (wrong here means a silent runtime denial
that CI can't see, because CI ad-hoc signs), the Xcode project, everything release-related,
the Sparkle serving path in `web/`, the `VizUniforms` ↔ MSL contract, and the rules
themselves — an agent that can widen its own permissions has none.

```bash
./scripts/risk-check.sh                    # this branch vs origin/main
./scripts/risk-check.sh --files a.swift b  # judge a hypothetical
```

## Releases are never autonomous

**Every release is targeted and approved by a human.** An agent working the queue may not run
`make bump`, `make direct`, `make appstore`, `make appcast` or `make publish-release`, may not
create or push a tag, and may not open a `release/*` branch — even if an issue asks it to. An
issue asking for a release is an issue to label `needs:human`.

Changing the release _tooling_ is ordinary work: it lands as a PR, the risk gate marks it
`risk:high`, and you merge it. Operating that tooling is yours alone. The procedure is the
`release` skill and `docs/distribution.md`.

Two guards back this up rather than relying on the rule being remembered:

- `publish-release.sh` refuses to publish a version whose `v<version>` tag is not an ancestor
  of `origin/main`. The merge-back stops being a step in a checklist and becomes a
  precondition of shipping.
- `.github/workflows/release-integrity.yml` watches for drift — a tag off mainline, a
  `VERSION` that disagrees with the newest tag, a published feed missing the current version,
  or any enclosure URL that doesn't answer 200. On failure it files a `needs:human` issue
  rather than only going red in a tab nobody has open. It runs on pushes to `main`, on tag
  pushes, and weekly.

Both exist because `v1.2` is permanently orphaned: its release branch was squash-merged,
which rewrote the tagged commit, and the branch was then deleted. Release branches merge with
`--merge`, never `--squash`.

## Labels

`.github/labels.yml` is the source of truth; GitHub is the copy.

```bash
make sync-labels-dry-run    # what would change
make sync-labels            # apply it
```

Idempotent, and it never deletes — a label removed from the file is left alone, because
deleting one strips it from every issue that carried it with no undo.

## Files

| Path                                      | What                                         |
| ----------------------------------------- | -------------------------------------------- |
| `.claude/skills/queue/SKILL.md`           | the loop: claim, work, PR, merge or escalate |
| `.claude/skills/release/SKILL.md`         | the release runbook, human-initiated         |
| `.github/labels.yml`                      | labels as data                               |
| `.github/risk-paths.txt`                  | what an agent may not merge, and why         |
| `.github/ISSUE_TEMPLATE/`                 | the queue formats                            |
| `.github/workflows/healthcheck.yml`       | the PR gate, plus `risk-gate`                |
| `.github/workflows/release-integrity.yml` | tag/version/published drift → `needs:human`  |
| `scripts/risk-check.sh`                   | the shared classifier                        |
| `scripts/sync-labels.sh`                  | applies `labels.yml`                         |
