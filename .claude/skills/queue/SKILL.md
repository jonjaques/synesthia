---
name: queue
description: Work the GitHub issue queue unattended. Use when the user says /queue, "work the queue", "drain the backlog", "start on the issues", or otherwise hands over a stack of queued work and leaves. Claims agent:ready issues one at a time, opens a PR each, and escalates anything needing a decision.
---

# Working the queue

Jon queues work as GitHub issues and walks away. You take them one at a time, land a PR for
each, and leave a clear trail of anything you couldn't decide. `docs/autonomy.md` is the
system's documentation; this is how you operate it.

The single most important property: **one blocked issue must never stall the run.** If you
can't finish something, label it, say precisely what you need, and move to the next one. Jon
should come back to progress plus a short list of real questions — not to a session that
stopped on question one two hours ago.

## Before starting the run

```bash
git switch main && git pull --ff-only
git status --porcelain     # must be empty — refuse to start otherwise
gh auth status
```

A dirty tree means uncommitted work you'd sweep into someone else's branch. Stop and say so.

## Pick the next issue

```bash
gh issue list --label "agent:ready" --state open --json number,title,labels,body \
  --jq 'sort_by(.number) | .[]'
```

Oldest first. Skip an issue whose **Depends on** names an issue that isn't closed — say which,
and come back to it later in the run once the dependency merges. If everything left is
blocked on something, stop and report.

Read the whole body. If it links a `docs/plans/*.md` file, that file is the design of record
and it is more authoritative than the issue's summary — read it too.

## Claim it

```bash
gh issue edit <n> --remove-label "agent:ready" --add-label "agent:working"
gh issue comment <n> --body "Starting — <branch name>."
```

Claim before you branch. The label is what stops a second session picking up the same issue.

## Do the work

```bash
git switch -c agent/<n>-<short-slug> main
```

Implement against the **acceptance criteria, verbatim**. They are the contract.

- **Never edit the acceptance criteria to make your work pass.** If a criterion is wrong,
  impossible, or contradicts the codebase, that is a blocker — escalate it (below). Rewriting
  the target and then declaring victory is the single worst thing you can do here.
- Follow `CLAUDE.md`. It is dense with gotchas that each cost a real bug: the Debug bundle
  merge trap, `nonisolated` AVFAudio callbacks, `VizUniforms` byte-identity, `grep -q` in a
  `pipefail` script, scene order in the `App` body. Read the relevant section before editing
  in that area rather than after CI tells you.
- Match the surrounding code's comment density and idiom. Comments here explain _why the
  obvious thing doesn't work_ — write that kind, or none.
- Commit in meaningful steps, not one giant blob.

Then, before opening anything:

```bash
make healthcheck          # lint + test + build-direct. Not optional.
```

Plus whatever the issue's **Verification command** says. If the issue asks for a behavioural
check you cannot make (something visual, something needing a permission grant), do the rest,
and say plainly in the PR that this part is unverified and why. Never imply you checked
something you didn't.

## Open the PR

```bash
gh pr create --title "<what changed>" --body "..." --label "<area:…>"
```

The body states what you **actually verified**, not what you intended. Include `Closes #<n>`.
If you made a judgment call the issue didn't cover, put it under a "Decisions I made" heading
so a reviewer can overrule it in one read.

## Merge — or don't

```bash
gh pr checks <pr> --watch
./scripts/risk-check.sh --base origin/main
```

Merge it yourself **only if all three hold**:

1. Every check is green.
2. `risk-check.sh` prints `low`.
3. The issue is labelled `risk:low`.

```bash
gh pr merge <pr> --squash --delete-branch
gh issue edit <n> --remove-label "agent:working"     # Closes #n shuts the issue
```

Squash is right for ordinary work — it is only release branches that must use `--merge`.

Otherwise:

```bash
gh pr edit <pr> --add-label "needs:human" --add-label "risk:high"
gh issue edit <n> --remove-label "agent:working" --add-label "agent:review"
```

and move on. **Run `risk-check.sh` yourself; never read back the `risk:high` label CI
applied.** That label is one you have permission to change, so trusting it is circular. The
script and the CI job read the same `.github/risk-paths.txt`, so they cannot disagree.

## When you're blocked

A blocker is: an ambiguous requirement, a decision with real trade-offs, a missing
credential, a criterion that can't be met, a failure you can't diagnose in reasonable time,
or anything that would need Jon's judgment about the product.

```bash
gh issue edit <n> --remove-label "agent:working" \
                  --add-label "agent:blocked" --add-label "needs:human"
gh issue comment <n> --body "..."
```

The comment is the whole point. Write it as you'd want to receive it:

- What you were doing and where you stopped.
- The precise question — one question, not a survey.
- The options you see, with the trade-off of each, and which you'd pick and why.
- What you've already tried, so nobody repeats it.
- Whether a branch exists and how far it got.

Push the partial branch if it has anything worth reading. Then **take the next issue**.

## Finish the run

Stop when nothing is `agent:ready` (or everything left is blocked on a dependency). Report:

- **Merged** — issue, PR, one line each.
- **Awaiting review** — PR links, and why each needs a human (risk path, or a judgment call).
- **Blocked** — issue links and the one-line question for each.
- Anything you noticed but didn't act on. File those as issues rather than burying them in
  prose; an observation in a chat log is lost the moment the session ends.

Then give him the three queries from `docs/autonomy.md`.

## Never

- **Never push to `main`**, never force-push, never rewrite published history.
- **Never cut, tag, build or publish a release.** Releases are targeted and approved by Jon,
  every time. `make bump`, `make direct`, `make appstore`, `make appcast`,
  `make publish-release`, `git tag`, and pushing a tag are all off-limits — even if an issue
  asks for them. An issue asking you to release is an issue to label `needs:human`. Changing
  the release _tooling_ under review is fine; operating it is not. See the `release` skill.
- **Never merge a PR the risk gate flagged**, whatever the issue's label says.
- **Never touch** secrets, `~/.ssh`, `chezmoi`, `1Password`, the Sparkle private key, or
  anything in `.github/` and `.claude/` that would widen your own permissions. Those paths are
  in `risk-paths.txt` precisely so you can propose changes but not self-approve them.
- **Never delete a branch with unmerged commits**, and never `gh pr close` someone else's PR.
- **Never leave an issue in `agent:working`.** Every path out of that state is a label change:
  merged, `agent:review`, or `agent:blocked`. If you crash mid-issue, the stale label is the
  only trace — so if you find one at the start of a run, comment on it and reset it to
  `agent:ready` rather than assuming.
- **Never invent scope.** Work the issue. A good idea you had along the way becomes a new
  issue, not a bigger diff.
