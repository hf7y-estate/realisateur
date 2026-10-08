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
3. **Provision identity.** The code is still here (`provision/`,
   `bin/selfdev-*`); the ownership is ruled away: credentials are senechal's
   (hf7y-estate/senechal#1042), and so are the dexter host layer and the path
   a service takes onto it (hf7y-estate/senechal#886, #1379 here).
4. **Hold the cross-project view.** `/ideate` is the interactive pass that
   surfaces what no single project can see; `dose` apportions the fleet's work.

## What this is not

Not the scheduler. `hf7y/scheduler` owns dispatch, pacing and the ROSTER that
arms a project; realisateur owns what a run is graded by once it dispatches.
Proposals about the engine go to that repo, never a hand-edit from here.

Not senechal. `hf7y-estate/senechal` owns the machines: what exists on them,
their credentials, and how a container or a repo's hooks reach a host (#886,
#1042, #1130 there). realisateur grades that, runs the agent image (`agent/`),
and files through senechal's typed doors.
