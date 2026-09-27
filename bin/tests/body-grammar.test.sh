#!/usr/bin/env bash
# body-grammar.test.sh -- witness for bin/lib/body-grammar.sh and the
# admission control bin/gh-sign.sh builds on it.
#
# SUBJECT: bin/lib/body-grammar.sh, bin/gh-sign.sh
#
# Section S is the claim an after-the-fact audit could not make: a malformed
# body never reaches the network.
set -uo pipefail

ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
. "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib/harness.sh"
. "$ROOT/lib/body-grammar.sh"

SHIM="$ROOT/gh-sign.sh"
harness_tmp

# A stub `gh`: if $T/reached appears, section S's write went through.
mkdir -p "$T/bin"
cat > "$T/bin/gh" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$T/reached"
cat > "$T/last-body" 2>/dev/null || true
EOF
chmod +x "$T/bin/gh"

# findings <body> -- the grammar's finding count, as a string.
findings() { local o; o="$(grammar_check "$1")"; printf '%s' "$?"; : "$o"; }
codes()    { grammar_check "$1" | while read -r c _; do printf '%s ' "$c"; done; }

GOOD='DECISION: @zach -- link the shim host-wide?
DEFAULT-AFTER 14d: link it and say so; unlinking is one command

Prose about the change.

<!-- DEFERRED -->
- hf7y/vim-arcade#143 -- drop the third copy of the retired grammar
- hf7y/realisateur#330 -- gh-sign is linked nowhere, so nothing is signed
<!-- /DEFERRED -->

<!-- DELIVERS -->
- host:monkey path:/usr/local/bin/gh via: install-verb-build.sh --link
<!-- /DELIVERS -->'

section 'A. the declaration is read from the FIRST non-empty line only'
eq 'A1 DECISION opens it'            "$(grammar_declaration "$GOOD")" decision
eq 'A2 NO-DECISION is its own kind'  "$(grammar_declaration 'NO-DECISION: nothing to call')" no-decision
eq 'A3 an ordinary body declares nothing' "$(grammar_declaration 'just a body')" none
eq 'A4 markdown furniture is stripped' "$(grammar_declaration '## DECISION: still counts')" decision
eq 'A5 leading blank lines are skipped' "$(grammar_declaration '

DECISION: after two blanks')" decision
# The word must OPEN the line, or a body QUOTING the convention exempts itself.
eq 'A6 a mention mid-line is not a declaration' \
  "$(grammar_declaration 'this PR follows the DECISION: convention')" none

section 'B. a decision buried below line 1 is the failure the convention exists for'
has 'B1 flagged' "$(codes 'intro paragraph

DECISION: buried at line 3

<!-- DEFERRED -->
- none
<!-- /DEFERRED -->')" MISPLACED-DECISION
eq  'B2 the well-formed body is clean' "$(findings "$GOOD")" 0
# #419: NO-DECISION asserts there is nobody to decide, so it names no @handle.
eq  'B2a NO-DECISION needs no decider' "$(findings 'NO-DECISION: agent work -- tests green, nothing to weigh

<!-- DEFERRED -->
- none
<!-- /DEFERRED -->

<!-- DELIVERS -->
- none
<!-- /DELIVERS -->')" 0
has 'B2b DECISION still needs one' "$(codes 'DECISION: who links the shim?

<!-- DEFERRED -->
- none
<!-- /DEFERRED -->')" NO-DECIDER
has 'B2c a buried NO-DECISION is still MISPLACED' "$(codes 'intro paragraph

NO-DECISION: buried at line 3

<!-- DEFERRED -->
- none
<!-- /DEFERRED -->')" MISPLACED-DECISION
eq  'B3 a fenced example is not a buried decision' \
  "$(findings 'NO-DECISION: @zach nothing to weigh

```
DECISION: this is an example
```

<!-- DEFERRED -->
- none
<!-- /DEFERRED -->

<!-- DELIVERS -->
- none
<!-- /DELIVERS -->')" 0

