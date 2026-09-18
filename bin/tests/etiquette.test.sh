#!/usr/bin/env bash
#
# Contract test for bin/etiquette.sh: does a repo carry the labels the
# grammar declares, and could-not-look is never clean.
#
# hf7y/scheduler#318 deleted the OTHER half this suite used to cover:
# reconciling a `needs-human` label against the DECISION:/NO-DECISION:
# line-1 sentence in every open issue's body. GitHub's own `assignees` field
# is that signal now (tempo.sh reads it directly); etiquette no longer
# derives or writes anything from a body, so there is no per-issue behaviour
# left here to pin -- only whether a repo carries what the grammar declares.
#
# HERMETICITY: full. A fake `gh` RECORDS every `label create`, so --apply is
# graded on what it wrote, not what it printed.
set -uo pipefail
. "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib/harness.sh"
SCRIPT="$(cd "$(dirname "$0")/.." && pwd)/etiquette.sh"
[ -x "$SCRIPT" ] || { echo "FAIL: $SCRIPT not executable"; exit 1; }
harness_tmp

mkdir -p "$T/bin"
cat > "$T/bin/gh" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = "label" ] && [ "$2" = "create" ]; then
  printf '%s\n' "$*" >> "$EDITS"; exit 0
fi
if [ "$1" = "label" ] && [ "$2" = "list" ]; then
  repo=''; prev=''
  for a in "$@"; do [ "$prev" = "--repo" ] && { repo="$a"; break; }; prev="$a"; done
  [ -n "${SEEN:-}" ] && printf '%s\n' "$repo" >> "$SEEN"
  [ -n "${GH_FAIL_REPO:-}" ] && [ "$repo" = "$GH_FAIL_REPO" ] && { echo "HTTP 404" >&2; exit 1; }
  [ -n "${GH_LABEL_FAIL:-}" ] && { echo "$GH_LABEL_FAIL" >&2; exit 1; }
  cat "${LABELS_FIXTURE:-/dev/null}"; exit 0
fi
exit 0
EOF
chmod +x "$T/bin/gh"
export PATH="$T/bin:$PATH"

# A fixture grammar, so the suite grades the MECHANISM rather than the estate's
# current label set.
printf '# fixture grammar\nneeds-human\tB60205\tderived:decision\tOnly a human can move this.\ndeferred\tFBCA04\twritten:defere\tParked for an agent.\n' > "$T/grammar.tsv"
printf 'needs-human\tOnly a human can move this.\ndeferred\tParked for an agent.\n' > "$T/labels.txt"

run() { EDITS="$T/edits" LABELS_FIXTURE="$T/labels.txt" \
        ETIQUETTE_GRAMMAR="$T/grammar.tsv" bash "$SCRIPT" o/r "$@"; }
grammar_only() { ETIQUETTE_GRAMMAR="$T/grammar.tsv" bash "$SCRIPT" "$@"; }

echo "etiquette.test.sh"

section "A. does the repo carry the declared labels?"
: > "$T/edits"; out="$(run 2>&1)"; code=$?
rc  "A1 every declared label present exits 0" 0 "$code"
has "A2 ...and says so" "$out" "every declared label exists here"
eq  "A3 a clean report writes NOTHING" "$(wc -l < "$T/edits")" "0"

printf 'deferred\tParked for an agent.\n' > "$T/labels.txt"   # needs-human missing
: > "$T/edits"; out="$(run 2>&1)"; code=$?
rc  "A4 a missing declared label is a finding -- exit 1" 1 "$code"
has "A5 ...and it says MISSING" "$out" "MISSING"
has "A6 ...naming the label" "$out" "needs-human"
eq  "A7 a report with no --apply writes NOTHING" "$(wc -l < "$T/edits")" "0"

: > "$T/edits"; run --apply >/dev/null 2>&1
has "A8 --apply creates the missing label" "$(cat "$T/edits")" "label create needs-human"
has "A9 ...with the grammar's own colour" "$(cat "$T/edits")" "B60205"

printf 'needs-human\tOnly a human can move this.\ndeferred\tParked for an agent.\n' > "$T/labels.txt"

section "B. usage"
rc "B1 two repos is a usage error" 2 "$(grammar_only o/r o/s >/dev/null 2>&1; echo $?)"
rc "B2 an unknown flag is a usage error" 2 "$(grammar_only --nope >/dev/null 2>&1; echo $?)"

section "C. the grammar is READ, not compiled in"
# What "central" means mechanically: change the file, change the behaviour,
# with no edit here (#397).
out="$(grammar_only 2>&1)"
has "C1 with no repo it PRINTS the grammar"          "$out" "needs-human"
has "C2 ...including the SOURCE column"              "$out" "derived:decision"
has "C3 ...and names the one home it read"           "$out" "grammar.tsv"
eq  "C4 --path prints that same file, so a host can prove which one it obeys" \
    "$(grammar_only --path)" "$T/grammar.tsv"
hasnt "C5 the footer no longer claims etiquette derives a label from a body" \
    "$out" "is written by --apply from line 1"

# The load-bearing one: a label the compiled-in code never heard of.
printf 'invented-here\t00FF00\ttyped\tA label that exists only in this fixture.\n' >> "$T/grammar.tsv"
out="$(run 2>&1)"
has "C6 a label added to the FILE is demanded of the repo, with no code change" \
    "$out" "invented-here"
: > "$T/edits"; run --apply >/dev/null 2>&1
has "C7 ...and --apply provisions it from the file's own colour and meaning" \
    "$(cat "$T/edits")" "label create invented-here"
