#!/usr/bin/env bash
# decision-drift.sh -- do two of Zach's rulings disagree, and does anything
# notice? (#1066)
#
# decision-rot.sh asks LIVENESS: is an answered issue still open? This asks
# CONSISTENCY: does a ruling made this week contradict one made last month?
# Four instances were found only by hand on 2026-09-06 -- hf7y/ecosim#113,
# hf7y/crt#101, hf7y-estate/realisateur#987, hf7y/baudin#42 -- because
# nothing was watching.
#
# TWO CHEAP SIGNALS ONLY, per the trap decision-rot.sh already names ("if a
# change here needs a convention INVENTED to work, THE AUDIT IS WRONG"):
#   A. two or more `<!-- decision-by: -->` comments on the SAME issue -- a
#      refinement or a reversal, worth a human eye either way.
#   B. a `decision-by:` comment that cites another issue whose OWN latest
#      `decision-by:` comment postdates the citation -- the citing ruling may
#      be reading stale state.
# NEITHER IS A VERDICT. This reports candidates for a human to read; whether
# two readings actually disagree is judgement, not a keyword match.
#
# RUNNER: no -- a SURVEY: run in a triage pass, or ahead of /ideate.
# GUARD-TEST: bin/tests/decision-drift.test.sh, offline behind a fake `gh`
# GATE: none -- reads every swept repo's live issue tracker
set -uo pipefail

CLI_NAME='decision-drift.sh'
CLI_SUMMARY='candidate rulings that may disagree with each other'
CLI_USAGE='  decision-drift.sh --all                       every swept repo
  decision-drift.sh <owner>/<repo>             one repo
  decision-drift.sh --all --since 2026-08-01   only comments on/after this
                                                date (default: 2026-08-01)
  decision-drift.sh --all --json               machine-readable NDJSON'
CLI_FLAGS='--all --since --json'
CLI_POSITIONAL=any
CLI_EXITS='  0  clean -- no candidate found
  1  one or more candidates found -- not a contradiction, a thing to read
  2  usage error
  6  BLIND -- a repo could not be read; the count is NOT trustworthy'
HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
. "$HERE/lib/cli-guard.sh"
cli_guard "$@"

. "$HERE/lib/estate-set.sh"
OWNER="${DECISION_DRIFT_OWNER:-$GH_ESTATE_OWNER}"

MODE=''
REPOS=()
SINCE='2026-08-01'
JSON=0
while [ $# -gt 0 ]; do
  case "$1" in
    --all) MODE=all; shift ;;
    --since) SINCE="${2:?--since needs a YYYY-MM-DD date}"; shift 2 ;;
    --json) JSON=1; shift ;;
    */*) MODE=one; REPOS+=("$1"); shift ;;
    *) echo "decision-drift.sh: not an <owner>/<repo>: $1" >&2; exit 2 ;;
  esac
done
if [ -z "$MODE" ]; then
  echo "decision-drift.sh: pass --all or an <owner>/<repo>" >&2
  exit 2
fi
case "$SINCE" in
  [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) ;;
  *) echo "decision-drift.sh: --since must be YYYY-MM-DD, got: $SINCE" >&2; exit 2 ;;
esac

if [ "$MODE" = all ]; then
  # shellcheck source=bin/lib/roster-set.sh
  . "$HERE/lib/roster-set.sh"
  for p in "${SWEEP[@]}"; do REPOS+=("$OWNER/$p"); done
fi

command -v gh >/dev/null || { echo "decision-drift.sh: gh not on PATH" >&2; exit 6; }
command -v jq >/dev/null || { echo "decision-drift.sh: jq not on PATH" >&2; exit 6; }

# Per-repo extraction: every `<!-- decision-by: -->` comment on/after $SINCE,
# with the issues it cites resolved to canonical owner/repo#n. A citation has
# no single grammar the way ANSWERED-BY does (#568) -- a ruling just names an
# issue in prose -- so this reads both spellings the estate's history left
# behind: `hf7y/x#n` from before the org cutover and `hf7y-estate/x#n` since
# (estate-set.sh's GH_ESTATE_HUMAN comment records that cutover). A fenced
# code block is a quotation, not a live citation, same trap answered.jq's
# stale_dates already names -- stripped first.
EXTRACT_JQ='
def refs_in(body; repo):
  ((body // "") | gsub("```(?s:.*?)```"; " ")) as $b
  | ( [$b | scan("[A-Za-z0-9][-A-Za-z0-9_.]*/[A-Za-z0-9][-A-Za-z0-9_.]*#[0-9]+")]
      | map(sub("^hf7y/"; "hf7y-estate/")) ) as $cross
  | ( [ ($b | gsub("[A-Za-z0-9][-A-Za-z0-9_.]*/[A-Za-z0-9][-A-Za-z0-9_.]*#[0-9]+"; " "))
        | scan("#[0-9]+") ] | map(repo + .) ) as $bare
  | ($cross + $bare) | unique;