section 'C. the DEFERRED block'
has 'C1 absent block is UNLEDGERED'   "$(codes 'a body with no ledger at all')" UNLEDGERED
has 'C2 empty block is EMPTY-LEDGER'  "$(codes 'NO-DECISION: @zach ok
<!-- DEFERRED -->
<!-- /DEFERRED -->')" EMPTY-LEDGER
has 'C3 two blocks are MULTI-LEDGER'  "$(codes 'NO-DECISION: @zach ok
<!-- DEFERRED -->
- none
<!-- /DEFERRED -->
<!-- DEFERRED -->
- none
<!-- /DEFERRED -->')" MULTI-LEDGER
has 'C4 an unclosed block is UNCLOSED' "$(codes 'NO-DECISION: @zach ok
<!-- DEFERRED -->
- hf7y/chezz#12 -- a thing')" UNCLOSED
eq  'C5 "- none" is a complete, passing answer' "$(findings 'NO-DECISION: @zach ok
<!-- DEFERRED -->
- none
<!-- /DEFERRED -->

<!-- DELIVERS -->
- none
<!-- /DELIVERS -->')" 0

section 'D. every entry names a destination'
has 'D1 a bare intention has none' "$(codes 'NO-DECISION: @zach ok
<!-- DEFERRED -->
- clean up the ratchets sometime
<!-- /DEFERRED -->')" NO-DESTINATION
eq 'D2 owner/repo#N is a destination' "$(findings 'NO-DECISION: @zach ok
<!-- DEFERRED -->
- hf7y/scheduler#49 -- the sibling issue
<!-- /DEFERRED -->

<!-- DELIVERS -->
- none
<!-- /DELIVERS -->')" 0
eq 'D3 a URL is a destination' "$(findings 'NO-DECISION: @zach ok
<!-- DEFERRED -->
- https://github.com/hf7y/realisateur/issues/327 -- the read side
<!-- /DEFERRED -->

<!-- DELIVERS -->
- none
<!-- /DELIVERS -->')" 0
# NO-OWNER is refused however well argued. #327 filed two and lost both, while
# the issue it DID cite is open and findable; it merged as a no-op.
has 'D4 NO-OWNER is refused even with a full reason' "$(codes 'NO-DECISION: @zach ok
<!-- DEFERRED -->
- NO-OWNER: it needs a human call about all thirteen accounts at once
<!-- /DEFERRED -->')" NO-DESTINATION
has 'D5 and refused without one' "$(codes 'NO-DECISION: @zach ok
<!-- DEFERRED -->
- NO-OWNER: later
<!-- /DEFERRED -->')" NO-DESTINATION
eq 'D6 a wrapped entry folds into its bullet' "$(findings 'NO-DECISION: @zach ok
<!-- DEFERRED -->
- hf7y/realisateur#330 -- it changes what four live accounts must hold
  before they can fetch anything, so a human decides
<!-- /DEFERRED -->

<!-- DELIVERS -->
- none
<!-- /DELIVERS -->')" 0

section 'T. the DELIVERS ledger -- where the change takes effect'
eq 'T1 no DELIVERS block is a finding' "$(codes 'NO-DECISION: x

<!-- DEFERRED -->
- none
<!-- /DEFERRED -->')" 'UNSHIPPED '
eq 'T2 "- none" is a complete answer' "$(findings 'NO-DECISION: x

<!-- DEFERRED -->
- none
<!-- /DEFERRED -->

<!-- DELIVERS -->
- none
<!-- /DELIVERS -->')" 0
eq 'T3 a typed claim passes' "$(findings 'NO-DECISION: x

<!-- DEFERRED -->
- none
<!-- /DEFERRED -->

<!-- DELIVERS -->
- clock:root@monkey tag:realisateur:ausculte:CADENCE
<!-- /DELIVERS -->')" 0
eq 'T4 prose a check cannot look for is a finding' "$(codes 'NO-DECISION: x

<!-- DEFERRED -->
- none
<!-- /DEFERRED -->

