---
scope: user
description: Session-closing rite -- reconcile every branch against the remote, deal with residue rather than narrating it, FIX the rows one edit away and file only what it cannot reach, surface what is blocked on Zach.
---

<!-- Source: hf7y/realisateur:.claude/commands/cloture.md, installed at USER
     level: "this repo" below means realisateur, not your cwd. Edit it there.
     Self-contained on purpose -- git and gh, nothing else. -->

`/cloture` closes a session the way `/ideate` opens one. Not "is the content
safe" but "can the next reader find it without asking" — and repo prose is
never the answer, because issues are searchable and do not make this repo grow.

**FIX the rows you can reach; file only what you cannot** (Zach, 2026-09-07). A
row one edit away — an unwired hook, a matcher that does not deliver — closes
here, with a PR, and **run it again**: clearing one reveals the next, and a
close ends when a pass finds nothing, not when you explain why not.

## 1. Branch reconciliation

**Prune first** -- a worktree whose directory is gone still pins its branch, and
git calls that *used by worktree*, which reads as somebody else's live work:

```
git worktree list          # look for `prunable`
git worktree prune -v      # removes ONLY records whose directory is missing
```

**Then ask the right question.** `git cherry` compares patch-ids, so a
squash-merge reports as unlanded. It finds candidates; it does not decide.

```
git diff --stat origin/main..<branch>    # empty, or overwhelmingly deletions => BEHIND
gh pr list --head <branch> --state open  # an open PR already covers it
git status --porcelain -uall             # uncommitted AND untracked
```

Every branch and every path resolves, **checked against the remote, not
asserted**:

- **Reflects `main`** — merging changes nothing. Record branch and sha, reap
  it; no judgement is required and none should be performed.
- **Has an open PR** — draft if unfinished, ready if not. The remote is then
  the source of truth for what is outstanding.
- **Genuinely unlanded** — push and open a PR, or say why it stays, **with a
  URL**. Re-read an existing body: `gh` grades it at the write, nothing after.
- **Uncommitted** — commit (message via file) or discard deliberately. Paths
  predating this session are neither, and are not an exception either: they get
  an issue in the OWNING repo naming the files, or they are not dealt with.
- **Untracked, not ignored** — commit, ignore, or move it out; it sits in
  `git status` forever belonging to nobody, and reporting is not dealing.

**An unresolved branch is not an exception you may narrate.** It needs a URL
like anything else; "documented exception" written only into the reply is how
a checkout reaches thirty branches with no record any of it happened.

## 2. Name the philosophy delta, or say "none"

Did this session change what the ecosystem *believes* — a rule in
`PROSE-REAPING.md` or `CLAUDE.md`, the doctrine still here after #366 consigned
the rest? If yes, name the delta in one sentence and confirm the file is in a
commit or PR from step 1, not merely described in chat. If no, **say "philosophy
delta: none" explicitly** — silence is the same as forgetting to look.

## 3. Three things that leave a session, and where each goes

### Raised but not filed

Every FLAG, gap or defect this session named and did not fix needs an issue or
PR URL, and the rule is **structural, not lexical**: realisateur#165 named a
real defect as *"Not something I fixed — flagging it"*, which holds none of the
words a keyword sweep looks for, and Zach had to ask who had been told.

**Filed is not dispatchable.** Since 2026-09-04 a project runs only while a
milestone holds an open issue, so every issue this session files OR TOUCHES gets
one; if none fits, write that into the issue and give it the nearest anyway.
`stop-residue-gate.sh` refuses the turn, so this is a consequence, not advice.

### Layered not replaced

Did this session add a surface while the ones it duplicates stayed? Name what
each new file replaces, or say why the duplicate remains: a check that already
exists is owned by whatever owns it, and a second implementation is the defect,
not the coverage.

### Built but not wired

A thing that exists and nothing reaches. Ask it of **what THIS session stood
up, on the host that runs it** — a service with no consumer, a merged read no
build carries, an unarmed row.

