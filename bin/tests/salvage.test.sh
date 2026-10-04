#!/usr/bin/env bash
# salvage.test.sh -- agent/salvage.sh pushes what a pass left unlanded, and
# nothing when it left nothing. Offline: a bare repo stands in for origin and a
# stub stands in for `gh`.
set -uo pipefail
REPO="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../.." && pwd)"
. "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib/harness.sh"
harness_tmp; export T
SALVAGE="$REPO/agent/salvage.sh"

mkdir -p "$T/bin"
cat > "$T/bin/gh" <<'STUB'
#!/usr/bin/env bash
case "$1 $2" in
  "pr list") cat "$T/merged-heads" 2>/dev/null; exit 0 ;;   # the shas merged PRs were merged from
esac
printf '%s\n' "$*" >> "$T/gh.calls"
STUB
chmod +x "$T/bin/gh"
export PATH="$T/bin:$PATH" GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t

git init -q --bare -b main "$T/origin.git"
git clone -q "$T/origin.git" "$T/seed" 2>/dev/null
( cd "$T/seed" && echo a > a && git add a && git commit -q -m seed && git push -q origin main )
# --depth 1 over file://, as run-agent.sh clones: single-branch, so a pushed
# branch gets no remote-tracking ref. A full clone hides that.
fresh() { rm -rf "$T/w" "$T/gh.calls" "$T/merged-heads"; git clone -q --depth 1 "file://$T/origin.git" "$T/w"; }
heads() { git -C "$T/origin.git" for-each-ref --format='%(refname:short)' refs/heads | tr '\n' ' '; }

section "A. a pass that left nothing pushes nothing"
fresh; before="$(heads)"
out="$(cd "$T/w" && echo report > REPORT.md && bash "$SALVAGE" S1 7 2>&1)"; rc "exits 0" 0 "$?"
eq "...no new branch, REPORT.md alone is not work" "$(heads)" "$before"
eq "...and says nothing" "$out" ""

section "B. uncommitted work on main is committed to a salvage branch and pushed"
fresh
out="$(cd "$T/w" && echo work > deliverable.json && echo report > REPORT.md && bash "$SALVAGE" S2 117 2>&1)"; rc "exits 0" 0 "$?"
has "...says where it went" "$out" "SALVAGED: pushed salvage/117-S2"
eq "...the file is on origin" "$(git -C "$T/origin.git" show salvage/117-S2:deliverable.json)" "work"
eq "...REPORT.md stayed out of the commit" "$(git -C "$T/origin.git" ls-tree --name-only salvage/117-S2 | grep -c REPORT.md)" "0"
eq "...main was not touched" "$(git -C "$T/origin.git" ls-tree --name-only main | tr '\n' ' ')" "a "
has "...and the issue is told the branch" "$(cat "$T/gh.calls")" "issue comment 117"

section "C. commits on the pass's own unpushed branch go up under that name"
fresh
out="$(cd "$T/w" && git checkout -q -b fix-thing && echo x > x && git add x && git commit -q -m fix && bash "$SALVAGE" S3 2>&1)"; rc "exits 0" 0 "$?"
has "...under the branch the pass chose" "$out" "SALVAGED: pushed fix-thing"
eq "...and the commit is there" "$(git -C "$T/origin.git" log --format=%s -1 fix-thing)" "fix"
eq "...with no issue named, nothing is commented" "$(cat "$T/gh.calls" 2>/dev/null)" ""

section "D. a branch the pass already pushed is left alone"
fresh
out="$(cd "$T/w" && git checkout -q -b done-thing && echo y > y && git add y && git commit -q -m landed && git push -q -u origin done-thing && bash "$SALVAGE" S4 9 2>&1)"; rc "exits 0" 0 "$?"
eq "...says nothing" "$out" ""
eq "...and the issue is told nothing" "$(cat "$T/gh.calls" 2>/dev/null)" ""

section "E. a clone the remote has moved past is landed, not lost"
fresh
( cd "$T/seed" && git pull -q origin main && echo b > b && git add b && git commit -q -m later && git push -q origin main )
before="$(heads)"
out="$(cd "$T/w" && bash "$SALVAGE" S5 42 2>&1)"; rc "exits 0" 0 "$?"
eq "...no branch is pushed for a commit main already holds" "$(heads)" "$before"
eq "...and says nothing" "$out" ""

section "F. a squash-merged branch is landed though nothing on the remote reaches it"
fresh; before="$(heads)"
out="$(cd "$T/w" && git checkout -q -b squashed && echo z > z && git add z && git commit -q -m work && git rev-parse HEAD > "$T/merged-heads" && bash "$SALVAGE" S6 150 2>&1)"; rc "exits 0" 0 "$?"
eq "...the deleted branch is not pushed back" "$(heads)" "$before"
eq "...and the issue is told nothing" "$(cat "$T/gh.calls" 2>/dev/null)" ""
rm -f "$T/merged-heads"
out="$(cd "$T/w" && bash "$SALVAGE" S7 150 2>&1)"
has "...but the same branch with no merged PR is salvaged" "$out" "SALVAGED: pushed squashed"

summary
