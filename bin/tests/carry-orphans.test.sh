#!/usr/bin/env bash
# carry-orphans.test.sh -- every commands/*.md file `bashified` carries has a
# row in bin/lib/carries.tsv naming it as a destination (#1120).
#
# carry.sh and carry-drift.test.sh only ever check the FORWARD direction: that
# a declared row is not stale. Removing a row un-declares a file and un-ships
# nothing -- carry.sh has no delete actuator (its own header says why: #511
# deleted 13 files when one was tried) -- so a file dropped from the table
# keeps installing into every account that adopts a bashified build.
# commands/bashify.md (retired by #367, months ago) and commands/cloture.md
# (de-carried by #1116 -- "it's not a verb, its personal") were both still on
# bashified with zero rows naming them when this was measured (#1120).
#
# QUARANTINED (bin/run-suites.quarantine, #1120): this suite is EXPECTED to
# find both and fail until a human removes them from bashified with a
# deliberate `git rm` -- deleting from a derived branch is refused to agents
# by the destructive-API guard, and carry.sh is built to never delete. A human
# fixes the finding; the gate stays off until they do, same lever #316 built
# for a suite that is correctly red and not an actuator's job to fix.
#
# SCOPED TO commands/ ONLY. bin/, man/, hooks/ and libexec/ carry files with
# more structure than a 1:1 row (bin/lib/retired-verbs.tsv, man pages, parked
# verbs like ausculte and decision-rot) that this suite has not audited --
# widening it blind would turn unrelated, unaudited drift into findings
# nobody asked for here.
#
# LIVE, same shape as carry-drift.test.sh and for the same reason: no fixture
# stands in for "what is actually on bashified today".

set -uo pipefail
. "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib/harness.sh"

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TABLE="$REPO/bin/lib/carries.tsv"
[ -f "$TABLE" ] || { echo "FAIL: $TABLE missing"; exit 1; }

echo "carry-orphans.test.sh"

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
  bad "no bashified ref is readable here -- orphans were NOT checked (BLIND, not clean)"
  summary; exit $?
fi

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
  bad "no main ref is readable here -- orphans were NOT checked (BLIND, not clean)"
  summary; exit $?
fi

declare -A CARRIED=()
n=0
while IFS=$'\t' read -r carried src; do
  case "$carried" in ''|'#'*) continue ;; esac
  n=$((n + 1))
  CARRIED["$carried"]=1
done < <(git -C "$REPO" show "$REF_MAIN:bin/lib/carries.tsv" 2>/dev/null \
           | grep -v '^#' | grep -v '^[[:space:]]*$')
if [ "$n" -eq 0 ]; then
  bad "carries.tsv named zero carried files"
  summary; exit $?
fi

m=0
while IFS= read -r f; do
  [ -n "$f" ] || continue
  m=$((m + 1))
  if [ -n "${CARRIED[$f]+set}" ]; then
    ok "$f has a carries.tsv row"
  else
    bad "$f rides $REF_BASH with no carries.tsv row -- un-ships nothing if a row named it and was removed, and nothing carries it off deliberately either"
  fi
done < <(git -C "$REPO" ls-tree -r --name-only "$REF_BASH" -- commands/ 2>/dev/null)

if [ "$m" -eq 0 ]; then
  bad "commands/ is empty or unreadable on $REF_BASH -- orphans were NOT checked"
fi

summary