<!-- DELIVERS -->
- it lands on the host
<!-- /DELIVERS -->')" 'UNTYPED-DELIVERY '
eq 'T5 an empty block is not an answer' "$(codes 'NO-DECISION: x

<!-- DEFERRED -->
- none
<!-- /DEFERRED -->

<!-- DELIVERS -->
<!-- /DELIVERS -->')" 'EMPTY-SHIP '
eq 'T6 two blocks: a reader cannot tell which is current' "$(codes 'NO-DECISION: x

<!-- DEFERRED -->
- none
<!-- /DEFERRED -->

<!-- DELIVERS -->
- none
<!-- /DELIVERS -->
<!-- DELIVERS -->
- none
<!-- /DELIVERS -->')" 'MULTI-SHIP '

eq 'T7 an indented example is not a second block' "$(findings 'NO-DECISION: x

Here is what one looks like:

    <!-- DELIVERS -->
    - host:monkey path:/usr/local/bin/dresse
    <!-- /DELIVERS -->

<!-- DEFERRED -->
- none
<!-- /DEFERRED -->

<!-- DELIVERS -->
- none
<!-- /DELIVERS -->')" 0

section 'S. the shim REFUSES, and the refusal is what stops the write'
run_shim() { ( PATH="$T/bin:$PATH"; cd "$T" && bash "$SHIM" "$@" 2>&1 ); }
rm -f "$T/reached"

printf '%s\n' "$GOOD" > "$T/good.md"
printf 'intro\n\nDECISION: buried\n' > "$T/bad.md"

out="$(run_shim issue create --title T --body-file "$T/bad.md")"; got=$?
rc   'S1 a malformed issue body is REFUSED (7): nothing was created' 7 "$got"
has  'S2 it says what is wrong'          "$out" MISPLACED-DECISION
has  'S3 it prints the block to paste'   "$out" '<!-- DEFERRED -->'
if [ -f "$T/reached" ]; then bad 'S4 gh was never called' "gh ran: $(cat "$T/reached")"
else ok 'S4 gh was never called'; fi

out="$(run_shim issue create --title T --body-file "$T/good.md")"
if [ -f "$T/reached" ]; then ok 'S5 a well-formed body reaches gh'
else bad 'S5 a well-formed body reaches gh' "gh was never called: $out"; fi

# gh-sign.sh needed no change: it refuses on any finding grammar_check reports.
printf 'NO-DECISION: agent work\n\nThis does not close #79.\n\n<!-- DEFERRED -->\n- none\n<!-- /DEFERRED -->\n\n<!-- DELIVERS -->\n- none\n<!-- /DELIVERS -->\n' > "$T/negated.md"
rm -f "$T/reached"
out="$(run_shim pr create --title T --body-file "$T/negated.md")"; got=$?
rc  'S5a a PR body denying a close it would perform is REFUSED (7)' 7 "$got"
has 'S5b it names NEGATED-CLOSE' "$out" NEGATED-CLOSE
if [ -f "$T/reached" ]; then bad 'S5c the PR was never created' "gh ran: $(cat "$T/reached")"
else ok 'S5c the PR was never created'; fi

# Comments are deliberately exempt: a thread reply is not where a ledger
# belongs, and refusing one loses the reply. It still gets signed.
rm -f "$T/reached"
run_shim issue comment 5 --body 'a reply with no ledger' >/dev/null
if [ -f "$T/reached" ]; then ok 'S6 a comment is not held to the create grammar'
else bad 'S6 a comment is not held to the create grammar' 'the shim refused a comment'; fi

# A guard that cannot look must SAY so and fall through -- never report clean.
out="$( PATH="$T/bin:$PATH" GH_SIGN_LIB=/nonexistent bash "$SHIM" issue create --title T --body-file "$T/bad.md" 2>&1 )"
has 'S7 a missing grammar library is announced BLIND, not silently skipped' "$out" BLIND

out="$(bash "$SHIM" --check-body "$T/bad.md" 2>&1)"; got=$?
rc  'S8 --check-body re-runs it offline and FINDS it (1), refusing nothing' 1 "$got"
has 'S9 --check-body names the same finding'         "$out" MISPLACED-DECISION

