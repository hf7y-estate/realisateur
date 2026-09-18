#!/usr/bin/env bash
# Contract test for gh-sign.sh's `issue close` guard (#752, #294, #778): a
# COMPLETED close that landed nothing and says nothing is refused, and every
# honest close goes through -- including when GitHub does not answer.
set -uo pipefail
# shellcheck source=bin/tests/lib/harness.sh
. "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib/harness.sh"
harness_tmp

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GS="$HERE/../gh-sign.sh"
BASH_BIN="$(command -v bash)"

# A fake gh: answers the guard's two reads, logs the rest. FAKE_LANDED,
# FAKE_VIEW_RC and FAKE_API_RC are the states the guard must survive.
mkdir -p "$T/stub"
cat > "$T/stub/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GH_LOG"
case "${1:-} ${2:-}" in
  'issue view')
    [ "${FAKE_VIEW_RC:-0}" -eq 0 ] || exit "$FAKE_VIEW_RC"
    case "$*" in
      *"--json assignees"*)
        printf '%s\n' "${FAKE_ASSIGNED:-false}"
        exit 0 ;;
    esac
    printf '%s\n' "${FAKE_URL:-https://github.com/hf7y/widget/issues/7}"
    cat "$FAKE_BODY"
    exit 0 ;;
esac
if [ "${1:-}" = api ]; then
  [ "${FAKE_API_RC:-0}" -eq 0 ] || exit "$FAKE_API_RC"
  [ "${FAKE_LANDED:-0}" -eq 1 ] && printf 'landed\n'
  exit 0
fi
exit 0
STUB
chmod +x "$T/stub/gh"

FAKE_BODY="$T/body"
printf 'NO-DECISION: shipped, nothing to weigh\n\nsome issue.\n' > "$FAKE_BODY"

run() {  # run <argv...> -- returns the shim's exit code, stderr in $OUT
  : > "$T/gh.log"
  OUT="$(GH_LOG="$T/gh.log" FAKE_BODY="$FAKE_BODY" \
    FAKE_LANDED="${FAKE_LANDED:-0}" FAKE_VIEW_RC="${FAKE_VIEW_RC:-0}" \
    FAKE_API_RC="${FAKE_API_RC:-0}" FAKE_URL="${FAKE_URL:-}" \
    FAKE_ASSIGNED="${FAKE_ASSIGNED:-false}" \
    PATH="$T/stub:$PATH" "$BASH_BIN" "$GS" "$@" 2>&1)"
}
closed() { grep -q '^issue close' "$T/gh.log"; }

echo "gh-sign issue-close guard"

section "A. the defect: COMPLETED, nothing landed, nothing said"

run issue close 7 --repo hf7y/widget --comment 'Closing: this is a map, not work.'
rc "A1 a close that names nothing is REFUSED" 7 "$?"
has "A2 ...it says which issue" "$OUT" "hf7y/widget#7"
has "A3 ...and offers the honest closes" "$OUT" '--reason "not planned"'
if closed; then bad "A4 nothing was closed"; else ok "A4 nothing was closed"; fi

run issue close 7 --repo hf7y/widget
rc "A5 a close with NO --comment at all is REFUSED" 7 "$?"
if closed; then bad "A6 nothing was closed"; else ok "A6 nothing was closed"; fi

section "B. the honest closes, all of which pass"

FAKE_LANDED=1 run issue close 7 --repo hf7y/widget --comment 'done'
rc "B1 a merged PR references the issue -- passes" 0 "$?"
if closed; then ok "B2 ...and the close happened"; else bad "B2 ...and the close happened" "$OUT"; fi
FAKE_LANDED=0

run issue close 7 --repo hf7y/widget --reason 'not planned' --comment 'premise expired'
rc "B3 --reason \"not planned\" -- passes" 0 "$?"
if closed; then ok "B4 ...and the close happened"; else bad "B4 ...and the close happened" "$OUT"; fi

