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

summary
