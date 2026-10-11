#!/usr/bin/env bash
# decision-sat.test.sh -- witness for bin/decision-sat.sh (#1624).
#
# HERMETIC -- a fake `gh` answers `issue list` from one fixture file per
# repo (named by the --repo value it was called with); nothing here reaches
# the network. DECISION_SAT_NOW pins "today" so the day-count is exact.
set -uo pipefail
# shellcheck source=bin/tests/lib/harness.sh
. "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib/harness.sh"
harness_tmp
SCRIPT="$(cd "$(dirname "$0")/.." && pwd)/decision-sat.sh"
[ -x "$SCRIPT" ] || { echo "FAIL: $SCRIPT not executable"; exit 1; }

echo "decision-sat.test.sh"

mkdir -p "$T/fix"
cat > "$T/gh" <<'STUB'
#!/usr/bin/env bash
if [ -n "${GH_FAIL:-}" ]; then echo "$GH_FAIL" >&2; exit 1; fi
repo=''
prev=''
for a in "$@"; do
  [ "$prev" = --repo ] && repo="$a"
  prev="$a"
done
safe="$(printf '%s' "$repo" | tr '/' '_')"
f="$FIXDIR/$safe.json"
if [ -f "$f" ]; then cat "$f"; else echo '[]'; fi
STUB
chmod +x "$T/gh"
export PATH="$T:$PATH"
export FIXDIR="$T/fix"
export DECISION_SAT_OWNER=o
export DECISION_SAT_NOW='2026-10-11T00:00:00Z'

run() { bash "$SCRIPT" "$@"; }

STAMP='<!-- decision-by: zach -->'

section "A. ruled, no blocker, sat past the threshold -- a candidate"
cat > "$T/fix/o_r.json" <<EOF
[ { "number": 1, "title": "ruled and forgotten", "comments": [
    { "createdAt": "2026-10-01T00:00:00Z", "body": "settled it. $STAMP" }
], "blockedBy": { "nodes": [], "totalCount": 0 } } ]
EOF
OUT="$(run o/r 2>&1)"; RC=$?
rc  "A1 exits 1" 1 "$RC"
has "A2 names the issue" "$OUT" "o/r#1"
has "A3 reports the day count" "$OUT" "(10d)"

section "B. ruled, but sat fewer than the threshold -- clean"
cat > "$T/fix/o_r.json" <<EOF
[ { "number": 2, "title": "ruled yesterday", "comments": [
    { "createdAt": "2026-10-10T00:00:00Z", "body": "settled it. $STAMP" }
], "blockedBy": { "nodes": [], "totalCount": 0 } } ]
EOF
OUT="$(run o/r 2>&1)"; RC=$?
rc  "B1 exits 0" 0 "$RC"
has "B2 says clean" "$OUT" "clean -- no candidate found"

section "C. ruled, past the threshold, but an OPEN blocker -- not sitting, it's waiting"
cat > "$T/fix/o_r.json" <<EOF
[ { "number": 3, "title": "ruled but blocked", "comments": [
    { "createdAt": "2026-10-01T00:00:00Z", "body": "settled it. $STAMP" }
], "blockedBy": { "nodes": [ { "number": 99, "state": "OPEN" } ], "totalCount": 1 } } ]
EOF
OUT="$(run o/r 2>&1)"; RC=$?
rc  "C1 exits 0 -- an open blocker takes it out of scope" 0 "$RC"

section "D. ruled, past the threshold, but the only blocker is CLOSED -- a candidate"
cat > "$T/fix/o_r.json" <<EOF
[ { "number": 4, "title": "ruled, blocker long closed", "comments": [
    { "createdAt": "2026-10-01T00:00:00Z", "body": "settled it. $STAMP" }
], "blockedBy": { "nodes": [ { "number": 99, "state": "CLOSED" } ], "totalCount": 1 } } ]
EOF
OUT="$(run o/r 2>&1)"; RC=$?
rc  "D1 exits 1 -- a closed blocker is not a blocker" 1 "$RC"
has "D2 names the issue" "$OUT" "o/r#4"

section "E. no decision-by comment at all -- not ruled, not a candidate"
cat > "$T/fix/o_r.json" <<EOF
[ { "number": 5, "title": "never ruled", "comments": [
    { "createdAt": "2026-09-01T00:00:00Z", "body": "Zach answered here, quoted verbatim, no marker." }
], "blockedBy": { "nodes": [], "totalCount": 0 } } ]
EOF
OUT="$(run o/r 2>&1)"; RC=$?
rc  "E1 exits 0 -- an unmarked comment is invisible to this predicate" 0 "$RC"

section "F. two decision-by comments -- measured from the LATEST, not the first"
cat > "$T/fix/o_r.json" <<EOF
[ { "number": 6, "title": "reversed call", "comments": [
    { "createdAt": "2026-09-01T00:00:00Z", "body": "first call. $STAMP" },
    { "createdAt": "2026-10-09T00:00:00Z", "body": "overturned. $STAMP" }
], "blockedBy": { "nodes": [], "totalCount": 0 } } ]
EOF
OUT="$(run o/r 2>&1)"; RC=$?
rc  "F1 exits 0 -- only 2 days since the latest ruling, below the default threshold" 0 "$RC"

section "G. --days narrows or widens the threshold"
cat > "$T/fix/o_r.json" <<EOF
[ { "number": 7, "title": "ruled 2 days ago", "comments": [
    { "createdAt": "2026-10-09T00:00:00Z", "body": "settled it. $STAMP" }
], "blockedBy": { "nodes": [], "totalCount": 0 } } ]
EOF
OUT="$(run o/r --days 1 2>&1)"; RC=$?
rc  "G1 --days 1 catches a 2-day-old ruling" 1 "$RC"
OUT="$(run o/r --days 30 2>&1)"; RC=$?
rc  "G2 --days 30 does not" 0 "$RC"

section "H. --all sweeps every repo in SWEEP, and --json emits NDJSON plus a summary"
cat > "$T/fix/o_crt.json" <<EOF
[ { "number": 40, "title": "ruled, sitting", "comments": [
    { "createdAt": "2026-10-01T00:00:00Z", "body": "settled it. $STAMP" }
], "blockedBy": { "nodes": [], "totalCount": 0 } } ]
EOF
OUT="$(run --all --json 2>&1)"; RC=$?
rc  "H1 exits 1" 1 "$RC"
has "H2 names the swept repo's finding" "$OUT" '"repo":"o/crt"'
has "H3 names the number" "$OUT" '"number":40'
has "H4 emits a summary record" "$OUT" '"kind":"summary"'
rm -f "$T/fix/o_crt.json"

section "I. an unreadable repo is BLIND, not a silent clean"
cat > "$T/fix/o_r.json" <<EOF
[]
EOF
OUT="$(GH_FAIL='rate limited' run o/dark 2>&1)"; RC=$?
rc  "I1 exits 6" 6 "$RC"
has "I2 says the count is not trustworthy" "$OUT" "NOT trustworthy"

section "J. the argument contract"
OUT="$(run --nope 2>&1)"; RC=$?
rc  "J1 an unknown flag is a usage error" 2 "$RC"
OUT="$(run 2>&1)"; RC=$?
rc  "J2 no argument is a usage error" 2 "$RC"
OUT="$(run o/r --days nope 2>&1)"; RC=$?
rc  "J3 --days must be a number" 2 "$RC"

summary
exit $?
