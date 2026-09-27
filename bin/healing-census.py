#!/usr/bin/env python3
"""What did a closure actually LEAVE? The estate's healing, graded on repo history.

  python3 bin/healing-census.py                 # every repo, since 2026-08-01
  python3 bin/healing-census.py --repo dog      # one repo
  python3 bin/healing-census.py --json          # the record, for a page or a diff

realisateur#791 measured that 80% of issues close and 26% of closures carry a
linked PR, and read the other 74% as an agent asserting the work was done. That
reading is wrong often enough to matter: dog#5 closed with no linked PR and was
CORRECT -- the code had landed, and the PR body said `Closes issue #5:` instead
of `Closes #5`, which is not a closing keyword, so GitHub linked nothing.

So a closure is graded here on the strongest evidence that survives it, and the
link is only the top rung:

  LINKED     a PR is truly linked (`closedByPullRequestsReferences`)
  COMMITTED  no link, but the repo's own history names the issue -- a commit
             referencing it, or a MERGED PR cross-referencing it. This is the
             dog#5 class: real work, broken bookkeeping.
  VERIFIED   no code, but the closing comment carries a command and its output,
             so the claim is checkable by someone who was not there
  ASSERTED   prose only

The ladder is the point. `LINKED` is not the target: a set point that counts
links would have graded the dog#5 pass a failure and made manufacturing a commit
the cheapest way to pass -- the metric-collapse this estate has already shipped
once, when tuning prose against style.mjs flattened the variance the metric
stood for. `COMMITTED + VERIFIED` is what a good pass leaves when there is no PR
to leave, and both are read from artifacts the pass cannot fake cheaply.

BLIND, NEVER CLEAN: a repo whose issues could not be read is reported as blind
and excluded from the shares, never counted as zero closures.
"""
import argparse, json, re, subprocess, sys

SINCE_DEFAULT = "2026-08-01"
# A command and its output, in the two shapes the estate's own comments use: a
# fenced block, or a `$ `-prefixed line. Prose about a command matches neither.
EVIDENCE = re.compile(r"```|^\s{0,4}\$ \S", re.M)

QUERY = """
query($owner:String!, $repo:String!, $after:String) {
  repository(owner:$owner, name:$repo) {
    issues(states: CLOSED, first: 50, after: $after,
           orderBy: {field: CREATED_AT, direction: DESC}) {
      pageInfo { hasNextPage endCursor }
      nodes {
        number createdAt closedAt stateReason title
        labels(first: 20) { nodes { name } }
        closedByPullRequestsReferences(first: 1, includeClosedPrs: true) { totalCount }
        timelineItems(last: 60, itemTypes: [REFERENCED_EVENT, CROSS_REFERENCED_EVENT]) {
          nodes {
            __typename
            ... on CrossReferencedEvent { source { __typename ... on PullRequest { merged } } }
          }
        }
        comments(last: 1) { nodes { body } }
      }
    }
  }
}
"""


def gh_graphql(owner, repo, after):
    cmd = ["gh", "api", "graphql", "-F", f"owner={owner}", "-F", f"repo={repo}", "-f", f"query={QUERY}"]
    cmd += ["-F", f"after={after}"] if after else []
    p = subprocess.run(cmd, capture_output=True, text=True)
    if p.returncode != 0:
        raise RuntimeError(p.stderr.strip().splitlines()[-1] if p.stderr.strip() else "gh exited nonzero")
    return json.loads(p.stdout)["data"]["repository"]["issues"]


def committed(issue):
    """Does the repo's history name this issue, without a link to show for it?"""
    for t in issue["timelineItems"]["nodes"]:
        if t["__typename"] == "ReferencedEvent":
            return True          # a commit naming the issue
        src = (t.get("source") or {})
        if src.get("__typename") == "PullRequest" and src.get("merged"):
            return True          # a MERGED PR naming it, keyword or not
    return False


def verified(issue):
    c = issue["comments"]["nodes"]
    return bool(c and EVIDENCE.search(c[0]["body"] or ""))


