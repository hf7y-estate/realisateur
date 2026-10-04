# realisateur

**The estate's governance layer.** realisateur owns the rules the other
projects are graded by, and the machinery that grades them: the guards
(`atteste`, `gh-sign`, body-grammar, the deny lists), the release channel and
its promotion boundary, self-dev account provisioning, and the cross-project
view no single project's nightly can have.

## What governance means here

1. **Grade the estate.** Guards, ratchets and witnesses that other repos call
   or inherit. A rule with no mechanism is prose; see `PROSE-REAPING.md`.
2. **Ship the generation.** The release pin, the promotion boundary, and
   `vaporwave` as the proving ground — milestone `v2`, one name across repos
   (see `hf7y/scheduler`'s `v2`).
3. **Provision identity.** Self-dev accounts, the host-wide App key, the
   credential surface. `provision/` and `bin/selfdev-*`.
4. **Hold the cross-project view.** `/ideate` is the interactive pass that
   surfaces what no single project can see; `dose` apportions the fleet's work.

## What this is not

Not the scheduler. `hf7y/scheduler` owns dispatch, pacing and the ROSTER that
arms a project; realisateur owns what a run is graded by once it dispatches.
Proposals about the engine go to that repo, never a hand-edit from here.

Not senechal. `hf7y/senechal` owns knowing what exists on the machines;
realisateur owns what it generates, and files through senechal's typed doors.
