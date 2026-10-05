#!/usr/bin/env bash
#
# Contract test for bin/etiquette.sh: the `needs-human` label is a VIEW of
# what line 1 declares, and could-not-look is never clean.
#
# HERMETICITY: full. A fake `gh` RECORDS every `issue edit`, so --apply is
# graded on what it wrote, not what it printed.
set -uo pipefail
. "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib/harness.sh"
SCRIPT="$(cd "$(dirname "$0")/.." && pwd)/etiquette.sh"
[ -x "$SCRIPT" ] || { echo "FAIL: $SCRIPT not executable"; exit 1; }
harness_tmp

mkdir -p "$T/bin"
cat > "$T/bin/gh" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = "issue" ] && [ "$2" = "edit" ]; then
  # GH_EDIT_FAIL: the credential can READ the tracker and cannot LABEL it.
  [ -n "${GH_EDIT_FAIL:-}" ] && { echo "GraphQL: Resource not accessible by personal access token (addLabelsToLabelable)" >&2; exit 1; }
  printf '%s\n' "$*" >> "$EDITS"; exit 0
fi
if [ "$1" = "label" ] && [ "$2" = "create" ]; then
  printf '%s\n' "$*" >> "$EDITS"; exit 0
fi
if [ "$1" = "label" ] && [ "$2" = "list" ]; then
  [ -n "${GH_LABEL_FAIL:-}" ] && { echo "$GH_LABEL_FAIL" >&2; exit 1; }
  cat "${LABELS_FIXTURE:-/dev/null}"; exit 0