def classify(issue):
    if issue["closedByPullRequestsReferences"]["totalCount"]:
        return "LINKED"
    if committed(issue):
        return "COMMITTED"
    if verified(issue):
        return "VERIFIED"
    return "ASSERTED"


def census_repo(owner, repo, since, listing=None):
    """Completed closures created on or after `since`, by class. Stops paging as
    soon as CREATED_AT order takes it past the window."""
    out = {"completed": 0, "not_planned": 0, "classes": {k: 0 for k in
           ("LINKED", "COMMITTED", "VERIFIED", "ASSERTED")}, "examples": {}}
    after = None
    while True:
        page = gh_graphql(owner, repo, after)
        for i in page["nodes"]:
            if i["createdAt"][:10] < since:
                return out
            if i["stateReason"] == "NOT_PLANNED":
                out["not_planned"] += 1
                continue
            out["completed"] += 1
            k = classify(i)
            out["classes"][k] += 1
            out["examples"].setdefault(k, f"{repo}#{i['number']}")
            if listing == k:
                print(f"  {repo}#{i['number']:<6} [{','.join(l['name'] for l in i['labels']['nodes'])}] {i['title'][:70]}")
        if not page["pageInfo"]["hasNextPage"]:
            return out
        after = page["pageInfo"]["endCursor"]


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--owner", default="hf7y-estate")
    ap.add_argument("--repo", action="append", help="one repo; repeatable. Default: every repo the owner has")
    ap.add_argument("--since", default=SINCE_DEFAULT, help=f"created on or after (default {SINCE_DEFAULT}, realisateur#791's window)")
    ap.add_argument("--json", action="store_true")
    ap.add_argument("--list", metavar="CLASS", help="also print every closure in one class, with its labels")
    a = ap.parse_args()

    repos = a.repo
    if not repos:
        p = subprocess.run(["gh", "repo", "list", a.owner, "--limit", "200", "--json", "name",
                            "--jq", ".[].name"], capture_output=True, text=True)
        if p.returncode != 0:
            sys.exit(f"healing-census: BLIND -- could not list {a.owner}'s repos: {p.stderr.strip()}")
        repos = p.stdout.split()

    rec = {"owner": a.owner, "since": a.since, "repos": {}, "blind": {},
           "totals": {"completed": 0, "not_planned": 0,
                      "classes": {k: 0 for k in ("LINKED", "COMMITTED", "VERIFIED", "ASSERTED")}}}
    for r in repos:
        try:
            got = census_repo(a.owner, r, a.since, a.list)
        except Exception as e:                      # a repo that could not be read is BLIND, not empty
            rec["blind"][r] = str(e)
            continue
        if not (got["completed"] or got["not_planned"]):
            continue
        rec["repos"][r] = got
        rec["totals"]["completed"] += got["completed"]
        rec["totals"]["not_planned"] += got["not_planned"]
        for k, v in got["classes"].items():
            rec["totals"]["classes"][k] += v

    if a.json:
        print(json.dumps(rec, indent=2, sort_keys=True))
        return 0

    t, n = rec["totals"], rec["totals"]["completed"]
    print(f"healing-census -- {a.owner}, issues created since {a.since}")
    print(f"  {n} completed closure(s), {t['not_planned']} not-planned, over {len(rec['repos'])} repo(s)")
    if not n:
        print("  nothing to grade.")
    for k in ("LINKED", "COMMITTED", "VERIFIED", "ASSERTED"):
        v = t["classes"][k]
        eg = next((d["examples"][k] for d in rec["repos"].values() if k in d["examples"]), "")
        print(f"  {k:<10} {v:>5}  {v*100//n if n else 0:>3}%   {eg}")
    if n:
        left = t["classes"]["LINKED"] + t["classes"]["COMMITTED"]
        print(f"  code the history can show for it: {left} ({left*100//n}%) -- "
              f"checkable at all: {left + t['classes']['VERIFIED']} "
              f"({(left + t['classes']['VERIFIED'])*100//n}%)")
    for r, why in sorted(rec["blind"].items()):
        print(f"  BLIND {r}: {why}")
    return 6 if rec["blind"] and not n else 0


if __name__ == "__main__":
    sys.exit(main())
