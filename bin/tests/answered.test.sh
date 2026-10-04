#!/usr/bin/env bash
# answered.test.sh -- witness for the `stale` verdict added to
# bin/lib/answered.jq / bin/lib/answered.sh (#1406): a `needs-human` body or
# comment naming a lock/deadline date already past reports `stale`, a verdict
# distinct from both `answered` and `unanswered` -- so cloture's "only exit 1
# is blocked on Zach" rule (`.claude/commands/cloture.md` section 4) excludes
# it without cloture itself changing.
#
# HERMETIC: issue_answered_json takes JSON directly, no `gh` call to fake.
# ANSWERED_TODAY pins the clock `stale` grades against, so the suite does not
# drift as the calendar moves.
set -uo pipefail
. "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib/harness.sh"
ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
export ANSWERED_TODAY=2026-10-04
export ANSWERED_OWNER=hf7y
. "$ROOT/lib/answered.sh"

echo "answered.test.sh"

section "A. musc-2300#149's shape: a lock date already past reports stale"
A_JSON='{"number":149,"title":"Lab 6","labels":[],
  "body":"DECISION: @hf7y -- send them, or let the window close.\nDEFAULT-AFTER 2d: send nothing. Canvas 15026433 locks Mon 2026-09-28 13:00 CT and the messages are discarded unread.",
  "comments":[{"author":{"login":"hf7y"},"createdAt":"2026-10-01T15:59:31Z",
    "body":"NO-DECISION: moot. Lab 6 locked Mon 2026-09-28 13:00, so the window this asked about closed by event. Closing.\n\n<!-- agent: zach@mandark 2026-10-01T15:59:29Z -->"}]}'
issue_answered_json "$A_JSON"; rc=$?
rc "A1 exits 3 (stale)" 3 "$rc"
has "A2 ANSWERED_WHY names the passed date" "$ANSWERED_WHY" "2026-09-28"
has "A3 ANSWERED_WHY says it was an event, not a human" "$ANSWERED_WHY" "event"
[ "$rc" -ne 1 ] && ok "A4 not exit 1 -- cloture's blocked-on-Zach check excludes it" \
  || bad "A4 not exit 1 -- cloture's blocked-on-Zach check excludes it"

section "B. a plain unanswered DECISION with no date at all stays unanswered"
B_JSON='{"number":1,"title":"no date","labels":[],
  "body":"DECISION: @hf7y -- do we ship this?","comments":[]}'
issue_answered_json "$B_JSON"; rc=$?
rc "B1 exits 1 (unanswered)" 1 "$rc"

section "C. a bare date with no deadline keyword is an attribution, not stale"
C_JSON='{"number":2,"title":"attribution date","labels":[],
  "body":"DECISION: @hf7y -- Zach, 2026-08-29, noticed this (#762). Ship it?","comments":[]}'
issue_answered_json "$C_JSON"; rc=$?
rc "C1 exits 1 (unanswered), not 3" 1 "$rc"

section "D. a lock date still in the future stays unanswered, not stale"
D_JSON='{"number":3,"title":"future lock","labels":[],
  "body":"DECISION: @hf7y -- Canvas locks 2099-01-01, ship before then?","comments":[]}'
issue_answered_json "$D_JSON"; rc=$?
rc "D1 exits 1 (unanswered), not 3" 1 "$rc"

section "E. a passed date naming a keyword in a COMMENT (not the body) also goes stale"
E_JSON='{"number":4,"title":"comment-only lock","labels":[],
  "body":"DECISION: @hf7y -- ship it?",
  "comments":[{"author":{"login":"hf7y"},"createdAt":"2026-09-29T00:00:00Z",
    "body":"moot -- the window closed 2026-09-28.\n<!-- agent: zach@mandark 2026-09-29 -->"}]}'
issue_answered_json "$E_JSON"; rc=$?
rc "E1 exits 3 (stale)" 3 "$rc"

section "F. a fenced code block quoting a lock date is not a live claim"
F_JSON='{"number":5,"title":"fenced quote","labels":[],
  "body":"DECISION: @hf7y -- ship it?\n\n```\nCanvas locks 2026-01-01\n```",
  "comments":[]}'
issue_answered_json "$F_JSON"; rc=$?
rc "F1 exits 1 (unanswered) -- the fence is a quote, not a claim" 1 "$rc"

section "G. the existing verdicts are untouched by the new check"
G_ANSWERED='{"number":10,"title":"answered","labels":[],
  "body":"DECISION: @hf7y -- ship?",
  "comments":[{"author":{"login":"hf7y"},"createdAt":"2026-09-01T00:00:00Z","body":"yes, ship it"}]}'
issue_answered_json "$G_ANSWERED"; rc "G1 answered still exits 0" 0 $?
G_UNCOUNTED='{"number":11,"title":"uncounted","labels":[],
  "body":"DECISION: @hf7y -- ship?",
  "comments":[{"author":{"login":"hf7y"},"createdAt":"2026-08-01T00:00:00Z","body":"yes, ship it"}]}'
issue_answered_json "$G_UNCOUNTED"; rc "G2 pre-era comment still exits 2 (uncounted)" 2 $?
G_BLIND_JQ="$ANSWERED_JQ_FILE"
ANSWERED_JQ_FILE="/no/such/file.jq" issue_answered_json '{"number":12}' 2>/dev/null
rc "G3 an unreadable predicate is still BLIND (6)" 6 $?
ANSWERED_JQ_FILE="$G_BLIND_JQ"

summary
exit $?
