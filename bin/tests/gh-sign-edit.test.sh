#!/usr/bin/env bash
set -uo pipefail
. "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib/harness.sh"

check(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected [$3] got [$2]"; fi; }
contains(){ case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "expected to contain [$3], got [$2]" ;; esac; }

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GS="$HERE/../gh-sign.sh"
BASH_BIN="$(command -v bash)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/stub"
cat > "$TMP/stub/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GH_LOG"
: > "$GH_LAST_BODY"
prev=''
for a in "$@"; do
  case "$prev" in --comment|--body) printf '%s' "$a" > "$GH_LAST_BODY" ;; esac
  prev="$a"
done
printf '%s\n' "$*" | grep -q -- '--body-file -' && cat > "$GH_LAST_BODY"
prev=''
for a in "$@"; do
  case "$a" in
    body=@-)
      case "$prev" in -F|--field) cat > "$GH_LAST_BODY" ;; *) printf '%s' "$a" > "$GH_LAST_BODY" ;; esac ;;
    body=*) printf '%s' "${a#body=}" > "$GH_LAST_BODY" ;;
  esac
  prev="$a"
done
exit "${GH_EXIT:-0}"
STUB
chmod +x "$TMP/stub/gh"

run() {
  GH_LOG="$TMP/gh.log" GH_LAST_BODY="$TMP/gh.body" CLAUDECODE=1 \
  PATH="$TMP/stub:$PATH" "$BASH_BIN" "$GS" "$@"
}
lastline() { grep -v '^[[:space:]]*$' "$TMP/gh.body" | tail -1; }
reset() { : > "$TMP/gh.log"; : > "$TMP/gh.body"; }

GOOD='NO-DECISION: @zach nothing to weigh

<!-- DEFERRED -->
- none
<!-- /DEFERRED -->

<!-- DELIVERS -->
- none
<!-- /DELIVERS -->'
BAD='no declaration line at all'

echo "gh-sign-edit contract (#970)"

section "A. issue edit / pr edit -- graded exactly like create"
reset
run issue edit 5 --repo hf7y/widget --body "$GOOD" >/dev/null 2>&1
check "a well-formed issue edit exits 0" "$?" "0"
case "$(lastline)" in
  '<!-- agent: '*) ok "...and is signed" ;;
  *) bad "signed" "last non-blank line: $(lastline)" ;;
esac

reset
run issue edit 5 --repo hf7y/widget --body "$BAD" >/dev/null 2>&1
check "a malformed issue edit is REFUSED (7)" "$?" "7"
check "...and nothing reached gh" "$(cat "$TMP/gh.log")" ""

reset
run pr edit 5 --repo hf7y/widget --body "$GOOD" >/dev/null 2>&1
check "a well-formed pr edit exits 0" "$?" "0"
case "$(lastline)" in
  '<!-- agent: '*) ok "...and is signed too" ;;
  *) bad "signed" "last non-blank line: $(lastline)" ;;
esac

contains "...over REST, not the GraphQL edit (musc-2300#104)" "$(cat "$TMP/gh.log")" "api -X PATCH repos/hf7y/widget/pulls/5 -F body=@-"

reset
run pr edit 5 --repo hf7y/widget --title T --body "$GOOD" >/dev/null 2>&1
contains "a pr edit touching more than the body still goes to gh pr edit" "$(cat "$TMP/gh.log")" "pr edit 5 --repo hf7y/widget --title T --body-file -"

reset
run pr edit 5 --repo hf7y/widget --body "$BAD" >/dev/null 2>&1
check "a malformed pr edit is REFUSED (7)" "$?" "7"

section "B. gh api PATCH to the same path -- the route named in #970"
reset
run api -X PATCH repos/hf7y/widget/issues/5 -f body="$GOOD" >/dev/null 2>&1
check "a well-formed api issue-body PATCH exits 0" "$?" "0"
contains "...the body reaches gh" "$(cat "$TMP/gh.body")" "NO-DECISION"
case "$(lastline)" in
  '<!-- agent: '*) ok "...and is signed" ;;
  *) bad "signed" "last non-blank line: $(lastline)" ;;
esac
contains "...the flag was upgraded from -f to -F for the write-back" "$(cat "$TMP/gh.log")" " -F body=@-"

reset
run api -X PATCH repos/hf7y/widget/issues/5 -f body="$BAD" >/dev/null 2>&1
check "a malformed api issue-body PATCH is REFUSED (7)" "$?" "7"
check "...and nothing reached gh" "$(cat "$TMP/gh.log")" ""