.[] as $i
| ($i.comments // [])[]
| select((.createdAt // "") >= $since)
| select((.body // "") | test("<!--\\s*decision-by:"))
| { repo: $repo, number: $i.number,
    title: ($i.title | gsub("\\s+"; " ")),
    created_at: .createdAt,
    refs: [ refs_in(.body; $repo + "#")[]
            | select(. != ($repo + "#" + ($i.number | tostring))) ] }
'

RULINGS_FILE="$(mktemp)"
trap 'rm -f "$RULINGS_FILE"' EXIT

ERRORS=0
for repo in "${REPOS[@]}"; do
  if ! issues=$(gh issue list --repo "$repo" --state all --limit 500 \
                  --json number,title,comments 2>&1); then
    case "$issues" in
      *"issues are disabled"*|*"Issues are disabled"*) ;;
      *)
        printf 'decision-drift.sh: ERROR reading %s: %s\n' "$repo" "$issues" >&2
        ERRORS=$((ERRORS+1)) ;;
    esac
    continue
  fi
  if ! printf '%s' "$issues" | jq -e 'type == "array"' >/dev/null 2>&1; then
    printf 'decision-drift.sh: ERROR %s returned a non-array (rate limit? token scope?)\n' "$repo" >&2
    ERRORS=$((ERRORS+1)); continue
  fi
  printf '%s' "$issues" | jq -c --arg repo "$repo" --arg since "$SINCE" "$EXTRACT_JQ" >> "$RULINGS_FILE" || {
    printf 'decision-drift.sh: ERROR extracting rulings from %s\n' "$repo" >&2
    ERRORS=$((ERRORS+1))
  }
done

# Cross-repo aggregation, now every repo's rulings are read into one array.
# $latest maps repo#number -> its own latest decision-by timestamp, so B
# compares a citation against the ONE newest ruling on the cited issue, never
# every ruling newer than the citation (which double-reports the same gap).
AGGREGATE_JQ='
. as $all
| ( ($all | group_by(.repo + "#" + (.number | tostring)))
    | map({key: (.[0].repo + "#" + (.[0].number | tostring)),
           value: (map(.created_at) | max)})
    | from_entries ) as $latest
| {
    same_issue: [ ($all | group_by(.repo + "#" + (.number | tostring)))[]
      | select(length >= 2)
      | (sort_by(.created_at)) as $g
      | { repo: $g[0].repo, number: $g[0].number, title: $g[0].title,
          count: ($g | length), first: $g[0].created_at, last: $g[-1].created_at,
          gap_days: ((($g[-1].created_at | fromdateiso8601)
                      - ($g[0].created_at | fromdateiso8601)) / 86400 | floor) } ],
    stale_citation: [ $all[] as $r
      | ($r.refs // [])[] as $ref
      | ($latest[$ref]? // null) as $cited_latest
      | select($cited_latest != null and $cited_latest > $r.created_at)
      | { citing_repo: $r.repo, citing_number: $r.number, citing_title: $r.title,
          citing_at: $r.created_at, cited: $ref, cited_latest_at: $cited_latest } ]
  }
'

RESULT="$(jq -s "$AGGREGATE_JQ" "$RULINGS_FILE" 2>/dev/null)" || {
  echo "decision-drift.sh: BLIND -- could not aggregate the rulings read" >&2
  exit 6
}

N_SAME="$(printf '%s' "$RESULT" | jq '.same_issue | length')"
N_STALE="$(printf '%s' "$RESULT" | jq '.stale_citation | length')"

if [ "$JSON" = 1 ]; then
  printf '%s' "$RESULT" | jq -c '.same_issue[] | . + {kind:"same-issue"}'
  printf '%s' "$RESULT" | jq -c '.stale_citation[] | . + {kind:"stale-citation"}'
  jq -cn --argjson repos "${#REPOS[@]}" --argjson same_issue "$N_SAME" \
         --argjson stale_citation "$N_STALE" --argjson errors "$ERRORS" \
         '{kind:"summary", repos:$repos, same_issue:$same_issue, stale_citation:$stale_citation, errors:$errors}'
else
  echo "decision-drift.sh: ${#REPOS[@]} repo(s), since $SINCE"
  if [ "$N_SAME" -gt 0 ]; then
    echo
    echo 'SAME-ISSUE -- two or more rulings on one issue (refinement, or reversal):'
    printf '%s' "$RESULT" | jq -r \
      '.same_issue[] | "  \(.repo)#\(.number)  \(.count) rulings, \(.first) .. \(.last) (\(.gap_days)d)  \(.title)"'
  fi
  if [ "$N_STALE" -gt 0 ]; then
    echo
    echo 'STALE CITATION -- a ruling cites an issue whose own later ruling it may not have seen:'
    printf '%s' "$RESULT" | jq -r \
      '.stale_citation[] | "  \(.citing_repo)#\(.citing_number) ruled \(.citing_at) citing \(.cited), whose own latest ruling is \(.cited_latest_at)  \(.citing_title)"'
  fi
  if [ "$N_SAME" -eq 0 ] && [ "$N_STALE" -eq 0 ]; then
    echo 'clean -- no candidate found'
  fi
fi

if [ "$ERRORS" -gt 0 ]; then
  echo "decision-drift.sh: $ERRORS repo(s) unreadable -- the count above is NOT trustworthy" >&2
  exit 6
fi
if [ "$N_SAME" -gt 0 ] || [ "$N_STALE" -gt 0 ]; then
  exit 1
fi
exit 0
