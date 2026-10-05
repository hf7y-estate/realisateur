---
scope: user
description: Interactive cross-project vision/triage pass -- surface state across the whole ecosystem (or one project), ask direct design questions, record decisions, queue priority. Does not scaffold or build.
argument-hint: "[project-name]"
---

<!-- Source: hf7y/realisateur:.claude/commands/ideate.md -- installed verbatim at
     USER level, so "this repo" below means realisateur, not your cwd. Edit it
     there, never the installed copy. -->

realisateur's interactive counterpart to `/nightly-batch` (unattended, builds).
Where nightly-batch scaffolds and implements, `/ideate` triages, prioritizes and
records. Default posture: **surface, ask, record, queue — not build, not
scaffold.** Say so explicitly if asked to do something this command defers:
*"that's a nightly-batch job, want me to queue it or just do it now?"* is a fine
thing to say; silently building anyway is not.

**This posture holds for the rest of THIS conversation, not just the first
response.** Nothing in the harness enforces a mode, so a build-shaped follow-up
twenty turns later gets the same answer as one in the first message. #339 is
closed: shortening this file resolved it, not a `UserPromptSubmit` hook.

**`$ARGUMENTS`:** with a project name, scope to that project — read
its open issues and skip the ecosystem sweep.
With no argument, run the full sweep.

## 1. Orient

`ausculte` for the estate's health before you touch any project.

**Read each project's open ISSUES, not its files.**

Don't trust a prior session's claims about status — start from what the survey
actually found, not a stale mental model.

## 2. Find what's worth surfacing

- **Urgent, small, low-ambiguity** — flag clearly, propose the fix, don't
  implement unless told to.
- **Real design forks** — multiple plausible directions. This is what
  `AskUserQuestion` is for. Ground each question in what the survey showed:
  cite the project, the issue, how long it has sat open.
- **Already-settled** — matches a standing decision. Don't re-litigate.
- **Synchronicities** (sweep only) — projects pointing at overlapping ground.
  The highest-leverage finding this command produces, since no single project's
  nightly-batch has the cross-project view.

## 2.5. Milestones: the loop is `bin/vision.sh`, one at a time

1. `bin/vision.sh queue` — every open milestone, worst first. Take the top
   `none` row: no stated close, and the most closes landed under it last week.
2. `bin/vision.sh card <repo> <n>` — show Zach exactly what it prints.
3. Ask the ONE question the card ends with. Offer candidate sentences if the
   issues suggest them; the answer is his.
4. `bin/vision.sh record <repo> <n> --quote '<his words>' --title '<a sentence
   true when done>' --closes-when '<command, else a sentence>' --apply`.
   `--quote` is verbatim or it is not written. A command beats a sentence.
5. Move each open issue that does not serve that close to the milestone it
   does serve, or close it with evidence. Then back to 1.

## 3. Ask, don't guess

For genuine forks, ask directly (`AskUserQuestion`, options with real
tradeoffs). Don't scaffold speculatively while waiting.

## 4. Record and queue, don't build

**Park by default.** Against the project's open **native GitHub milestone**
(`gh api repos/hf7y/<p>/milestones`): is this idea required to reach it? Yes → `active`;
if no, tag `(parked)` — or `(waiting: <dep>)` if blocked externally — and record
one line of why. The metric that matters is the *active* set draining, not the
parked reservoir shrinking; a free-fed reservoir is supposed to grow. Promoting
a parked idea is a deliberate, stated decision, never a silent reorder.

**Entry shape — vision, then milestones, then blockers:**
1. **Vision** — the goal in plain terms, and what is explicitly still open.
   Name what is NOT decided; don't let silence imply it is.
2. **Milestone chain** — numbered, working backward. Each step concrete enough
   that "is this idea required for the current step" is answerable.
3. **Blockers** — blocking the CURRENT step specifically, tagged by who can
   clear it (human-only vs buildable-now), not a generic backlog dump.

**Every destination is a command, never a file:**

- **realisateur's own scope** — file an issue on `hf7y/realisateur`.
- **Machine-wide config** (crontab, `~/.claude` hooks, systemd, autostart, WM
  config, `~/.local/bin`) — `notify-senechal <door> <field>=<value>`. TYPED
  since 2026-08-16 (#352); the prose form exits 2. realisateur owns what it
  generates, senechal owns knowing it exists.
- **Another project** — file an issue on **that project's** tracker, labelled
  `from:realisateur`. Every actor in this estate is `hf7y`, so authorship
  cannot answer "did a human ask for this, or did an agent find it"; the label
  is a sensor, not decoration. `check-project-busy` gates DIRECT file writes,
  not front doors like this one.

## 4.5. Vision debt, and overriding oldest-first

Rank by signal, not by date: age is the WEAKEST of five signals; re-arrival in the same shape is the
strongest; an idea re-arriving in a DIFFERENT shape each time gets its weight
*lowered*; a cross-project cluster is answered by naming the missing
regulator, not by promoting its members. Stamp a confirmed candidate so the
judgment is durable.

**Oldest-first is a signal, not a rule.** realisateur's cross-project view is
what makes it able to judge when a newer idea should jump ahead. When
overriding, **say which older item was passed over and why, in the issue** --
a silent reorder is indistinguishable from forgetting the item existed.

## 4.6. Stable build vs bigger dream

**Close to a stable core** -- near-term shape, unlikely to be discarded by the
idea changing under it; fine for nightly-batch to iterate. **Part of a
still-forming dream** -- likely to morph before anything built against its
current shape survives; slower iteration is the lever, not "don't build".

Record it **on an issue assigned to that milestone** (the `milestone` label was retired #738/#875). It is no longer a
`_paced.conf` weight: `scheduler/tempo.sh` paces on ACTIONABLE BACKLOG,
ROSTER's `rate` is only a ceiling, and `TEMPO_BASE_MIN` is the single fleet
knob. **Never edit a ROSTER row to change pace.**

## 5. Proposals about scheduler itself go through the front door

File an issue in `hf7y/scheduler`. Never hand-edit its engine from an ideate
session: it may have concurrent work in flight, and realisateur is not its owner.

## 6. Commit, push, and stop

Commit realisateur's own changes; findings went to issues in §4 and need no
commit. Push everything pushable and **name anything that could not push**. End
with: what is queued and where, and explicit confirmation that no project was
scaffolded and no feature code was written.