fi
# $SEEN records the sweep's reach; $GH_FAIL_REPO makes one tracker unreadable.
repo=''; prev=''
for a in "$@"; do [ "$prev" = "--repo" ] && { repo="$a"; break; }; prev="$a"; done
[ -n "${SEEN:-}" ] && printf '%s\n' "$repo" >> "$SEEN"
[ -n "${GH_FAIL_REPO:-}" ] && [ "$repo" = "$GH_FAIL_REPO" ] && { echo "HTTP 404" >&2; exit 1; }
if [ -n "${GH_FAIL:-}" ]; then echo "$GH_FAIL" >&2; exit 1; fi
# Bulk `gh issue list`: attach `comments` per issue from $ANSWERED_FIXTURE
# (`<number>` or `<number><TAB><createdAt>`, one per line), owner-authored.
jq -c --rawfile af "${ANSWERED_FIXTURE:-/dev/null}" '
  ( ($af | split("\n") | map(select(length > 0) | split("\t"))
     | map({(.[0]): (.[1] // "2026-08-19T00:00:00Z")}) | add) // {} ) as $m
  | map(. + {comments: (if $m[(.number|tostring)] then
        [{author: {login: "hf7y"}, body: "an answer", createdAt: $m[(.number|tostring)]}]
      else [] end)})
' "$FIXTURE"
EOF
chmod +x "$T/bin/gh"
export PATH="$T/bin:$PATH"

# A fixture grammar, so the suite grades the MECHANISM rather than the estate's
# current label set.
printf '# fixture grammar\nneeds-human\tB60205\tderived:decision\tOnly a human can move this.\ndeferred\tFBCA04\twritten:defere\tParked for an agent.\n' > "$T/grammar.tsv"
printf 'needs-human\tOnly a human can move this.\ndeferred\tParked for an agent.\n' > "$T/labels.txt"

run() { EDITS="$T/edits" FIXTURE="$T/f.json" LABELS_FIXTURE="$T/labels.txt" \
        ANSWERED_FIXTURE="${ANSWERED_FIXTURE:-/dev/null}" \
        ETIQUETTE_GRAMMAR="$T/grammar.tsv" bash "$SCRIPT" o/r "$@"; }
grammar_only() { ETIQUETTE_GRAMMAR="$T/grammar.tsv" bash "$SCRIPT" "$@"; }

echo "etiquette.test.sh"

section "A. the label is derived from line 1, both directions"
cat > "$T/f.json" <<'EOF'
[
 {"number":1,"title":"agrees, labelled","body":"DECISION: @zach -- pick one","labels":[{"name":"needs-human"}]},
 {"number":2,"title":"agrees, unlabelled","body":"NO-DECISION: nothing to weigh","labels":[]},
 {"number":3,"title":"declares but is not labelled","body":"DECISION: @zach -- pick one","labels":[]},
 {"number":4,"title":"labelled but declares no decision","body":"NO-DECISION: nothing to weigh","labels":[{"name":"needs-human"}]}
]
EOF
: > "$T/edits"; out="$(run 2>&1)"; code=$?
rc  "A1 findings exit 1" 1 "$code"
has "A2 an unlabelled DECISION: is MISSING"            "$out" "MISSING     #3"
has "A3 a labelled NO-DECISION: is STALE"              "$out" "STALE       #4"
hasnt "A4 an agreeing labelled issue is not a finding" "$out" "#1   declares"
hasnt "A5 an agreeing unlabelled issue is not a finding" "$out" "#2   declares"
has "A6 the agreeing pair is counted, not just silent" "$out" "2 issue(s) agree"
eq  "A7 a report writes NOTHING" "$(wc -l < "$T/edits")" "0"

section "A'. line 1 ALONE decides: a comment or label never clears a DECISION:"  # #1433
# #1373: a relayed owner comment read as a ruling took needs-human off a body
# that still asked. The label is a view of line 1; to clear it, edit line 1.
cat > "$T/f.json" <<'EOF2'
[
 {"number":5,"title":"owner commented, still labelled","body":"DECISION: @zach -- pick one","labels":[{"name":"needs-human"}]},
 {"number":6,"title":"owner commented, not labelled","body":"DECISION: @zach -- pick one","labels":[]},
 {"number":7,"title":"carries the answered label","body":"DECISION: @zach -- pick one","labels":[{"name":"needs-human"},{"name":"answered"}]},
 {"number":8,"title":"line 1 rewritten on ruling","body":"NO-DECISION: ruled 2026-10-01 -- use A","labels":[{"name":"needs-human"}]}
]
EOF2
printf '5\n6\n7\n8\n' > "$T/answered.txt"
: > "$T/edits"; out="$(ANSWERED_FIXTURE="$T/answered.txt" run --apply 2>&1)"
eq    "A'1 a DECISION: with an owner comment KEEPS needs-human"  "$(grep -c 'edit 5 ' "$T/edits")" "0"
has   "A'2 ...and one without the label GETS it, comment notwithstanding" "$(cat "$T/edits")" "issue edit 6 --repo o/r --add-label needs-human"
eq    "A'3 the \`answered\` label does not clear it either"     "$(grep -c 'edit 7 ' "$T/edits")" "0"
has   "A'4 only a NO-DECISION: line 1 takes it off"              "$(cat "$T/edits")" "issue edit 8 --repo o/r --remove-label needs-human"
eq    "A'5 exactly those two writes"                             "$(wc -l < "$T/edits" | tr -d ' ')" "2"
hasnt "A'6 no comment-scan row survives: ANSWERED"               "$out" "ANSWERED"
hasnt "A'7 ...UNCOUNTED"                                         "$out" "UNCOUNTED"
hasnt "A'8 ...or a per-issue BLIND"                              "$out" "BLIND"

# B reads the section-A fixture; put it back.
cat > "$T/f.json" <<'EOF'
[
 {"number":1,"title":"agrees, labelled","body":"DECISION: @zach -- pick one","labels":[{"name":"needs-human"}]},
 {"number":2,"title":"agrees, unlabelled","body":"NO-DECISION: nothing to weigh","labels":[]},
 {"number":3,"title":"declares but is not labelled","body":"DECISION: @zach -- pick one","labels":[]},
 {"number":4,"title":"labelled but declares no decision","body":"NO-DECISION: nothing to weigh","labels":[{"name":"needs-human"}]}
]
EOF

section "B. --apply writes the label the body implies"
: > "$T/edits"; run --apply >/dev/null 2>&1
has "B1 the missing label is ADDED"   "$(cat "$T/edits")" "--add-label needs-human"
has "B2 ...to the issue that declares" "$(cat "$T/edits")" "issue edit 3"
has "B3 the stale label is REMOVED"   "$(cat "$T/edits")" "--remove-label needs-human"
has "B4 ...from the issue that does not" "$(cat "$T/edits")" "issue edit 4"
eq  "B5 exactly two writes -- the agreeing pair is left alone" "$(wc -l < "$T/edits")" "2"

section "C. a body that declares nothing is UNDECLARED, never 'no decision'"
cat > "$T/f.json" <<'EOF'
[{"number":9,"title":"predates the convention","body":"Found while doing something else.","labels":[]}]
EOF
: > "$T/edits"; out="$(run --apply 2>&1)"; code=$?
rc  "C1 exit 1" 1 "$code"
has "C2 reported UNDECLARED"                     "$out" "UNDECLARED  #9"
eq  "C3 --apply writes NO label for it: the fix is line 1, not a label" "$(wc -l < "$T/edits")" "0"

section "D. the declaration must OPEN line 1"
cat > "$T/f.json" <<'EOF'
[{"number":11,"title":"quotes the convention later","body":"Some preamble.\n\nDECISION: @zach -- this is a quotation, not a declaration","labels":[]}]
EOF
out="$(run 2>&1)"
has "D1 a DECISION: below line 1 does not earn the label" "$out" "UNDECLARED  #11"

section "E. could-not-look is BLIND, never clean"
cat > "$T/f.json" <<'EOF'
[]
EOF
out="$(EDITS="$T/edits" FIXTURE="$T/f.json" LABELS_FIXTURE="$T/labels.txt" \
       ETIQUETTE_GRAMMAR="$T/grammar.tsv" GH_FAIL="HTTP 401" bash "$SCRIPT" o/r 2>&1)"; code=$?
rc  "E1 an unreadable issue list exits 6 (BLIND), not 0" 6 "$code"
has "E2 ...and says so rather than reporting nothing waiting" "$out" "not \"nothing needs a human\""

section "F. an empty tracker is clean, and is NOT the same as BLIND"
out="$(run 2>&1)"; code=$?
rc  "F1 no open issues exits 0" 0 "$code"
hasnt "F2 ...without claiming BLIND" "$out" "BLIND"

section "G. usage"
rc "G1 two repos is a usage error" 2 "$(grammar_only o/r o/s >/dev/null 2>&1; echo $?)"
rc "G2 an unknown flag is a usage error" 2 "$(grammar_only --nope >/dev/null 2>&1; echo $?)"

section "H. the grammar is READ, not compiled in"
# What "central" means mechanically: change the file, change the behaviour,
# with no edit here (#397).
out="$(grammar_only 2>&1)"
has "H1 with no repo it PRINTS the grammar"          "$out" "needs-human"
has "H2 ...including the SOURCE column, which says who may write each" "$out" "derived:decision"
has "H3 ...and names the one home it read"           "$out" "grammar.tsv"
eq  "H4 --path prints that same file, so a host can prove which one it obeys" \
    "$(grammar_only --path)" "$T/grammar.tsv"

# The load-bearing one: a label the compiled-in code never heard of.
printf 'invented-here\t00FF00\ttyped\tA label that exists only in this fixture.\n' >> "$T/grammar.tsv"
out="$(run 2>&1)"
has "H5 a label added to the FILE is demanded of the repo, with no code change" \
    "$out" "invented-here"
: > "$T/edits"; run --apply >/dev/null 2>&1
has "H6 ...and --apply provisions it from the file's own colour and meaning" \
    "$(cat "$T/edits")" "label create invented-here"
has "H7 ...with the colour the file gave it"  "$(cat "$T/edits")" "00FF00"

# And the derived label is read from the file too, not typed in the script.
sed -i 's/^needs-human\t/needs-a-person\t/' "$T/grammar.tsv"
sed -i 's/^needs-human\t/needs-a-person\t/' "$T/labels.txt"
cat > "$T/f.json" <<'EOF'
[{"number":1,"title":"declares","body":"DECISION: @zach -- pick one","labels":[]}]
EOF
: > "$T/edits"; run --apply >/dev/null 2>&1
has "H8 renaming the derived label in the FILE moves what --apply writes" \
    "$(cat "$T/edits")" "--add-label needs-a-person"
hasnt "H9 ...and the old name is not written from a hardcoded copy" \
    "$(cat "$T/edits")" "--add-label needs-human"

section "I. a grammar that did not load is BLIND, never an empty grammar"
out="$(ETIQUETTE_GRAMMAR="$T/nope.tsv" bash "$SCRIPT" o/r 2>&1)"; code=$?
rc  "I1 a missing grammar exits 6 (BLIND), not 0"  6 "$code"
has "I2 ...and says it could not read the RULES"   "$out" "not \"there are no rules\""
printf '# only comments\n' > "$T/empty.tsv"
rc  "I3 a grammar with no rows is BLIND too, not a vacuous pass" 6 \
    "$(ETIQUETTE_GRAMMAR="$T/empty.tsv" bash "$SCRIPT" o/r >/dev/null 2>&1; echo $?)"
rc  "I4 an unreadable LABEL list is BLIND, not 'no labels'" 6 \
    "$(EDITS="$T/edits" FIXTURE="$T/f.json" ETIQUETTE_GRAMMAR="$T/grammar.tsv" \
       GH_LABEL_FAIL="HTTP 403" bash "$SCRIPT" o/r >/dev/null 2>&1; echo $?)"

section "J. the grammar is a floor, not a whitelist"
printf 'needs-a-person\tOnly a human.\ndeferred\tParked.\ninvented-here\tfixture.\nsomebodys-own-label\tnot ours\n' > "$T/labels.txt"
: > "$T/edits"; out="$(run --apply 2>&1)"
hasnt "J1 a label absent from the grammar is never deleted" "$(cat "$T/edits")" "label delete"
hasnt "J2 ...and is not reported as a finding either"       "$out" "somebodys-own-label"

section "K. --all sweeps every rostered repo, not just the dispatching one"
printf '# fixture grammar\nneeds-human\tB60205\tderived:decision\tOnly a human can move this.\n' > "$T/grammar.tsv"
printf 'needs-human\tOnly a human can move this.\n' > "$T/labels.txt"
cat > "$T/f.json" <<'EOF'
[{"number":1,"title":"declares","body":"DECISION: @zach -- pick one","labels":[]}]
EOF
run_all() { EDITS="$T/edits" FIXTURE="$T/f.json" LABELS_FIXTURE="$T/labels.txt" \
            SEEN="$T/seen" ANSWERED_FIXTURE=/dev/null \
            ETIQUETTE_GRAMMAR="$T/grammar.tsv" bash "$SCRIPT" --all "$@"; }

rc "K1 --all and a named repo is a usage error, not a silent sweep of one" 2 \
   "$(run_all o/r >/dev/null 2>&1; echo $?)"

. "$(cd "$(dirname "$0")/.." && pwd)/lib/roster-set.sh"
: > "$T/edits"; : > "$T/seen"; run_all --apply >/dev/null 2>&1
want=''; for _p in "${SWEEP[@]}"; do want="$want$SWEEP_OWNER/$_p"$'\n'; done
eq "K2 --all grades exactly the repos lib/roster-set.sh names" \
   "$(sort -u < "$T/seen")" "$(printf '%s' "$want" | sort -u)"
has "K3 ...including one nothing ever dispatches to, which is the whole point" \
    "$(cat "$T/edits")" "--repo $SWEEP_OWNER/verbs --add-label needs-human"

rc "K4 one unreadable tracker is BLIND (6) for the whole sweep, never clean" 6 \
   "$(GH_FAIL_REPO="$SWEEP_OWNER/${SWEEP[0]}" run_all >/dev/null 2>&1; echo $?)"

echo
section "L. a write the credential REFUSES is BLIND, never a clean sweep"
cat > "$T/f.json" <<'EOF'
[
 {"number":20,"title":"declares a decision, unlabelled","body":"DECISION: @zach -- pick one","labels":[]}
]
EOF
: > "$T/edits"
out="$(GH_EDIT_FAIL=1 run --apply 2>&1)"; rc_refused=$?
rc    "L1 --apply exits 6 when a write is refused"           6 "$rc_refused"
has   "L2 ...and the refusal is a ROW, not a silence"        "$out" "REFUSED"
has   "L3 ...and it is named as BLIND"                       "$out" "label write(s) REFUSED"
hasnt "L4 ...and is NOT counted as reconciled"               "$out" "1 label(s) reconciled"
eq    "L5 ...and nothing was recorded as written"            "$(wc -l < "$T/edits" | tr -d " ")" "0"
out="$(run --apply 2>&1)"; rc_ok=$?
# 1, not 0: a finding --apply FIXED still exits 1, which is exactly why the
# workflow tolerates 1 and why a refused write had to become 6 instead.
rc    "L6 the same sweep with a working credential exits 1, on the finding"  1 "$rc_ok"
has   "L7 ...and reconciles the label"                       "$out" "1 label(s) reconciled"

section "M. a DECISION: past its own DEFAULT-AFTER window needs no human"  # #1410
cat > "$T/f.json" <<'EOF'
[
 {"number":1,"title":"lapsed","createdAt":"2026-09-08T00:00:00Z","body":"DECISION: @zach -- pick one\n\nDEFAULT-AFTER 7d: take the first","labels":[{"name":"needs-human"}]},
 {"number":2,"title":"still open","createdAt":"2026-10-01T00:00:00Z","body":"DECISION: @zach -- pick one\n\nDEFAULT-AFTER 14d: take the first","labels":[{"name":"needs-human"}]},
 {"number":3,"title":"no default","createdAt":"2026-08-01T00:00:00Z","body":"DECISION: @zach -- pick one\n\nDEFAULT-AFTER 0d: block -- irreversible, no default","labels":[{"name":"needs-human"}]}
]
EOF
: > "$T/edits"; out="$(ETIQUETTE_TODAY=2026-10-05 run --apply 2>&1)"
has   "M1 the lapsed one loses the label"        "$(cat "$T/edits")" "issue edit 1 --repo o/r --remove-label needs-human"
eq    "M2 and it is the only write"              "$(wc -l < "$T/edits")" "1"
has   "M3 an open window and a 0d both still agree" "$out" "2 issue(s) agree"

summary
