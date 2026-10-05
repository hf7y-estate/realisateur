#!/usr/bin/env bash
# decision-drift.test.sh -- witness for bin/decision-drift.sh (#1066).
#
# HERMETIC -- a fake `gh` answers `issue list` from one fixture file per
# repo (named by the --repo value it was called with); nothing here reaches
# the network.
set -uo pipefail
# shellcheck source=bin/tests/lib/harness.sh
. "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib/harness.sh"
harness_tmp
SCRIPT="$(cd "$(dirname "$0")/.." && pwd)/decision-drift.sh"
[ -x "$SCRIPT" ] || { echo "FAIL: $SCRIPT not executable"; exit 1; }

echo "decision-drift.test.sh"

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
export DECISION_DRIFT_OWNER=o

run() { bash "$SCRIPT" "$@"; }

STAMP='<!-- decision-by: zach -->'

section "A. one decision-by comment -- nothing to report"
cat > "$T/fix/o_r.json" <<EOF
[ { "number": 1, "title": "one ruling", "comments": [
    { "createdAt": "2026-08-10T00:00:00Z", "body": "settled it. $STAMP" }
] } ]
EOF
OUT="$(run o/r 2>&1)"; RC=$?
rc  "A1 exits 0" 0 "$RC"
has "A2 says clean" "$OUT" "clean -- no candidate found"

section "B. two decision-by comments on the SAME issue is a candidate"
cat > "$T/fix/o_r.json" <<EOF
[ { "number": 2, "title": "reversed call", "comments": [
    { "createdAt": "2026-08-28T00:00:00Z", "body": "first call. $STAMP" },
    { "createdAt": "2026-09-06T00:00:00Z", "body": "overturned. $STAMP" }
] } ]
EOF
OUT="$(run o/r 2>&1)"; RC=$?
rc  "B1 exits 1" 1 "$RC"
has "B2 names the issue" "$OUT" "o/r#2"
has "B3 reports the gap in days" "$OUT" "(9d)"
has "B4 reports the count" "$OUT" "2 rulings"

section "C. a comment without the marker does not count"
cat > "$T/fix/o_r.json" <<EOF
[ { "number": 3, "title": "no marker", "comments": [
    { "createdAt": "2026-08-10T00:00:00Z", "body": "Zach answered here, quoted verbatim, no marker." },
    { "createdAt": "2026-08-20T00:00:00Z", "body": "a second comment, also no marker." }
] } ]
EOF
OUT="$(run o/r 2>&1)"; RC=$?
rc  "C1 exits 0 -- unmarked comments are invisible to this predicate" 0 "$RC"

section "D. a ruling citing an issue whose own later ruling postdates it"
# A single-repo run cannot see a cross-repo citation; exercise --all instead,
# via lib/roster-set.sh's real SWEEP, picking two repo NAMES already in
# SWEEP_PROJECTS (crt, ecosim) -- the actual --all code path, not a
# reimplementation of it.
cat > "$T/fix/o_crt.json" <<EOF
[ { "number": 10, "title": "cites y", "comments": [
    { "createdAt": "2026-08-01T00:00:00Z",
      "body": "ruled from o/ecosim#5's state at the time. $STAMP" }
] } ]
EOF
cat > "$T/fix/o_ecosim.json" <<EOF
[ { "number": 5, "title": "ruled again later", "comments": [
    { "createdAt": "2026-07-01T00:00:00Z", "body": "first. $STAMP" },
    { "createdAt": "2026-08-15T00:00:00Z", "body": "changed. $STAMP" }
] } ]
EOF
OUT="$(run --all 2>&1)"; RC=$?
rc  "D1 exits 1" 1 "$RC"
has "D2 names the citing issue and comment date" "$OUT" "o/crt#10 ruled 2026-08-01T00:00:00Z"
has "D3 names what it cited" "$OUT" "citing o/ecosim#5"
has "D4 names the cited issue's own later ruling date" "$OUT" "2026-08-15T00:00:00Z"
rm -f "$T/fix/o_crt.json" "$T/fix/o_ecosim.json"

section "E. the mirror of D: a citation that is NOT stale raises nothing"
cat > "$T/fix/o_crt.json" <<EOF
[ { "number": 10, "title": "cites y", "comments": [
    { "createdAt": "2026-09-01T00:00:00Z",
      "body": "ruled from o/ecosim#5's state at the time. $STAMP" }
] } ]
EOF
cat > "$T/fix/o_ecosim.json" <<EOF
[ { "number": 5, "title": "ruled once", "comments": [
    { "createdAt": "2026-07-01T00:00:00Z", "body": "first. $STAMP" }
] } ]
EOF
OUT="$(run --all 2>&1)"; RC=$?
rc  "E1 exits 0 -- the citation postdates the thing it cites" 0 "$RC"
rm -f "$T/fix/o_crt.json" "$T/fix/o_ecosim.json"

