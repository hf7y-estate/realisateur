#!/usr/bin/env bash
# body-rewrite.test.sh -- witness for grammar_rewrite_on_ruling (#1434), the
# transform that flips a DECISION: body to NO-DECISION: and lands the ruling
# in the body itself, carrying the DEFERRED/DELIVERS blocks through unchanged.
#
# SUBJECT: bin/lib/body-grammar.sh:grammar_rewrite_on_ruling
set -uo pipefail

ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
. "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib/harness.sh"
. "$ROOT/lib/body-grammar.sh"

findings() { grammar_check "$1" >/dev/null; printf '%s' "$?"; }

DECISION='DECISION: @zach -- link the shim host-wide?
POLICY: which verb builds may claim a host-wide binary path
DEFAULT-AFTER 14d: link it and say so; unlinking is one command

Prose about the change, over two lines
of the same paragraph.

<!-- DEFERRED -->
- hf7y/vim-arcade#143 -- drop the third copy of the retired grammar
<!-- /DEFERRED -->

<!-- DELIVERS -->
- host:monkey path:/usr/local/bin/gh via: install-verb-build.sh --link
<!-- /DELIVERS -->'

eq 'the fixture itself is a clean DECISION, or this test proves nothing' "$(findings "$DECISION")" 0

RULING='link it host-wide; unlinking is one command if that is wrong'
OUT="$(grammar_rewrite_on_ruling "$DECISION" "$RULING")"

section 'A. the rewritten body declares NO-DECISION, carrying the ruling'
eq 'A1 line 1 declares no-decision'     "$(grammar_declaration "$OUT")" no-decision
has 'A2 line 1 carries the ruling text' "$(printf '%s\n' "$OUT" | head -1)" "$RULING"

section 'B. the rewritten body is grammatically clean -- the DECISION it replaces is quoted, not live'
eq 'B1 zero findings' "$(findings "$OUT")" 0

section 'C. the original question survives, quoted, not actuated'
has 'C1 the original DECISION line is still readable' "$OUT" '> DECISION: @zach -- link the shim host-wide?'
has 'C2 its DEFAULT-AFTER is still readable'           "$OUT" '> DEFAULT-AFTER 14d:'
rc  'C3 but it is not a LIVE default-after any more' 1 "$(grammar_default_after "$OUT" >/dev/null; echo $?)"

section 'D. the DEFERRED/DELIVERS blocks carried through unchanged'
has 'D1 the deferred entry survived verbatim' "$OUT" 'hf7y/vim-arcade#143 -- drop the third copy of the retired grammar'
has 'D2 the delivers entry survived verbatim' "$OUT" 'host:monkey path:/usr/local/bin/gh via: install-verb-build.sh --link'

summary
