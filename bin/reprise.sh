#!/usr/bin/env bash
# reprise.sh -- collect the files whose owner has actually received them.
#
# NOT A VERB, deliberately (bin/lib/not-a-verb.tsv's test, Zach 2026-08-11:
# "would another agent or Zach ever call one of those?"). Nobody types
# `reprise`; --apply opens its own PR. It is LOCAL
# in bin/lib/propagation-set.sh -- it acts on THIS repo's handoff table, so
# shipping it to twelve accounts would give each one a tool with nothing to do.
# RUNNER: no -- its runner, the `handoff` probe of ausculte.sh, was deleted (#1273); nothing has run this since 2026-09-17 (#1274)
# GUARD-TEST: bin/tests/reprise.test.sh
# GATE: none -- `--check` reports and `--apply` opens a PR a human merges. It
#   deletes nothing that is not already present at its destination, so there is
#   no invocation of this that can gate a build or block a branch.
#
# TRAP: a MERGED pr is not a delivery. The witness is the file's presence on
#   the receiving repo's DEFAULT BRANCH; merged-but-absent is a failure that
#   deletes nothing, because #368's rule is that a file removed here before it
#   exists there is an outage.
# TRAP: it never pushes `main` (CLAUDE.md) -- --apply builds a branch and a PR.
set -uo pipefail

CLI_NAME='reprise'
CLI_SUMMARY='delete the files whose receiving PR has merged AND landed'
CLI_USAGE='  reprise             what is collectable, and what is owed (default)
  reprise --check     the same; writes nothing
  reprise --apply     open one PR removing every collectable path'
CLI_FLAGS='--check --apply'
CLI_EXITS='  0  the table was read; nothing is owed, or --apply opened the PR
  1  a receiving PR merged but its file is NOT on the destination branch
  2  usage error
  6  BLIND: no table, no gh, or a repo that could not be read'
CLI_POSITIONAL=none
# readlink -f: a verb is a symlink; without this the guard silently misses.
. "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib/cli-guard.sh"
cli_guard "$@"

HERE="${REPRISE_REPO:-$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)}"
TABLE="${REPRISE_TABLE:-$HERE/bin/lib/handoffs.tsv}"

blind() { printf '%s: BLIND: %s\n' "$CLI_NAME" "$*" >&2; exit 6; }

MODE=--check
for a in "$@"; do
  case "$a" in
    --check|--apply) MODE="$a" ;;
    -h|--help) printf '%s -- %s\nusage:\n%s\n' "$CLI_NAME" "$CLI_SUMMARY" "$CLI_USAGE"; exit 0 ;;
  esac
done

[ -r "$TABLE" ] || blind "no handoff table at $TABLE"
command -v gh >/dev/null 2>&1 || blind "gh is not on PATH -- cannot ask whether anything merged"

# `gh api` per row, not one search: a search that rate-limits returns [] and an
# empty result reads exactly like "nothing merged", which would silently mean
# "collect nothing" forever. A per-row 404 is loud.
collect=(); owed=0; bad=0; rows=0
while IFS=$'\t' read -r here repo pr there; do
  case "$here" in ''|'#'*) continue ;; esac
  # COUNT IT BEFORE VALIDATING IT. A malformed row is still a row: counting it
  # after the `continue` left rows=0 for a table of nothing but bad rows, and
  # the "no handoffs outstanding" shortcut below then exited 0 over a table
  # this script had just refused to read.
  rows=$((rows + 1))
  [ -n "${there:-}" ] || { printf '%s: FAIL: %s names no destination path\n' "$CLI_NAME" "$here" >&2; bad=1; continue; }
  merged="$(gh api "repos/$repo/pulls/$pr" --jq '.merged' 2>/dev/null)" \
    || { printf '%s: BLIND: could not read %s#%s\n' "$CLI_NAME" "$repo" "$pr" >&2; blind "the tracker did not answer for $repo#$pr"; }
  if [ "$merged" != true ]; then
    printf '  OWED   %-44s %s#%s not merged\n' "$here" "$repo" "$pr"
    owed=$((owed + 1)); continue
  fi
  # THE SECOND HALF, and the whole reason this is not `gh pr view --json merged`.
  if gh api "repos/$repo/contents/$there" --jq '.sha' >/dev/null 2>&1; then
    printf '  LANDED %-44s %s:%s\n' "$here" "$repo" "$there"
    [ -e "$HERE/$here" ] && collect+=("$here")
  else
    printf '  FAIL   %-44s %s#%s MERGED but %s is not on the default branch\n' \
      "$here" "$repo" "$pr" "$there" >&2
    printf '         deleting here would leave it in neither repo. Nothing collected.\n' >&2
    bad=1
  fi
done < "$TABLE"

[ "$rows" -gt 0 ] || { printf '%s: no handoffs outstanding\n' "$CLI_NAME"; exit 0; }
[ "$bad" -eq 0 ] || exit 1
printf '%s: %d row(s): %d collectable, %d owed\n' "$CLI_NAME" "$rows" "${#collect[@]}" "$owed"
[ "${#collect[@]}" -gt 0 ] || exit 0
[ "$MODE" = --apply ] || { printf '%s: NOT collected (need --apply)\n' "$CLI_NAME"; exit 0; }

cd "$HERE" || blind "cannot enter $HERE"
BRANCH="reprise-$(git rev-parse --short HEAD)"
git checkout -q -B "$BRANCH" origin/main || blind "could not branch from origin/main"
git rm -q -- "${collect[@]}" || blind "could not remove the collected paths"
# The table's rows go with the files they describe: a row whose subject is gone
# would make every later run re-report a delivery already taken.
for c in "${collect[@]}"; do
  grep -v "^$c	" "$TABLE" > "$TABLE.new" && mv "$TABLE.new" "$TABLE"
done
git add "$TABLE"
{
  printf 'reprise: collect %d file(s) their owner has received\n\n' "${#collect[@]}"
  printf 'Each path below is gone from a receiving PR that MERGED and whose file\n'
  printf 'is present on that repo'"'"'s default branch. Both halves were checked;\n'
  printf 'a merge alone would not have been enough (#368).\n\n'
  printf '%s\n' "${collect[@]}" | sed 's/^/  /'
  printf '\n<!-- DELIVERS -->\n- none\n<!-- /DELIVERS -->\n'
} > "$HERE/.reprise-msg"
git commit -q -F "$HERE/.reprise-msg" && rm -f "$HERE/.reprise-msg"
git push -q -u origin "$BRANCH" || blind "could not push $BRANCH"
gh pr create --title "reprise: collect ${#collect[@]} file(s) their owner has received" \
  --body "$(printf 'NO-DECISION: mechanical collection; every path was witnessed at its destination\n\nOpened by `reprise --apply` from bin/lib/handoffs.tsv. See the commit body.\n\n<!-- DEFERRED -->\n- none\n<!-- /DEFERRED -->\n\n<!-- DELIVERS -->\n- none\n<!-- /DELIVERS -->\n')"