reset
run api -X PATCH repos/hf7y/widget/pulls/5 -f body="$GOOD" >/dev/null 2>&1
check "a pr-body PATCH by the same api route exits 0" "$?" "0"
case "$(lastline)" in
  '<!-- agent: '*) ok "...and is signed" ;;
  *) bad "signed" "last non-blank line: $(lastline)" ;;
esac

section "C. the read path this write used to hide behind is unaffected"
reset
run api repos/hf7y/widget/issues/5 >/dev/null 2>&1
check "a bare GET on the same path still reaches gh unsigned" \
  "$(cat "$TMP/gh.body" 2>/dev/null)" ""
contains "...with its argv intact" "$(cat "$TMP/gh.log")" "repos/hf7y/widget/issues/5"

reset
run api repos/hf7y/widget/issues/5/comments -f body="$GOOD" >/dev/null 2>&1
check "a comment POST on the /comments path is unaffected by the edit route" "$?" "0"
case "$(lastline)" in
  '<!-- agent: '*) ok "...still signed via the pre-existing comment path" ;;
  *) bad "signed" "last non-blank line: $(lastline)" ;;
esac

section "D. no agent env and no TTY is CRON (not human), so cron's edit is graded too"
reset
env -u CLAUDECODE -u CLAUDE_CODE_ENTRYPOINT \
  GH_LOG="$TMP/gh.log" GH_LAST_BODY="$TMP/gh.body" \
  PATH="$TMP/stub:$PATH" "$BASH_BIN" "$GS" \
  issue edit 5 --repo hf7y/widget --body "$BAD" </dev/null >/dev/null 2>&1
check "a malformed edit from cron is still REFUSED (7)" "$?" "7"

# --- E. hf7y/scheduler#318: an agent may not unassign hf7y -----------------
# Assignment is the native "waiting on a human" signal now (the field, not a
# body sentence); only Zach's own act -- a real TTY at the keyboard -- may
# clear it. Additive: it must not touch anything above.
section "E. hf7y/scheduler#318: an agent may not unassign hf7y"
reset
run issue edit 5 --repo hf7y/widget --remove-assignee hf7y >/dev/null 2>&1
check "an agent removing hf7y as assignee is REFUSED (7)" "$?" "7"
check "...and nothing reached gh -- the unassign never happened" "$(cat "$TMP/gh.log")" ""

reset
run pr edit 5 --repo hf7y/widget --remove-assignee hf7y >/dev/null 2>&1
check "the same guard applies to pr edit" "$?" "7"

reset
run issue edit 5 --repo hf7y/widget --remove-assignee=hf7y >/dev/null 2>&1
check "the --remove-assignee=<login> spelling is caught too" "$?" "7"

reset
run issue edit 5 --repo hf7y/widget --remove-assignee someoneelse,hf7y >/dev/null 2>&1
check "hf7y named in a comma-separated --remove-assignee list is still caught" "$?" "7"

reset
run issue edit 5 --repo hf7y/widget --remove-assignee HF7Y >/dev/null 2>&1
check "the login match is case-insensitive" "$?" "7"

reset
run issue edit 5 --repo hf7y/widget --remove-assignee someoneelse >/dev/null 2>&1
check "removing a DIFFERENT assignee is unaffected -- this guard names hf7y only" "$?" "0"

reset
run issue edit 5 --repo hf7y/widget --add-assignee hf7y --body "$GOOD" >/dev/null 2>&1
check "ADDING hf7y as assignee is unaffected -- the guard is about removal only" "$?" "0"

reset
env -u CLAUDECODE -u CLAUDE_CODE_ENTRYPOINT \
  GH_LOG="$TMP/gh.log" GH_LAST_BODY="$TMP/gh.body" \
  PATH="$TMP/stub:$PATH" "$BASH_BIN" "$GS" \
  issue edit 5 --repo hf7y/widget --remove-assignee hf7y </dev/null >/dev/null 2>&1
check "cron (no CLAUDECODE, no TTY) is refused too -- cron is not Zach's own act" "$?" "7"

# The human path needs a pty, same as gh-sign.test.sh's own human-at-keyboard case.
if command -v script >/dev/null 2>&1; then
  reset
  script -qec "env -u CLAUDECODE -u CLAUDE_CODE_ENTRYPOINT \
    GH_LOG='$TMP/gh.log' GH_LAST_BODY='$TMP/gh.body' \
    PATH='$TMP/stub:$PATH' '$BASH_BIN' '$GS' \
    issue edit 5 --repo hf7y/widget --remove-assignee hf7y" /dev/null >/dev/null 2>&1
  check "a human at a real TTY still clears it -- only Zach's own act may" \
    "$(grep -c '^issue edit 5' "$TMP/gh.log")" "1"
else
  echo "  SKIP  human-at-keyboard: no \`script\` to allocate a pty" >&2
fi

summary
