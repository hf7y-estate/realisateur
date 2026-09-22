---
scope: user
description: Work one self-dev repo's open issues end to end -- rank the estate, pick the repo that unblocks the most, clear its blockers, and realign its milestone when the issues no longer match it. Builds; one repo per run.
argument-hint: "[repo-name]"
---

<!-- Source: hf7y/realisateur:.claude/commands/debloque.md -- installed verbatim
     at USER level, so "this repo" below means realisateur, not your cwd. Edit
     it there, never the installed copy. -->

`/ideate` surveys the estate and refuses to build. `/reap` cuts one repo's
prose and issue count. `/debloque` is the third: **one repo, its open issues,
worked.** It builds.

**One repo per run.** Finish it or say why you stopped. Do not start a second.

## 1. Rank, then name the repo

```
bin/rang-selfdev.sh
```

Three sections, answering three different questions. Pick from them in order:

1. **GATE CLOSED** — armed in ROSTER, zero open milestone issues. Its nightly
   wakes and dispatches into nothing. Cheapest repair in the estate and it
   costs a fleet slot every 20 minutes until it is made. Always first.
2. **UNBLOCKS MOST** — open PRs plus human-owned blockers. An open draft PR is
   finished work nobody merged; it unblocks at a better rate than anything you
   would write today.
3. **VISION DEBT** — unmilestoned stock, and the largest single milestone. A
   milestone holding 30+ issues is a bucket, not a goal: it cannot answer *is
   this required to reach it*, which is the one question it exists to answer.

With `$ARGUMENTS`, skip the pick and work that repo — but still run the rank,
and **say in one line which higher-ranked repo you passed over.**

Numbers in a headline are stale by construction. Re-derive before acting on one.

## 2. Work it

Read the repo's open **issues** (`BLOCKERS.md`/`FOCUS.md`/`QUESTIONS.md` were
retired estate-wide by `hf7y/scheduler#66`). Then, in this order:

- **Merge what is already written.** A draft PR that passes, and its issue.
  `gh pr ready` and `gh pr edit` die on a projectCards deprecation — use
  `gh api` directly.
- **Fix what is one edit away** — unwired, unreplaced, built-not-wired. Do not
  file an issue for a row you can reach; filing it is the slower way to do it.
- **Escalate what only Zach can clear.** One question, one concrete thing, 2-3
  lines, fits a phone screen. Guards escalate via `demande`, never fatal.
  Anything machine-state goes through `notify-senechal <door> <field>=<value>`
  — typed; prose exits 2.
- **Close what is already true.** An issue whose fix landed is noise that
  inflates every count above it.

Leave the rest. A repo you emptied by closing what you did not work is worse
than one you did not touch.

## 3. Realign the milestone, only when the issues say to

The milestone is the dispatch gate: no open issue in an open native milestone
and the project does not run. So two failures, with different repairs:

- **Gate closed** — issues exist, none carry the milestone. The repair is
  assigning or filing one, *not* building. Name the milestone when you file.
- **Bucket** — one milestone holds most of the repo. Split it against what the
  repo is actually for, or say plainly it is not a milestone and what is.

Either way, write the milestone's vision as **what is still open**, not only
what is decided — silence reads as settled. Promoting a parked idea is a stated
decision; a silent reorder is indistinguishable from forgetting.

## 4. Landing

Branch and PR, never a commit to local `main` — direct pushes are refused for
everyone. Another project's work is an issue on **that** repo labelled
`from:realisateur`, never a file write from here. Proposals about the engine go
to `hf7y/scheduler`.

End with: the repo, what merged, what closed, what is now in front of Zach and
where, and the next repo the rank names.