section "F. self-citation is not a candidate"
cat > "$T/fix/o_r.json" <<EOF
[ { "number": 20, "title": "cites itself", "comments": [
    { "createdAt": "2026-08-01T00:00:00Z", "body": "see #20 above. $STAMP" }
] } ]
EOF
OUT="$(run o/r 2>&1)"; RC=$?
rc  "F1 exits 0" 0 "$RC"

section "G. a reference inside a fenced code block is a quotation, not a citation"
cat > "$T/fix/o_crt.json" <<EOF
[ { "number": 11, "title": "quotes an example", "comments": [
    { "createdAt": "2026-08-01T00:00:00Z",
      "body": "example output:\n\`\`\`\nFixes o/ecosim#5\n\`\`\`\n$STAMP" }
] } ]
EOF
cat > "$T/fix/o_ecosim.json" <<EOF
[ { "number": 5, "title": "ruled later", "comments": [
    { "createdAt": "2026-09-01T00:00:00Z", "body": "changed. $STAMP" }
] } ]
EOF
OUT="$(run --all 2>&1)"; RC=$?
rc  "G1 exits 0 -- the fenced citation is stripped before scanning" 0 "$RC"
rm -f "$T/fix/o_crt.json" "$T/fix/o_ecosim.json"

section "H. --since excludes a comment before the cutoff"
cat > "$T/fix/o_r.json" <<EOF
[ { "number": 30, "title": "old reversal", "comments": [
    { "createdAt": "2026-06-01T00:00:00Z", "body": "first. $STAMP" },
    { "createdAt": "2026-06-10T00:00:00Z", "body": "changed. $STAMP" }
] } ]
EOF
OUT="$(run o/r --since 2026-08-01 2>&1)"; RC=$?
rc  "H1 exits 0 -- both comments predate --since" 0 "$RC"
OUT="$(run o/r --since 2026-05-01 2>&1)"; RC=$?
rc  "H2 exits 1 once --since reaches back far enough" 1 "$RC"

section "I. machine-readable output"
cat > "$T/fix/o_r.json" <<EOF
[ { "number": 2, "title": "reversed call", "comments": [
    { "createdAt": "2026-08-28T00:00:00Z", "body": "first call. $STAMP" },
    { "createdAt": "2026-09-06T00:00:00Z", "body": "overturned. $STAMP" }
] } ]
EOF
OUT="$(run o/r --json 2>&1)"; RC=$?
rc  "I1 exits 1" 1 "$RC"
S="$(printf '%s\n' "$OUT" | jq -c 'select(.kind=="summary")')"
has "I2 summary carries the same_issue count" "$S" '"same_issue":1'
has "I3 summary carries the error count" "$S" '"errors":0'
R="$(printf '%s\n' "$OUT" | jq -c 'select(.kind=="same-issue")')"
has "I4 the row itself is typed" "$R" '"kind":"same-issue"'

section "J. SILENT ZERO: a gh failure exits 6, never 0"
cat > "$T/fix/o_r.json" <<EOF
[ { "number": 1, "title": "x", "comments": [] } ]
EOF
OUT="$(GH_FAIL='API rate limit exceeded' run o/r 2>&1)"; RC=$?
rc  "J1 exits 6 on a gh failure" 6 "$RC"
has "J2 says the count is untrustworthy" "$OUT" "NOT trustworthy"
OUT="$(GH_FAIL='Issues are disabled for this repo' run o/r 2>&1)"; RC=$?
rc  "J3 issues-disabled is soft, not an error" 0 "$RC"

section "K. the argument contract (cli-guard)"
bash "$SCRIPT" --not-a-real-flag >/dev/null 2>&1; rc "K1 unknown flag exits 2" 2 "$?"
bash "$SCRIPT" >/dev/null 2>&1;                   rc "K2 no argument exits 2" 2 "$?"
bash "$SCRIPT" --help >/dev/null 2>&1;            rc "K3 --help exits 0" 0 "$?"
bash "$SCRIPT" o/r --since nope >/dev/null 2>&1;  rc "K4 a non-date --since exits 2" 2 "$?"
has "K5 --help states the candidate exit code" "$(bash "$SCRIPT" --help 2>&1)" "1  one or more candidates found"

summary
