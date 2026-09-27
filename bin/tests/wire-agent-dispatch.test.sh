#!/usr/bin/env bash
# SUBJECT: bin/wire-agent-dispatch.sh. Hermetic -- AGENT_DIR is a fixture, so it
# cannot pass because dexter's /srv/agent happens to be wired already.
set -uo pipefail
. "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib/harness.sh"
harness_tmp
REPO="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../.." && pwd)"
WIRE="$REPO/bin/wire-agent-dispatch.sh"
# Read the list OUT OF THE VERB, so adding a dispatch file cannot leave the test
# asserting a number the verb no longer wires. It said "4" on 2026-09-26 and
# merge-carry.sh made that wrong in two places at once.
FILES="$(sed -n 's/^FILES=(\(.*\))$/\1/p' "$WIRE")"
NFILES="$(printf '%s\n' $FILES | wc -l)"
[ "$NFILES" -ge 4 ] || { echo "cannot read FILES out of $WIRE"; exit 2; }

echo "wire-agent-dispatch.test.sh"

fresh_copies() {  # the state dexter was in on 2026-09-26: hand-placed copies
  rm -rf "$T/srv"; mkdir -p "$T/srv"
  for f in $FILES; do cp -p "$REPO/agent/$f" "$T/srv/$f"; done
}
wire() { AGENT_DIR="$T/srv" bash "$WIRE" "$@" 2>&1; }

section "A. the argument contract"
out="$(AGENT_DIR="$T" bash "$WIRE" --nonsense 2>&1)"; rc "an unknown flag exits 2" 2 "$?"
has "...and says what it takes" "$out" "usage:"

section "B. --check changes nothing, and says the copies are unrefreshed"
fresh_copies
out="$(wire --check)"; r=$?
rc "identical copies are a GAP (4), not a pass" 4 "$r"
has "...and it says nothing refreshes them" "$out" "refreshed by nothing"
has "...and hands over the next command" "$out" "--apply"
eq "...and nothing was linked" "$(find "$T/srv" -type l | wc -l)" "0"
eq "...and no backup directory was made" "$(ls -d "$T/srv/.pre-wire" 2>/dev/null | wc -l)" "0"

section "C. --apply links every dispatch file and keeps what it replaced"
out="$(wire --apply)"; rc "--apply exits 0" 0 "$?"
eq "one symlink per dispatch file" "$(find "$T/srv" -maxdepth 1 -type l | wc -l)" "$NFILES"
eq "each points into the clone" \
   "$(readlink -f "$T/srv/run-agent.sh")" "$(readlink -f "$REPO/agent/run-agent.sh")"
eq "the replaced copies are kept" "$(ls "$T/srv/.pre-wire" | wc -l)" "$NFILES"

section "D. it is idempotent -- a second run is a no-op that reports OK"
out="$(wire --check)"; rc "an already-wired host is 0" 0 "$?"
has "...and says there is nothing to do" "$out" "nothing to do."
before="$(ls "$T/srv/.pre-wire" | wc -l)"
out="$(wire --apply)"; rc "--apply on a wired host is 0" 0 "$?"
eq "...and takes no second backup" "$(ls "$T/srv/.pre-wire" | wc -l)" "$before"

section "E. BEHIND is not DRIFT -- the normal state after a merge is linkable"
# A real earlier version of this same path, taken out of the clone's history.
# That is what /srv/agent holds the morning after any agent/ PR merges, and
# refusing it would make this verb useless exactly when it is needed.
fresh_copies
prev="$(git -C "$REPO" log --format=%H -- agent/run-agent.sh | sed -n 2p)"
if [ -n "$prev" ]; then
  git -C "$REPO" show "$prev:agent/run-agent.sh" > "$T/srv/run-agent.sh"
  out="$(wire --check)"
  has "an earlier version of the path reads as behind, not drifted" "$out" "an EARLIER version of this same file"
  eq  "...and --state says so in one word" \
      "$(AGENT_DIR="$T/srv" bash "$WIRE" --state | awk -F'\t' '$1=="run-agent.sh"{print $2}')" "behind"
  out="$(wire --apply)"; rc "...and --apply links it" 0 "$?"
  eq  "...and the old bytes are kept" "$(ls "$T/srv/.pre-wire" | wc -l)" "$NFILES"
else
  ok "SKIPPED: agent/run-agent.sh has only one version in this clone"
fi

section "E2. a backup is claimed only when one was taken"
# It said "was backed up to .pre-wire/<f>.<stamp>" unconditionally, so linking a
# file that was ABSENT on the host named a backup that does not exist.
fresh_copies
one="$(printf '%s\n' $FILES | sed -n 1p)"
rm -f "$T/srv/$one"
out="$(wire --apply)"; rc "an absent file still links" 0 "$?"
has "...and says it was absent" "$out" "$one: absent on the host"
case "$out" in
  *"$one -> the clone (was backed up"*) bad "...and does not claim a backup it did not take" ;;
  *) ok "...and does not claim a backup it did not take" ;;
esac
eq "...and no backup file was left for it" "$(ls "$T/srv/.pre-wire/$one".* 2>/dev/null | wc -l)" "0"
has "...while a file it DID replace still says where the bytes went" "$out" "was backed up to .pre-wire/"

section "F. bytes that were NEVER this path's content are refused, never adopted"
fresh_copies
printf 'a-hand-edit-nobody-recorded\n' > "$T/srv/repos"
out="$(wire --apply)"; rc "drift exits 5" 5 "$?"
has "...and says the host was edited" "$out" "NEVER this path's content"
eq  "...and --state calls it drifted" \
    "$(AGENT_DIR="$T/srv" bash "$WIRE" --state | awk -F'\t' '$1=="repos"{print $2}')" "drifted"
has "...and hands over the diff command" "$out" "diff '$T/srv/repos'"
eq "...and left the drifted file exactly as it was" "$(cat "$T/srv/repos")" "a-hand-edit-nobody-recorded"
eq "...while still wiring the others that agreed" "$(find "$T/srv" -maxdepth 1 -type l | wc -l)" "$((NFILES - 1))"

section "G. a nightly holding the lock stops it -- run-agent.sh is in use"
fresh_copies
: > "$T/srv/.nightly.lock"
out="$(flock "$T/srv/.nightly.lock" -c "AGENT_DIR='$T/srv' bash '$WIRE' --apply 2>&1")"; rc "a held lock exits 1" 1 "$?"
has "...and says a pass is dispatching" "$out" "it is dispatching right now"
eq "...and nothing was touched" "$(find "$T/srv" -maxdepth 1 -type l | wc -l)" "0"

section "H. a wrong host and a wrong checkout are usage errors, not silent passes"
out="$(AGENT_DIR="$T/no-such-dir" bash "$WIRE" --check 2>&1)"; rc "no /srv/agent exits 2" 2 "$?"
has "...and says this host does not dispatch" "$out" "does not dispatch"

summary