section 'I. the CI backstop is wired to the same grammar'
hasnt 'I5 the deleted script is really gone' "$(ls "$ROOT")" 'deferral-ledger.sh'

# --- DEFAULT-AFTER: the unanswered decision resolves itself (2026-08-22) -----
# 36 open `needs-human` each subtracted from `actionable` in tempo.sh, so every
# unanswered question also braked the repo that asked it (#262).
section "DEFAULT-AFTER"

_da() { printf 'DECISION: @zach -- q\n%s\n<!-- DEFERRED -->\n- none\n<!-- /DEFERRED -->\n<!-- DELIVERS -->\n- none\n<!-- /DELIVERS -->\n' "$1"; }

grammar_check "$(_da 'DEFAULT-AFTER 14d: close it as declined')" >/dev/null 2>&1 \
  && ok "a well-formed default is accepted" \
  || bad "a well-formed default is accepted" "it was refused"

out="$(grammar_check "$(_da 'DEFAULT-AFTER: close it')" 2>&1)"
case "$out" in *BAD-DEFAULT*) ok "a default with no day count is BAD-DEFAULT" ;;
  *) bad "no day count is BAD-DEFAULT" "got: $out" ;; esac

out="$(grammar_check "$(_da 'DEFAULT-AFTER 14d:')" 2>&1)"
case "$out" in *BAD-DEFAULT*) ok "a window with no action is BAD-DEFAULT -- a timer to nowhere" ;;
  *) bad "no action is BAD-DEFAULT" "got: $out" ;; esac

# --- A QUOTED DECLARATION IS TEXT (hf7y/wtul#346, again on #356) -------------
# Demoting an answered DECISION to NO-DECISION while keeping the original wording
# quoted beside it was refused: the `DEFAULT-AFTER 14d:` inside the blockquote
# still parsed as a live declaration, so the body could not carry its own
# history. Two writes refused on #346 before the body took. `>` is not markdown
# decoration like # * _ -; it is how supersession is written.
_demoted="$(printf 'NO-DECISION: answered 2026-09-25, the original is quoted below\n\n> DECISION: @zach -- which shim?\n> DEFAULT-AFTER 14d: close it as declined\n\n<!-- DEFERRED -->\n- none\n<!-- /DEFERRED -->\n<!-- DELIVERS -->\n- none\n<!-- /DELIVERS -->\n')"
grammar_check "$_demoted" >/dev/null 2>&1 \
  && ok "a NO-DECISION may quote the DECISION and DEFAULT-AFTER it supersedes" \
  || bad "a quoted declaration is text" "it was refused: $(grammar_check "$_demoted" 2>&1)"

out="$(grammar_check "$_demoted" 2>&1)"
case "$out" in *MISPLACED-DECISION*) bad "a quoted DECISION is not MISPLACED" "got: $out" ;;
  *) ok "...and the quoted DECISION line is not MISPLACED-DECISION either" ;; esac

# The quote must not satisfy the requirement either -- a DECISION whose only
# DEFAULT-AFTER is quoted history has no live timer and still blocks forever.
_quoted_only="$(printf 'DECISION: @zach -- q\n\n> DEFAULT-AFTER 14d: what the last round said\n\n<!-- DEFERRED -->\n- none\n<!-- /DEFERRED -->\n<!-- DELIVERS -->\n- none\n<!-- /DELIVERS -->\n')"
case "$(grammar_check "$_quoted_only" 2>&1)" in *NO-DEFAULT*) ok "a DECISION whose only DEFAULT-AFTER is quoted is still NO-DEFAULT" ;;
  *) bad "quoted default does not satisfy #680" "got: $(grammar_check "$_quoted_only" 2>&1)" ;; esac

