#!/usr/bin/env bash
# carry-drift.test.sh -- every file bin/lib/carries.tsv says `bashified`
# carries from `main` is still byte-identical to its source.
#
# HERMETIC. Reads this checkout's own git refs only -- no sudo, no read of
# any live host, and the one `git fetch` below cannot prompt or block on an
# ssh credential. `origin/bashified` must be resolvable; tests.yml fetches
# it before this suite runs, and a fetch is attempted here too so a local
# run (or a shallower CI checkout) is BLIND, not silently green.
#
# THE MAIN SIDE IS origin/main. It was HEAD until 2026-08-23; see the block
# above the REF_MAIN resolution below for what that cost and why it moved.
#

set -uo pipefail
. "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib/harness.sh"

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TABLE="$REPO/bin/lib/carries.tsv"
[ -f "$TABLE" ] || { echo "FAIL: $TABLE missing"; exit 1; }

echo "carry-drift.test.sh"

# origin/bashified FIRST, refreshed before read: a local `bashified` is
# whatever that clone last fetched, and preferring it reported drift against a
# branch nobody ships. The local one is a fallback, and says so when used.
# --depth=1 ONLY WHERE ALREADY SHALLOW: it shallows the WHOLE repo, so this
# suite truncated its own dev clone -- `git merge-base` then says "unrelated
# histories" and rebase dies. CI is depth-1 already; elsewhere, fetch whole.
depth=""
[ "$(git -C "$REPO" rev-parse --is-shallow-repository 2>/dev/null)" = true ] && depth=--depth=1

REF_BASH=""
GIT_TERMINAL_PROMPT=0 SSH_ASKPASS_REQUIRE=never GIT_ASKPASS=/bin/true \
  git -C "$REPO" fetch -q $depth origin bashified:refs/remotes/origin/bashified 2>/dev/null || true
if git -C "$REPO" rev-parse --verify -q "origin/bashified^{commit}" >/dev/null 2>&1; then
  REF_BASH="origin/bashified"
elif git -C "$REPO" rev-parse --verify -q "bashified^{commit}" >/dev/null 2>&1; then
  REF_BASH="bashified"
  echo "  note  origin/bashified unreadable; comparing against the LOCAL bashified branch"
fi
if [ -z "$REF_BASH" ]; then
  bad "no bashified ref is readable here -- drift was NOT checked (BLIND, not clean)"
  summary; exit $?
fi

# THE MAIN SIDE IS origin/main, NOT HEAD -- changed 2026-08-23, hf7y/realisateur#578.
#
# It was HEAD, on the reasoning that "a PR that edits a carried source without
# carrying it goes red before it merges". That is incompatible with how this
# estate actually carries, and bin/lib/carries.tsv records why: carrying BEFORE
# the merge is what put a #510 change onto bashified before that PR landed, 25
# minutes before #511 deleted its premise. The carry is a SECOND STEP, AFTER
# the merge -- so under the old rule every branch touching a carried source was
# red for doing the right thing.
#
# MEASURED, and it was not theoretical: `suites` is a REQUIRED check, so this
# suite wedged every such PR. On 2026-08-23 that was #565, #571 and #579 at
# once -- three PRs that could never merge, one of them not even ours.
#
# origin/main answers the question this guard was built for (#516): is the
# CARRY behind, or has bashified been hand-edited? A PR cannot fail that, and
# a missing carry still goes red the moment it merges.
# THE TABLE COMES FROM origin/main TOO, not the working tree. Reading it from
# the branch reintroduced the same wedge one line down: a PR that ADDS a row
# for a file main has never shipped (#571's shape) asks "is this carried yet?"
# about something not yet merged, and the honest answer -- not yet -- was a
# red required check. Found by checking #571's log instead of assuming the
# first fix covered it.
REF_MAIN=""
GIT_TERMINAL_PROMPT=0 SSH_ASKPASS_REQUIRE=never GIT_ASKPASS=/bin/true \
  git -C "$REPO" fetch -q $depth origin main:refs/remotes/origin/main 2>/dev/null || true
if git -C "$REPO" rev-parse --verify -q "origin/main^{commit}" >/dev/null 2>&1; then
  REF_MAIN="origin/main"
elif git -C "$REPO" rev-parse --verify -q "main^{commit}" >/dev/null 2>&1; then
  REF_MAIN="main"
  echo "  note  origin/main unreadable; comparing against the LOCAL main branch"
fi
if [ -z "$REF_MAIN" ]; then
  bad "no main ref is readable here -- drift was NOT checked (BLIND, not clean)"
  summary; exit $?
fi

n=0
while IFS=$'\t' read -r carried src; do
  case "$carried" in ''|'#'*) continue ;; esac
  n=$((n + 1))
  a="$(git -C "$REPO" show "$REF_BASH:$carried" 2>/dev/null)"
  if [ -z "$a" ] && ! git -C "$REPO" cat-file -e "$REF_BASH:$carried" 2>/dev/null; then
    bad "$carried is declared in carries.tsv but does not exist on $REF_BASH"
    continue
  fi
  b="$(git -C "$REPO" show "$REF_MAIN:$src" 2>/dev/null)"
  if [ -z "$b" ] && ! git -C "$REPO" cat-file -e "$REF_MAIN:$src" 2>/dev/null; then
    bad "$src (source of $carried) does not exist on $REF_MAIN"
    continue
  fi
  if [ "$a" = "$b" ]; then
    ok "$carried matches its source $src"
  else
    bad "$carried DRIFTED from $src -- $REF_BASH ships a different file than $REF_MAIN develops. The carry is owed, or bashified was hand-edited."
  fi
done < <(git -C "$REPO" show "$REF_MAIN:bin/lib/carries.tsv" 2>/dev/null \
           | grep -v '^#' | grep -v '^[[:space:]]*$')

if [ "$n" -gt 0 ]; then
  ok "checked $n carried file(s) from bin/lib/carries.tsv"
else
  bad "carries.tsv named zero carried files"
fi

summary