has "C8 ...with the colour the file gave it"  "$(cat "$T/edits")" "00FF00"

section "D. a grammar that did not load is BLIND, never an empty grammar"
out="$(ETIQUETTE_GRAMMAR="$T/nope.tsv" bash "$SCRIPT" o/r 2>&1)"; code=$?
rc  "D1 a missing grammar exits 6 (BLIND), not 0"  6 "$code"
has "D2 ...and says it could not read the RULES"   "$out" "not \"there are no rules\""
printf '# only comments\n' > "$T/empty.tsv"
rc  "D3 a grammar with no rows is BLIND too, not a vacuous pass" 6 \
    "$(ETIQUETTE_GRAMMAR="$T/empty.tsv" bash "$SCRIPT" o/r >/dev/null 2>&1; echo $?)"
rc  "D4 an unreadable LABEL list is BLIND, not 'no labels'" 6 \
    "$(EDITS="$T/edits" ETIQUETTE_GRAMMAR="$T/grammar.tsv" \
       GH_LABEL_FAIL="HTTP 403" bash "$SCRIPT" o/r >/dev/null 2>&1; echo $?)"

section "E. the grammar is a floor, not a whitelist"
printf 'needs-human\tOnly a human.\ndeferred\tParked.\ninvented-here\tfixture.\nsomebodys-own-label\tnot ours\n' > "$T/labels.txt"
: > "$T/edits"; out="$(run --apply 2>&1)"
hasnt "E1 a label absent from the grammar is never deleted" "$(cat "$T/edits")" "label delete"
hasnt "E2 ...and is not reported as a finding either"       "$out" "somebodys-own-label"

section "F. --all sweeps every rostered repo, not just the dispatching one"
printf '# fixture grammar\nneeds-human\tB60205\tderived:decision\tOnly a human can move this.\n' > "$T/grammar.tsv"
printf 'deferred\tParked.\n' > "$T/labels.txt"   # needs-human missing everywhere -- proves reach
run_all() { EDITS="$T/edits" LABELS_FIXTURE="$T/labels.txt" \
            SEEN="$T/seen" \
            ETIQUETTE_GRAMMAR="$T/grammar.tsv" bash "$SCRIPT" --all "$@"; }

rc "F1 --all and a named repo is a usage error, not a silent sweep of one" 2 \
   "$(run_all o/r >/dev/null 2>&1; echo $?)"

. "$(cd "$(dirname "$0")/.." && pwd)/lib/roster-set.sh"
: > "$T/edits"; : > "$T/seen"; run_all --apply >/dev/null 2>&1
want=''; for _p in "${SWEEP[@]}"; do want="$want$SWEEP_OWNER/$_p"$'\n'; done
eq "F2 --all grades exactly the repos lib/roster-set.sh names" \
   "$(sort -u < "$T/seen")" "$(printf '%s' "$want" | sort -u)"
has "F3 ...including one nothing ever dispatches to, which is the whole point" \
    "$(cat "$T/edits")" "label create needs-human --repo $SWEEP_OWNER/verbs"

rc "F4 one unreadable label list is BLIND (6) for the whole sweep, never clean" 6 \
   "$(GH_FAIL_REPO="$SWEEP_OWNER/${SWEEP[0]}" run_all >/dev/null 2>&1; echo $?)"

JQF="$(cd "$(dirname "$0")/.." && pwd)/lib/answered.jq"
[ -r "$JQF" ] || { echo "FAIL: $JQF not readable"; exit 1; }

ab() { jq -r --arg owner zach --arg era 2026-08-14 \
         "$(cat "$JQF")"'. | answered_by // "null"'; }

section "ANSWERED-BY is read from the body AND the comments"
# bin/lib/answered.jq is shared with decision-rot.sh and is untouched by
# #318 (ANSWERED-BY is a different concern per the issue text) -- these
# assertions exercise it directly, independent of etiquette's own logic.

got="$(printf '%s' '{"body":"DECISION: @zach\nANSWERED-BY hf7y/wtul#34","comments":[]}' | ab)"
[ "$got" = "hf7y/wtul#34" ] \
  && ok "A: a pointer in the body is found" \
  || bad "A: a pointer in the body is found" "got: $got"

got="$(printf '%s' '{"body":"DECISION: @zach","comments":[
  {"createdAt":"2026-08-29T10:00:00Z","body":"ANSWERED-BY hf7y/senechal#439"}]}' | ab)"
[ "$got" = "hf7y/senechal#439" ] \
  && ok "B: a pointer in a COMMENT is found (senechal#527's case)" \
  || bad "B: a pointer in a COMMENT is found" "got: $got -- body-only again"

got="$(printf '%s' '{"body":"DECISION: @zach\nANSWERED-BY hf7y/wtul#34","comments":[
  {"createdAt":"2026-08-30T10:00:00Z","body":"ANSWERED-BY hf7y/senechal#439"},
  {"createdAt":"2026-08-29T10:00:00Z","body":"noise"}]}' | ab)"
[ "$got" = "hf7y/senechal#439" ] \
  && ok "C: the newest pointer wins over the body's" \
  || bad "C: the newest pointer wins over the body's" "got: $got"

got="$(printf '%s' '{"body":"DECISION: @zach","comments":[{"createdAt":"2026-08-29T10:00:00Z","body":"no pointer"}]}' | ab)"
[ "$got" = "null" ] \
  && ok "D: no pointer anywhere is null, not empty" \
  || bad "D: no pointer anywhere is null" "got: $got"

echo
summary