_nodefault="$(printf 'DECISION: @zach -- q\n<!-- DEFERRED -->\n- none\n<!-- /DEFERRED -->\n<!-- DELIVERS -->\n- none\n<!-- /DELIVERS -->\n')"
out="$(grammar_check "$_nodefault" 2>&1)"
case "$out" in *NO-DEFAULT*) ok "#680: a DECISION with no DEFAULT-AFTER is NO-DEFAULT -- blocking by omission is refused" ;;
  *) bad "no default is NO-DEFAULT" "got: $out" ;; esac

grammar_check "$(_da 'DEFAULT-AFTER 0d: block -- irreversible, no default')" >/dev/null 2>&1 \
  && ok "#680: blocking forever stays legal when DECLARED as 0d, so an irreversible call has a spelling" \
  || bad "0d blocks forever" "it was refused; irreversible calls lost their spelling"

grammar_check "$(printf 'NO-DECISION: agent work\n<!-- DEFERRED -->\n- none\n<!-- /DEFERRED -->\n<!-- DELIVERS -->\n- none\n<!-- /DELIVERS -->\n')" >/dev/null 2>&1 \
  && ok "#680: NO-DECISION needs no default -- the rule binds the bodies that ask, not the ones that report" \
  || bad "NO-DECISION needs no default" "it was refused"

# The reader the actuator consumes.
got="$(grammar_default_after "$(_da 'DEFAULT-AFTER 14d: close it as declined')")"
eq "the reader returns days and action, tab-separated" "$got" "$(printf '14\tclose it as declined')"
grammar_default_after "$(_da 'nothing here')" >/dev/null 2>&1 \
  && bad "absent default returns 1" "it returned 0" \
  || ok "an absent default returns 1, so the actuator can tell 'blocks forever' from 'not read'"

section "ANSWERED-BY"

_ab() { printf 'NO-DECISION: q\n%s\n<!-- DEFERRED -->\n- none\n<!-- /DEFERRED -->\n<!-- DELIVERS -->\n- none\n<!-- /DELIVERS -->\n' "$1"; }

grammar_check "$(_ab 'ANSWERED-BY hf7y/wtul#34')" >/dev/null 2>&1 \
  && ok "a well-formed pointer is accepted" \
  || bad "a well-formed pointer is accepted" "it was refused"

out="$(grammar_check "$(_ab 'ANSWERED-BY wtul#34')" 2>&1)"
case "$out" in *BAD-ANSWERED-BY*) ok "no owner (bare repo#n) is BAD-ANSWERED-BY" ;;
  *) bad "no owner is BAD-ANSWERED-BY" "got: $out" ;; esac

out="$(grammar_check "$(_ab 'ANSWERED-BY hf7y/wtul')" 2>&1)"
case "$out" in *BAD-ANSWERED-BY*) ok "no issue number is BAD-ANSWERED-BY" ;;
  *) bad "no issue number is BAD-ANSWERED-BY" "got: $out" ;; esac

out="$(grammar_check "$(_ab 'ANSWERED-BY see the other issue')" 2>&1)"
case "$out" in *BAD-ANSWERED-BY*) ok "prose instead of a ref is BAD-ANSWERED-BY" ;;
  *) bad "prose instead of a ref is BAD-ANSWERED-BY" "got: $out" ;; esac

grammar_check "$(printf 'NO-DECISION: q\n<!-- DEFERRED -->\n- none\n<!-- /DEFERRED -->\n<!-- DELIVERS -->\n- none\n<!-- /DELIVERS -->\n')" >/dev/null 2>&1 \
  && ok "a body with no pointer is still valid" \
  || bad "no pointer is still valid" "it was refused"

got="$(grammar_answered_by "$(_ab 'ANSWERED-BY hf7y/wtul#34')")"
eq "the reader returns the ref" "$got" "hf7y/wtul#34"
grammar_answered_by "$(_ab 'nothing here')" >/dev/null 2>&1 \
  && bad "absent pointer returns 1" "it returned 0" \
  || ok "an absent pointer returns 1, so the caller can tell 'no pointer' from 'not read'"

# --- NEGATED-CLOSE ----------------------------------------------------------
# hf7y/scheduler#180 shut scheduler#79 -- the ROSTER consolidation -- from a
# sentence under a heading titled "What this is not".
section "NEGATED-CLOSE"

