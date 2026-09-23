---
scope: user
description: Session-closing rite -- reconcile every branch against the remote, deal with residue rather than narrating it, FIX the rows one edit away and file only what it cannot reach, surface what is blocked on Zach.
---

<!-- Source: hf7y/realisateur:.claude/commands/cloture.md, installed at USER
     level: "this repo" below means realisateur, not your cwd. Edit it there.
     Self-contained on purpose -- git and gh, nothing else.
     Every rule here is one line and a citation. The argument lives in the
     issue, per the rule in section 0. -->

`/cloture` closes a session the way `/ideate` opens one: not "is the content
safe" but "can the next reader find it without asking". Repo prose is never the
answer -- issues are searchable and do not make this repo grow.

## 0. Posture

- **FIX the rows you can reach; file only what you cannot** (Zach, 2026-09-07). A row one edit away closes here, with a PR.
- **Then run it again.** Clearing one reveals the next. A close ends when a pass finds nothing, not when you explain why not.
- **A repeat pass audits the LAST pass before hunting new ground.** Re-read what it asserted and re-run the command behind every number.
- **Retracting the pass before is oscillation, not progress** (#1247). Cost is asymmetric: an unfound defect waits quietly, a wrong claim in an issue gets built on.
- **Verify as the CONSUMER invokes.** Your shell has your exports; cron has none. `env -i` asks the real question (crt#363).
- **A convenient number is the likeliest lie.** A `0`, a round figure, a count agreeing with the hypothesis: run the second command that separates the answer from how you asked.
- **Evidence for a rule belongs in the PR that adds it, not in this file.**

## 1. Branch reconciliation

Prune first -- a worktree whose directory is gone still pins its branch, and git calls that *used by worktree*:

```
git worktree list                        # look for `prunable`
git worktree prune -v                    # removes ONLY records whose dir is missing
git diff --stat origin/main..<branch>    # empty or all-deletions => BEHIND
gh pr list --head <branch> --state open  # an open PR already covers it
git status --porcelain -uall             # uncommitted AND untracked
```

`git cherry` compares patch-ids, so a squash-merge reports as unlanded. It finds candidates; it does not decide.

Every branch and path resolves **against the remote, not asserted**:

- **Reflects main** -- record branch and sha, reap it. No judgement required.
- **Open PR** -- draft if unfinished, ready if not. Re-read the body; `gh` grades it at the write, nothing after.
- **Unlanded** -- push and open a PR, or say why it stays, with a URL.
- **Uncommitted** -- commit (message via file) or discard deliberately. Paths predating this session get an issue in the owning repo naming them.
- **Untracked, not ignored** -- commit, ignore, or move it out.

**An unresolved branch is not an exception you may narrate.** It needs a URL like anything else.

## 2. Philosophy delta

Did this session change what the ecosystem *believes* -- a rule in `PROSE-REAPING.md` or `CLAUDE.md`? Name the delta in one sentence and confirm it is in a commit or PR from step 1. If not, **say "philosophy delta: none"** -- silence is the same as forgetting to look.

## 3. What leaves a session

### Raised but not filed
Every FLAG, gap or defect named and not fixed needs an issue or PR URL, **subject to the budget below**. The rule is **structural, not lexical**: #165 named a real defect as *"Not something I fixed -- flagging it"*, which holds none of the words a sweep looks for.

**Filed is not dispatchable.** A project runs only while a milestone holds an open issue, so every issue filed OR TOUCHED gets one; if none fits, write that into the issue and give it the nearest anyway. `stop-residue-gate.sh` refuses the turn.

**Not everything noticed is a finding.** File what BLOCKS the end state the session was asked for, or what a person would act on this month. A defect met in passing while debugging something else is noise in a tracker you do not own; note it in the close and let it be re-found by whoever it blocks. #1276, #1281 and #1286 were closed as noise minutes after filing.

**Budget: at most TWO issues into a repo that is not the session's subject.** Past two, consolidate into one issue listing the rest. A session about a film score filed SEVEN into realisateur, each defensible alone, and the total was never looked at because nothing counted it. **The close states the count**, per repo, so the number is visible before it is paid.

### Layered not replaced
Did this session add a surface while the one it duplicates stayed? Name what each new file replaces, or why the duplicate remains. A second implementation is the defect, not the coverage.

### Built but not wired
A thing that exists and nothing reaches, asked of **what THIS session stood up, on the host that runs it**.

**Barking is not wiring.** A detector is wired when it reaches **the thing that repairs it**, not when it reports (senechal#933).

- **A mechanism** claims to act -- check, watchdog, guard, timer. Two outcomes, no third: **wired to its repair this session, or deleted this session.** A remedy one file over is a row you can reach, so section 0 applies.
- **A diagnostic** claims only to record -- log, snapshot, measurement. Its consumer is a person or agent answering a **named open issue**. No such issue means it is not a diagnostic, it is litter.

The answer is a URL either way -- the PR that wired it, or the one that removed it. On mandark the target is `installe list | grep Documents/Projects` (a PATH name resolving into a CLONE), the build's `commands/` and `hooks/` matching `~/.claude/`, and `settings.json` naming each hook at an event. **A hook wired to nothing enforces nothing.**

### Where each goes
The **owning** repo -- `check-project-busy <target>` first if it isn't this one.

- **A cross-project write**, reverted ones and any second account or host included -- one issue or PR comment each, with repo and sha.
- **A decision blocked on Zach** -- an issue titled as the question. He comments and leaves it open; `etiquette` derives the label.
- **An insight** -- a *rule* goes in a doctrine file (step 2), a finding is an issue, merely interesting needs no home.

## 4. Blocked on Zach

Only this session's own. An open issue whose body opens `DECISION:` is waiting on a person; `NO-DECISION:` is not.

- **Residue this session CAUSED is never one of these.** Repair it or file it; handing it back is the failure.
- **"Blocked on Zach: nothing" under an unmet goal is an alarm**, not a pass -- the only thing that stopped is the agent. While an unblocked next command exists, run it.
- **An offer is not a landing.** "Want me to file that?", "say the word and I'll build it" -- nine in one session, one declined (#1239). An offer nobody declines was never a question.

The test is structural: **a paragraph about a defect ending in a question mark did not file it.** Ask of the close you are about to write: **does any sentence propose work rather than link it?** If blocked, it is a `DECISION:` issue with a URL. If not blocked, it is not an offer -- do it, and link that.

**No future-tense verb about your own work.** Not "filing that now", "will file", "next I'll land". The question-mark test misses the declarative future, which reads as compliance and lands nothing -- a well-formed sentence discharges the obligation, and "filing now" is indistinguishable from having filed at the moment you write it. If it is not done it gets a URL or it gets named as blocked, never a sentence. Measured 2026-09-23: one session hit this three times in a row, the third time while explaining the first two (#1280).

## 5. Close

**Answer two questions in plain words before any link:** what needs Zach (usually nothing), and whether this session's own goal landed. A close that has to be decoded has closed nothing -- Zach, 2026-09-23, on one that opened with three issue references: *"what is this... how you landed it was worse than useless"*.

Then the evidence: **every clause naming a problem is immediately followed by an issue or PR URL** -- which branch got which PR, which issues were filed, what was pushed where, what was reaped and its sha. Links are the proof, not the report. A URL standing where a sentence belongs fails exactly as a sentence standing where a URL belongs.

Zach should never have to ask whether something landed, **or what you just said**.
