#!/usr/bin/env bash
# SUBJECT: agent/merge-carry.sh. Hermetic -- `gh` and `sudo` are stubs on PATH
# and AGENT_STATE is a fixture, so this suite merges nothing and cannot pass
# because some real PR happens to be in the right state.
set -uo pipefail
. "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib/harness.sh"
harness_tmp
REPO="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../.." && pwd)"
SUT="$REPO/agent/merge-carry.sh"

echo "merge-carry.test.sh"

mkdir -p "$T/bin" "$T/state"
printf 'not-a-real-token\n' > "$T/token"

# The stub answers `pr view` from $T/view/<n> and `pr merge` from $T/merge/<n>
# (file contents = exit code), and records every merge it was asked for.
# `api .../actions/permissions` answers from $T/actions-enabled, defaulting to
# "true" when absent -- same as every section before G3 expects, unstated.
# `api --method PUT .../pulls/<n>/update-branch` records <n> to
# $T/update-branch-calls, one line per call asked for.
cat > "$T/bin/gh" <<'STUB'
#!/usr/bin/env bash
n=""; for a in "$@"; do case "$a" in [0-9]*) n="$a"; break ;; esac; done
case "$1" in
  api)
    ep=""; for a in "$@"; do case "$a" in repos/*) ep="$a" ;; esac; done
    case "$ep" in
      */update-branch)
        pn="${ep#*pulls/}"; pn="${pn%/update-branch}"
        printf '%s\n' "$pn" >> "$T/update-branch-calls" ;;
      *) [ -f "$T/actions-enabled" ] && cat "$T/actions-enabled" || echo true ;;
    esac ;;
  *) case "$2" in
       list)  [ ! -f "$T/listfail" ] || exit 1; cat "$T/list" 2>/dev/null ;;
       view)
         [ -f "$T/view/$n" ] || exit 1
         v="$(cat "$T/view/$n")"
         # No real jq runs here -- the fixture is the already-decided state
         # string. A real jq filter never emits RED/PENDING once Actions is
         # off, so mimic that here for the one section that needs it.
         if [ -f "$T/actions-enabled" ] && [ "$(cat "$T/actions-enabled")" = "false" ]; then
           v="$(printf '%s' "$v" | sed -E 's/ (RED|PENDING)$//')"
         fi
         printf '%s\n' "$v" ;;
       merge) printf '%s\n' "$n" >> "$T/merged"; exit "$(cat "$T/merge/$n" 2>/dev/null || echo 0)" ;;
     esac ;;
esac
STUB
cat > "$T/bin/sudo" <<'STUB'
#!/usr/bin/env bash
shift; exec "$@"          # drop -n, run the cat
STUB
chmod +x "$T/bin/gh" "$T/bin/sudo"

run() {  # run(repo) -- with the stubs in front of the real gh
  rm -f "$T/merged"
  # shellcheck disable=SC2097,SC2098  # T="$T" passes the harness dir the stubs read; same value, child env
  PATH="$T/bin:$PATH" T="$T" AGENT_STATE="$T/state" GH_TOKEN_FILE="$T/token" \
    bash "$SUT" "$1" 2>&1
}
carry() { printf '%s\n' "$@" > "$T/state/${repo}.prs"; }
left()  { tr '\n' ' ' < "$T/state/${repo}.prs" | sed 's/ $//'; }
state() { mkdir -p "$T/view" "$T/merge"; printf '%s\n' "$2" > "$T/view/$1"; }
calls() { [ -f "$T/update-branch-calls" ] && grep -c "^$1\$" "$T/update-branch-calls" || echo 0; }

section "A. the argument contract"
out="$(PATH="$T/bin:$PATH" AGENT_STATE="$T/state" bash "$SUT" 2>&1)"
rc "no repo exits 1" 1 "$?"
has "...and says what it takes" "$out" "usage:"

section "B. nothing recorded is not a failure, and says nothing"
repo=quiet
out="$(run "$repo")"; rc "a missing carry file exits 0" 0 "$?"
eq "...and prints nothing at all" "$out" ""
: > "$T/state/${repo}.prs"
out="$(run "$repo")"; rc "an EMPTY carry file also exits 0" 0 "$?"
eq "...and still prints nothing" "$out" ""

section "C. a mergeable PR is merged and forgotten"
repo=happy; carry 11
state 11 "OPEN false MERGEABLE"
out="$(run "$repo")"; rc "exits 0" 0 "$?"
has "...says which one it merged" "$out" "MERGED   #11"
eq  "...asked gh to merge exactly it" "$(tr '\n' ' ' < "$T/merged" | sed 's/ $//')" "11"
eq  "...and the list is now empty" "$(left)" ""

section "D. every state that can still change is KEPT, not dropped"
for case in "red:OPEN false MERGEABLE RED" "pending:OPEN false MERGEABLE PENDING" "young:OPEN false MERGEABLE YOUNG" "draft:OPEN true MERGEABLE" "conflict:OPEN false CONFLICTING" \
            "uncomputed:OPEN false UNKNOWN"; do
  repo="${case%%:*}"; carry 22
  state 22 "${case#*:}"
  out="$(run "$repo")"
  has "${repo}: held, with the state named" "$out" "HELD     #22"
  eq  "${repo}: and kept for the next pass" "$(left)" "22"
  eq  "${repo}: and nothing was merged" "$(cat "$T/merged" 2>/dev/null)" ""