_nc() { printf 'NO-DECISION: agent work\n%s\n<!-- DEFERRED -->\n- none\n<!-- /DEFERRED -->\n<!-- DELIVERS -->\n- none\n<!-- /DELIVERS -->\n' "$1"; }

# The real sentence, verbatim from the merged PR body.
has 'N1 the sentence that cost scheduler#79 is refused' \
  "$(codes "$(_nc '## What this is not

This does not retire `RUNNER_CRON` or close #79/#81'"'"'s `onekey`/`perproject` probes — `bin/roster-target.sh` is unchanged at 4/6 by this commit.')")" NEGATED-CLOSE

# THE STANDING DECISION, Zach 2026-08-04: "batch agents should close shipped
# issues automatically. this can't be a regular clean up by hand." Lose this
# fixture and the guard can silently become the ban that reverses it.
eq 'N2 a plain `Closes #123` still closes -- the standing decision is intact' \
  "$(findings "$(_nc 'Closes #123')")" 0

eq 'N3 a bare #79 inside a denial is the fix, not the defect' \
  "$(findings "$(_nc 'This does not retire RUNNER_CRON or touch #79 at all.')")" 0

eq 'N4 a fenced example is quoted code, not a close' \
  "$(findings "$(_nc '```
This PR does not close #79.
```')")" 0

eq 'N5 an inline code span is a quotation, so this rule can be written down' \
  "$(findings "$(_nc 'Never write `close #79` in a denial; write the bare number.')")" 0

has 'N6 the enclosing heading negates on its own -- no marker on the line' \
  "$(codes "$(_nc '## Non-goals

Closes #79 -- listed here so the reader knows it is untouched.')")" NEGATED-CLOSE

eq 'N7 the next heading ends the denial: a close under it still closes' \
  "$(findings "$(_nc '## Non-goals

nothing here

## What ships

Closes #123')")" 0

# COMPOSITION: every finding, not the first, or the second one is hidden.
_compose="$(printf 'a body that declares nothing\n\nThis does not close hf7y/scheduler#79.\n')"
has 'N8 composed: UNDECLARED is still reported'    "$(codes "$_compose")" UNDECLARED
has 'N9 composed: NEGATED-CLOSE is reported too'   "$(codes "$_compose")" NEGATED-CLOSE
has 'N10 composed: so is UNSHIPPED'                "$(codes "$_compose")" UNSHIPPED
eq  'N11 composed: four findings, not one'         "$(findings "$_compose")" 4

section 'L. grammar_landing_ref -- what a close names that a check could follow'

_lr() { grammar_landing_ref "$1" || printf 'NONE'; }

eq 'L1 a bare #N'            "$(_lr 'closed by #761')"                       '#761'
eq 'L2 owner/repo#N'         "$(_lr 'landed in hf7y/scheduler#118 today')"   'hf7y/scheduler#118'
eq 'L3 a pull URL'           "$(_lr 'see https://github.com/hf7y/x/pull/12')" 'https://github.com/hf7y/x/pull/12'
eq 'L4 a commit'             "$(_lr 'merged as 5f1ae62, branch deleted')"    '5f1ae62'
eq 'L5 a typed DELIVERS claim' "$(_lr 'landed as path:/usr/local/bin/gh on monkey')" 'path:/usr/local/bin/gh'
eq 'L6 a code span naming a file' "$(_lr 'Already done -- `bin/lib/carries.tsv` carries it.')" 'bin/lib/carries.tsv'
eq 'L7 prose names nothing'  "$(_lr 'Closing: this is a map, not work.')"    'NONE'
eq 'L8 an all-digit token is a date or a size, not a commit' \
  "$(_lr 'the 20260830 run reclaimed 254000000 bytes')"                      'NONE'
eq 'L9 a statement below line 1 is still read' \
  "$(_lr "$(printf 'Closing.\n\nThe work landed in #118.\n')")"             '#118'
eq 'L10 an empty close names nothing' "$(_lr '')"                            'NONE'

summary
