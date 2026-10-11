#!/usr/bin/env bash
# decision-sat.sh -- a ruled, unblocked issue that has sat (#1624)
#
# decision-rot.sh asked this LIVENESS question before #1435 retired it along
# with answered.jq's verdict, the marker it read. Nothing replaced it: Zach,
# 2026-10-01 -- "the failure mode is I forget to keep repeating myself and a
# decision rots because it wasn't re-raised by me for the third time.
# Incredibly brittle." Today only Zach notices an issue he already ruled on
# sitting unactioned.
#
# "Ruled" is read the same mechanical way decision-drift.sh already reads it
# (#1066/#497/#1366): a dated `<!-- decision-by: -->` comment. A prose-matched
# dated quote was considered and dropped -- the same "if a change here needs a
# convention INVENTED to work, THE AUDIT IS WRONG" trap decision-rot.sh named,
# now that the estate already has one marker for this and agents write it.
#
# "No open blocker" reads GitHub's native issue-dependency graph
# (`blockedBy`), which this estate already draws edges on (#1391, #1561) --
# not the prose `<!-- DEFERRED -->` ledger, which records what was left
# behind, not what blocks this issue from being worked.
#
# RUNNER: no -- a SURVEY: run in a triage pass, or ahead of /ideate.
# GUARD-TEST: bin/tests/decision-sat.test.sh, offline behind a fake `gh`
# GATE: none -- reads every swept repo's live issue tracker
set -uo pipefail

CLI_NAME='decision-sat.sh'
CLI_SUMMARY='ruled, unblocked issues that have sat N days unactioned'
CLI_USAGE='  decision-sat.sh --all                       every swept repo
  decision-sat.sh <owner>/<repo>             one repo
  decision-sat.sh --all --days 3             only report >= this many days
                                              since the ruling (default: 3)
  decision-sat.sh --all --json               machine-readable NDJSON'
CLI_FLAGS='--all --days --json'
CLI_POSITIONAL=any
CLI_EXITS='  0  clean -- no candidate found
  1  one or more candidates found -- ruled, unblocked, sitting
  2  usage error
  6  BLIND -- a repo could not be read; the count is NOT trustworthy'
HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
. "$HERE/lib/cli-guard.sh"
cli_guard "$@"

. "$HERE/lib/estate-set.sh"
OWNER="${DECISION_SAT_OWNER:-$GH_ESTATE_OWNER}"

MODE=''
REPOS=()
DAYS=3
JSON=0
while [ $# -gt 0 ]; do
  case "$1" in
    --all) MODE=all; shift ;;
    --days) DAYS="${2:?--days needs a number}"; shift 2 ;;
    --json) JSON=1; shift ;;
    */*) MODE=one; REPOS+=("$1"); shift ;;
    *) echo "decision-sat.sh: not an <owner>/<repo>: $1" >&2; exit 2 ;;
  esac
done
if [ -z "$MODE" ]; then
  echo "decision-sat.sh: pass --all or an <owner>/<repo>" >&2
  exit 2
fi
case "$DAYS" in [0-9]*) ;; *) echo "decision-sat.sh: --days must be a non-negative integer, got: $DAYS" >&2; exit 2 ;; esac

if [ "$MODE" = all ]; then
  # shellcheck source=bin/lib/roster-set.sh
  . "$HERE/lib/roster-set.sh"
  for p in "${SWEEP[@]}"; do REPOS+=("$OWNER/$p"); done
fi

command -v gh >/dev/null || { echo "decision-sat.sh: gh not on PATH" >&2; exit 6; }
command -v jq >/dev/null || { echo "decision-sat.sh: jq not on PATH" >&2; exit 6; }

NOW="${DECISION_SAT_NOW:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}"

# Per-repo extraction. The LATEST decision-by comment is the ruling date: a
# reversed or refined ruling (decision-drift.sh's own SAME-ISSUE case) should
# be measured from the newest word, not the first. An issue with any OPEN
# blockedBy node is not yet actionable, so it is not "sitting" -- it is
# waiting on something else this script already knows about.
EXTRACT_JQ='
.[] as $i
| ( [ ($i.comments // [])[] | select((.body // "") | test("<!--\\s*decision-by:")) ]
    | sort_by(.createdAt) ) as $rulings
| select(($rulings | length) > 0)
| ($rulings[-1].createdAt) as $ruled_at
| ( [ ($i.blockedBy.nodes // [])[] | select(.state == "OPEN") ] ) as $open_blockers
| select(($open_blockers | length) == 0)
| { repo: $repo, number: $i.number, title: ($i.title | gsub("\\s+"; " ")),
    ruled_at: $ruled_at,
    days: ((($now | fromdateiso8601) - ($ruled_at | fromdateiso8601)) / 86400 | floor) }
| select(.days >= ($mindays | tonumber))
'

FOUND_FILE="$(mktemp)"
trap 'rm -f "$FOUND_FILE"' EXIT

ERRORS=0
for repo in "${REPOS[@]}"; do
  if ! issues=$(gh issue list --repo "$repo" --state open --limit 500 \
                  --json number,title,comments,blockedBy 2>&1); then
    case "$issues" in
      *"issues are disabled"*|*"Issues are disabled"*) ;;
      *)
        printf 'decision-sat.sh: ERROR reading %s: %s\n' "$repo" "$issues" >&2
        ERRORS=$((ERRORS+1)) ;;
    esac
    continue
  fi
  if ! printf '%s' "$issues" | jq -e 'type == "array"' >/dev/null 2>&1; then
    printf 'decision-sat.sh: ERROR %s returned a non-array (rate limit? token scope?)\n' "$repo" >&2
    ERRORS=$((ERRORS+1)); continue
  fi
  printf '%s' "$issues" | jq -c --arg repo "$repo" --arg now "$NOW" --arg mindays "$DAYS" "$EXTRACT_JQ" \
    >> "$FOUND_FILE" || {
    printf 'decision-sat.sh: ERROR extracting from %s\n' "$repo" >&2
    ERRORS=$((ERRORS+1))
  }
done

N_FOUND="$(jq -s 'length' "$FOUND_FILE")"

if [ "$JSON" = 1 ]; then
  jq -c '.' "$FOUND_FILE"
  jq -cn --argjson repos "${#REPOS[@]}" --argjson found "$N_FOUND" --argjson errors "$ERRORS" --argjson days "$DAYS" \
    '{kind:"summary", repos:$repos, found:$found, errors:$errors, min_days:$days}'
else
  echo "decision-sat.sh: ${#REPOS[@]} repo(s), >= ${DAYS}d since the ruling"
  if [ "$N_FOUND" -gt 0 ]; then
    echo
    echo 'SITTING -- ruled, no open blocker, unactioned:'
    jq -r -s 'sort_by(-.days)[] | "  \(.repo)#\(.number)  ruled \(.ruled_at) (\(.days)d)  \(.title)"' "$FOUND_FILE"
  else
    echo 'clean -- no candidate found'
  fi
fi

if [ "$ERRORS" -gt 0 ]; then
  echo "decision-sat.sh: $ERRORS repo(s) unreadable -- the count above is NOT trustworthy" >&2
  exit 6
fi
[ "$N_FOUND" -gt 0 ] && exit 1
exit 0