done

section "E. a PR that is already gone is dropped, not retried forever"
repo="done"; carry 33   # quoted: bare done reads as the loop keyword (SC1010)
state 33 "MERGED false UNKNOWN"
out="$(run "$repo")"; has "says it is already done" "$out" "DONE     #33"
eq "...and drops it" "$(left)" ""
repo=closed; carry 44
state 44 "CLOSED false UNKNOWN"
out="$(run "$repo")"; has "a CLOSED PR is also done" "$out" "DONE     #44"
eq "...and is dropped" "$(left)" ""

section "F. a refused merge stays on the list -- the whole point"
repo=refused; carry 55
state 55 "OPEN false MERGEABLE"; mkdir -p "$T/merge"; echo 1 > "$T/merge/55"
out="$(run "$repo")"
has "says the merge was refused" "$out" "FAILED   #55"
eq  "...and keeps it" "$(left)" "55"
rm -f "$T/merge/55"

section "G. a PR it cannot read is kept and left alone"
repo=blind; carry 66      # no $T/view/66, so `gh pr view` exits 1
out="$(run "$repo")"
has "says it could not be read" "$out" "UNREADABLE #66"
eq  "...and does not guess" "$(cat "$T/merged" 2>/dev/null)" ""
eq  "...and keeps it" "$(left)" "66"

section "G2. an open PR the App authored is adopted, listed or not"
repo=adopt; rm -f "$T/state/${repo}.prs"; state 77 "OPEN false MERGEABLE"; echo 77 > "$T/list"
out="$(run "$repo")"
has "merges a PR no pass wrote down" "$out" "MERGED   #77"
carry 77; out="$(run "$repo")"
eq  "...and one both listed and adopted is merged once" "$(grep -c 77 "$T/merged")" "1"
rm -f "$T/list"; touch "$T/listfail"; carry 77
out="$(run "$repo")"
has "a listing that fails still runs the list" "$out" "MERGED   #77"
rm -f "$T/listfail"

section "H. a mixed list: each one is decided on its own"
repo=mixed; carry 11 55 66 33
state 11 "OPEN false MERGEABLE"; state 33 "MERGED false UNKNOWN"
state 55 "OPEN false CONFLICTING"; rm -f "$T/view/66"
out="$(run "$repo")"; rc "exits 0" 0 "$?"
eq "merged only the mergeable one" "$(tr '\n' ' ' < "$T/merged" | sed 's/ $//')" "11"
eq "...and kept exactly the two unresolved" "$(left)" "55 66"
hasnt "...and did not claim to merge the conflicting one" "$out" "MERGED   #55"

section "I. Actions disabled: statusCheckRollup is ignored, not trusted"
repo=noactions; carry 11; echo false > "$T/actions-enabled"
state 11 "OPEN false MERGEABLE RED"   # would hold RED if Actions were on
out="$(run "$repo")"
has "a PR that would read RED is merged instead" "$out" "MERGED   #11"
has "...and says why" "$out" "Actions disabled"
eq  "...and forgets it" "$(left)" ""

repo=noactionsheld; carry 22; echo false > "$T/actions-enabled"
state 22 "OPEN false CONFLICTING RED"   # held, but for CONFLICTING, not the check
out="$(run "$repo")"
has "held only for the non-check reason" "$out" "HELD     #22"
has "...and says Actions is off, not why it reads RED" "$out" "Actions disabled"
eq  "...and keeps it" "$(left)" "22"

repo=actionson; carry 33; echo true > "$T/actions-enabled"
state 33 "OPEN false MERGEABLE RED"
out="$(run "$repo")"
has "the same RED state still holds when Actions is on" "$out" "HELD     #33"
hasnt "...with no claim that Actions is disabled" "$out" "Actions disabled"
eq  "...and keeps it" "$(left)" "33"
rm -f "$T/actions-enabled"

section "J. RED or CONFLICTING gets one update-branch call, not every pass"
rm -f "$T/update-branch-calls"
repo=redonce; carry 22
state 22 "OPEN false MERGEABLE RED"
out="$(run "$repo")"
has "held for RED" "$out" "HELD     #22"
eq  "...and update-branch was called once" "$(calls 22)" "1"
out="$(run "$repo")"
has "still held, same RED state" "$out" "HELD     #22"
eq  "...and a second consecutive HELD pass triggers none" "$(calls 22)" "1"
rm -f "$T/update-branch-calls"

repo=conflictonce; carry 33
state 33 "OPEN false CONFLICTING"
out="$(run "$repo")"
has "held for CONFLICTING" "$out" "HELD     #33"
eq  "...and update-branch was called once" "$(calls 33)" "1"
out="$(run "$repo")"
eq  "...and a second consecutive HELD pass triggers none" "$(calls 33)" "1"
rm -f "$T/update-branch-calls"

section "K. other HELD reasons never call update-branch"
for case in "pending:OPEN false MERGEABLE PENDING" "young:OPEN false MERGEABLE YOUNG" "draft:OPEN true MERGEABLE" "uncomputed:OPEN false UNKNOWN"; do
  repo="up-${case%%:*}"; carry 44
  state 44 "${case#*:}"
  out="$(run "$repo")"
  has "${repo}: held, no update-branch call" "$out" "HELD     #44"
  eq  "${repo}: and none was made" "$(calls 44)" "0"
  rm -f "$T/update-branch-calls"
done

summary
