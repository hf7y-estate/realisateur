#!/usr/bin/env bash
#
# Contract test for gh-sign.sh's comment-note (#1372): `gh issue view` and
# `gh pr view` are how an agent USUALLY reads one, and the api-path note in
# gh-sign.test.sh never fires for either. This covers the gap: the note
# fires on `issue view`/`pr view` too, whether or not comments were asked
# for, and never on a human's own call.
set -uo pipefail
# shellcheck source=bin/tests/lib/harness.sh
. "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib/harness.sh"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GS="$HERE/../gh-sign.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/stub"
cat > "$TMP/stub/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GH_LOG"
case "$*" in
  *'repo view'*)
    if [ -n "${GH_REPO_JSON:-}" ]; then printf '%s\n' "$GH_REPO_JSON"
    else printf '{"nameWithOwner":"hf7y/widget"}\n'; fi
    exit 0 ;;
esac
if [ -n "${GH_ISSUE_JSON:-}" ]; then printf '%s' "$GH_ISSUE_JSON"; else printf '{}'; fi
STUB
chmod +x "$TMP/stub/gh"

rd(){ PATH="$TMP/stub:$PATH" CLAUDECODE=1 GH_LOG="$TMP/gh.log" bash "$GS" "$@"; }

echo "gh-read-names-comments contract"

ISSUE='{"number":11,"body":"the view output","comments":8}'
NOCOM='{"number":11,"body":"the view output","comments":0}'

: > "$TMP/gh.log"
out="$(GH_ISSUE_JSON="$ISSUE" rd issue view 11 --repo hf7y-estate/space-canon 2>"$TMP/e")"
case "$(cat "$TMP/e")" in
  *"hf7y-estate/space-canon#11 has 8 comment(s)"*) ok "\`gh issue view\` with comments says so, on stderr" ;;
  *) bad "issue view warns" "stderr: $(cat "$TMP/e")" ;;
esac
case "$out" in *'"body":"the view output"'*) ok "...and stdout still carries the real gh output" ;; *) bad "stdout preserved" "got: $out" ;; esac
case "$out" in *gh-sign:*) bad "the note leaked into stdout" "$out" ;; *) ok "...and the note never reaches stdout" ;; esac

: > "$TMP/gh.log"
out="$(GH_ISSUE_JSON="$NOCOM" rd issue view 11 --repo hf7y-estate/space-canon 2>"$TMP/e")"
case "$(cat "$TMP/e")" in
  *"comment(s)"*) bad "warned with no comments" "a note on every read is not read" ;;
  *) ok "an issue with NO comments is silent" ;;
esac

: > "$TMP/gh.log"
out="$(GH_ISSUE_JSON="$ISSUE" rd issue view 11 --repo hf7y-estate/space-canon --json body,comments 2>"$TMP/e")"
case "$(cat "$TMP/e")" in
  *"has 8 comment(s)"*) ok "the note fires even when --json comments was explicitly requested" ;;
  *) bad "quiet when comments requested" "asking is not the same as reading: stderr=$(cat "$TMP/e")" ;;
esac

: > "$TMP/gh.log"
out="$(GH_ISSUE_JSON="$ISSUE" rd pr view 11 --repo hf7y-estate/space-canon 2>"$TMP/e")"
case "$(cat "$TMP/e")" in
  *"hf7y-estate/space-canon#11 has 8 comment(s)"*) ok "\`gh pr view\` gets the same note" ;;
  *) bad "pr view warns" "stderr: $(cat "$TMP/e")" ;;
esac

: > "$TMP/gh.log"
out="$(GH_ISSUE_JSON="$ISSUE" rd issue view 11 --repo hf7y-estate/space-canon --web 2>"$TMP/e")"
case "$(cat "$TMP/e")" in
  *"comment(s)"*) bad "--web still tried to note" "fails open on a selector it does not resolve, not loudly" ;;
  *) ok "\`--web\` passes through unnoted rather than buffering a browser launch" ;;
esac

summary
exit $?