run issue close 7 --repo hf7y/widget --reason='not planned'
rc "B5 --reason=not planned, the other spelling -- passes" 0 "$?"

run issue close 7 --repo hf7y/widget --comment 'closed by hf7y/scheduler#118, which merged today'
rc "B6 a TRACKER whose target landed in another repo -- passes" 0 "$?"
if closed; then ok "B7 ...and the close happened"; else bad "B7 ...and the close happened" "$OUT"; fi

run issue close 7 --repo hf7y/widget --comment 'landed as 5f1ae62 on main'
rc "B8 a close naming a commit -- passes" 0 "$?"

run issue close 7 --repo hf7y/widget --comment 'landed as path:/usr/local/bin/gh on monkey'
rc "B9 a close typed in the DELIVERS vocabulary -- passes" 0 "$?"

run issue close 7 --repo hf7y/widget --comment 'Already done -- `bin/lib/carries.tsv` carries it.'
rc "B10 a close naming a file -- passes" 0 "$?"

# Without its own arm the equals form arrives as an EMPTY comment, and an
# honest close is refused over a formatting choice.
run issue close 7 --repo hf7y/widget --comment=closed-by-hf7y/scheduler#118
rc "B10b --comment=<text>, the other spelling, is read too" 0 "$?"

FAKE_ASSIGNED=true run issue close 7 --repo hf7y/widget --comment 'Answered: monkey, per Zach today.'
rc "B11 an issue that still carries an assignee closes on the answer -- passes" 0 "$?"
if closed; then ok "B12 ...and the close happened"; else bad "B12 ...and the close happened" "$OUT"; fi
FAKE_ASSIGNED=false

section "B'. hf7y/scheduler#318: assignees replaced the DECISION: sentence -- the sentence alone no longer bypasses the guard"
printf 'DECISION: @hf7y -- which host?\nDEFAULT-AFTER 14d: pick monkey\n' > "$FAKE_BODY"
run issue close 7 --repo hf7y/widget --comment 'Answered: monkey, per Zach today.'
rc "B'1 a DECISION:-shaped body with NO assignee is refused -- the text alone means nothing now" 7 "$?"
printf 'NO-DECISION: shipped, nothing to weigh\n\nsome issue.\n' > "$FAKE_BODY"

section "C. fail open -- a guard that wedges 18 accounts is worse than the leak"

FAKE_API_RC=1 run issue close 7 --repo hf7y/widget --comment 'no ref here'
rc "C1 the timeline API does not answer -- passes" 0 "$?"
if closed; then ok "C2 ...and the close happened"; else bad "C2 ...and the close happened" "$OUT"; fi
FAKE_API_RC=0

FAKE_VIEW_RC=1 run issue close 7 --repo hf7y/widget --comment 'no ref here'
rc "C3 the issue cannot be read -- passes" 0 "$?"
FAKE_VIEW_RC=0

FAKE_URL='not a url' run issue close 7 --repo hf7y/widget --comment 'no ref here'
rc "C4 the issue URL is unparseable -- passes" 0 "$?"
FAKE_URL=''

: > "$T/gh.log"
OUT="$(GH_LOG="$T/gh.log" GH_SIGN_LIB="$T/nolib" FAKE_BODY="$FAKE_BODY" \
  PATH="$T/stub:$PATH" "$BASH_BIN" "$GS" issue close 7 --repo hf7y/widget --comment x 2>&1)"
rc "C5 no grammar library -- BLIND, so it passes" 0 "$?"
if closed; then ok "C6 ...and the close happened"; else bad "C6 ...and the close happened" "$OUT"; fi

section "D. it grades a close, and nothing else"

run issue comment 7 --repo hf7y/widget --body 'no ref, no landing, just a comment'
rc "D1 a comment is never graded for landing" 0 "$?"

run pr close 7 --repo hf7y/widget
rc 'D2 pr close is not an issue close' 0 "$?"

summary