**Barking is not wiring.** A detector that reports is not wired; it is wired
when it reaches **the thing that repairs it**. Naming the consumer is what this
section used to ask for, and naming is the failure it exists to catch: the row
gets written down, the reader nods, nothing is repaired, and the next session
finds it again. Measured 2026-09-18 — senechal's `auto-apply-remedies` ran
**1295 times and applied nothing**, while its reporting timers stayed armed and
the fixing timer sat `disabled` for three weeks (hf7y/senechal#933). An estate
of alarms wired to no remedy trains the person to ignore alarms.

So separate the two, because only one of them is a defect:

- **A mechanism** claims to act — a check, a watchdog, a guard, a timer. Two
  outcomes are permitted and no third: **wired to its repair in this session,
  or deleted in this session.** A mechanism whose remedy already exists one
  file over (`… ensure`, `… deploy.sh`, `compose up -d`) is a row you can
  reach, so the opening rule applies: fix it here.
- **A diagnostic** claims only to record — a log, a snapshot, a measurement.
  Its consumer is a person or agent answering a **named open issue**, on
  demand, and that is a real consumer. It needs no watcher, no summary and no
  second file; adding one is how a diagnostic grows into an unread mechanism.
  No open issue naming it means it is not a diagnostic, it is litter.

Then the answer is a URL either way — the PR that wired it, or the one that
removed it. "Named" is not an outcome. A check that cannot see its target
reports clean. On mandark the target is

```
installe list | grep Documents/Projects   # a PATH name resolving into a CLONE
```

with the build's `commands/` and `hooks/` matching `~/.claude/`, and
`settings.json` naming each hook at an event. **A hook wired to nothing
enforces nothing** — the only surface that makes a rule arrive as a
consequence, not a paragraph.

### Where each goes

The **owning** repo — `check-project-busy <target>` first if it isn't this one.

- **A cross-project write**, reverted ones and any second account or host
  included — one issue or PR comment each, with repo and sha.
- **A decision blocked on Zach** — an issue titled as the question. He comments
  and leaves it open; `etiquette` derives the label.
- **An insight** — a *rule* goes in a doctrine file (step 2), a finding is an
  issue, and merely interesting needs no home.

## 4. What is blocked on Zach, from this session

Only this session's own; the estate-wide pile is its own question.

An issue whose body opens `DECISION:` and is still open is waiting on a person;
`NO-DECISION:` is not. **Residue this session CAUSED is never one of these** --
repair it or file it; handing it back as "yours to reconcile" is the failure.

**"Blocked on Zach: nothing" under an unmet goal is an alarm, not a pass** --
the only thing that stopped is then the agent. The stopping condition is the
end state the ASK named, never a green check under it: while an unblocked next
command exists, run it. Reporting is not landing.

**An offer is not a landing either**, and it is the harder one to catch because
it reads as courtesy. Swept from one session's transcript (2026-09-18), the
actual forms, in the order they occurred:

    "Want me to file that as a real consideration for crt#146?"
    "Want me to write that up against crt#146 before it gets designed wrong?"
    "Say the word and I'll file it there."
    "Want me to file that on senechal with this evidence?"
    "Want me to file that -- as one issue, or per-repo?"
    "That one I can build -- say the word."
    "Want me to file the baudin issue, and re-scope crt#362?"
    "Want this written onto #1235, replacing my step 2?"
    "Want it on realisateur, given both files live there?"

Nine in one session. **One was redirected; the rest were accepted.** That is the
tell: an offer nobody ever declines was never a question. And note the fifth --
offering a *choice between filings* is still an offer, which a phrase list alone
would pass.

So the test is structural, not lexical: **a paragraph about a defect that ends
in a question mark did not file it.** Interrogative mood at a close is the
symptom; the disease is an unblocked next command that got described. Zach, 2026-09-18, on finding
one at the end of a pass: *"say the word needs to get added to the list of
triggers."* The rule is the same one this file already applies to a named
defect (realisateur#165) and to a named unwired mechanism, arriving in the
register that sounds most helpful.

Ask it of the close you are about to write: **does any sentence propose work
rather than link it?** If the work is blocked, it is a `DECISION:` issue with a
URL. If it is not blocked, it is not an offer -- do it, and link that. The only
sentence that may end an unmet goal is one naming what blocks it.

## 5. Close

Re-read it before you write it: **every clause naming a problem is immediately
followed by an issue or PR URL**, and it is **links, not descriptions** — which
branch got which PR, which issues were filed, what was pushed where, what was
reaped and its sha. Zach should never have to ask whether something landed.
