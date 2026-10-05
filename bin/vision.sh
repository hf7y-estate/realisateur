#!/usr/bin/env bash
set -uo pipefail  # vision.sh -- one milestone at a time: which states no close, what it holds, and Zach's answer written onto it
#
# KIND: verb
#
# TRAP: `record` carries Zach's words VERBATIM and dated. A paraphrase written
#   here becomes the milestone every later pass is graded against.
# TRAP: `queue` could not look is exit 6, never an empty queue.

CLI_NAME='vision.sh'
CLI_SUMMARY='one milestone at a time: which states no close, what it holds, and the answer written onto it'
CLI_USAGE="  vision.sh queue                      every open milestone, worst first:
                                       kind  open  closed-7d  repo  number  title
  vision.sh card <repo> <number>       title, counts, three open issues, the one question
  vision.sh record <repo> <number> --quote '<his words>'
            [--title '<a sentence true when done>'] [--closes-when '<command or sentence>']
            [--apply]                  default prints the milestone it would write"
CLI_FLAGS='--quote --title --closes-when --apply'
CLI_POSITIONAL=any
CLI_EXITS='  0  printed, or written under --apply
  1  gh refused the write
  2  usage error
  6  BLIND -- the org or the milestone could not be read. NEVER an empty queue.'
HERE="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
. "$HERE/lib/cli-guard.sh"
cli_guard "$@"
. "$HERE/lib/estate-set.sh"
OWNER="${VISION_OWNER:-$GH_ESTATE_OWNER}"
TODAY="${VISION_TODAY:-$(date -u +%F)}"
blind() { echo "BLIND: $*" >&2; exit 6; }

verb="${1:-}"; [ $# -gt 0 ] && shift
case "$verb" in
queue)
  since="$(date -u -d "$TODAY -7 days" +%FT%TZ)"
  # kind: a `CLOSES WHEN:` or `END STATE:` line is the stated close; a backtick
  # on it makes it a command something can run. `none` sorts first, then by
  # where last week's closes went -- spend with no stated close is the debt.
  gh api graphql -f query='{organization(login:"'"$OWNER"'"){repositories(first:100,isArchived:false){nodes{name milestones(states:OPEN,first:30){nodes{number title description open:issues(states:OPEN){totalCount} recent:issues(states:CLOSED,first:100,orderBy:{field:UPDATED_AT,direction:DESC}){nodes{closedAt}}}}}}}}' \
    --jq '[.data.organization.repositories.nodes[] | .name as $r | .milestones.nodes[]
      | ((.description // "") | split("\n") | map(select(test("^(CLOSES WHEN|END STATE):"))) | first) as $w
      | {k:(if $w == null then "none" elif ($w|test("`")) then "command" else "sentence" end),
         o:.open.totalCount, w:([.recent.nodes[]|select(.closedAt >= "'"$since"'")]|length), r:$r, n:.number, t:.title}]
      | sort_by((if .k=="none" then 0 elif .k=="sentence" then 1 else 2 end), -.w, -.o)[]
      | [.k, .o, .w, .r, .n, .t] | @tsv' \
    || blind "could not list $OWNER's milestones"
  ;;
card)
  repo="${1:-}"; n="${2:-}"
  [ -n "$repo" ] && [ -n "$n" ] || cli_die "card needs <repo> <number>"
  m="$(gh api "repos/$OWNER/$repo/milestones/$n" 2>/dev/null)" || blind "could not read $OWNER/$repo milestone $n"
  jq -r '"\(.title)\n  open \(.open_issues)  closed \(.closed_issues)\n\n\((.description // "(no description)") | split("\n")[:6] | join("\n"))\n"' <<<"$m"
  # Three that span it: the oldest, the most argued over, the newest.
  gh api "repos/$OWNER/$repo/issues?milestone=$n&state=open&per_page=100" \
    --jq '[.[]|select(.pull_request|not)] | sort_by(.created_at) | [first, (.[1:-1] | max_by(.comments)), last] | map(select(.)) | unique_by(.number)[]
          | "  #\(.number)  \(.created_at[:10])  \(.comments) comment(s)  \(.title)"' \
    || blind "could not list $OWNER/$repo milestone $n's issues"
  printf '\nWhat is true when this is done?\n'
  ;;
record)
  repo="${1:-}"; n="${2:-}"; [ $# -ge 2 ] && shift 2
  quote=''; title=''; when=''; apply=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --quote)       quote="${2:?--quote needs his words}"; shift ;;
      --title)       title="${2:?--title needs a sentence}"; shift ;;
      --closes-when) when="${2:?--closes-when needs a command or a sentence}"; shift ;;
      --apply)       apply=1 ;;
      *) cli_die "record: unexpected $1" ;;
    esac
    shift
  done
  [ -n "$repo" ] && [ -n "$n" ] && [ -n "$quote" ] || cli_die "record needs <repo> <number> --quote '<his words>'"
  m="$(gh api "repos/$OWNER/$repo/milestones/$n" 2>/dev/null)" || blind "could not read $OWNER/$repo milestone $n"
  old_title="$(jq -r .title <<<"$m")"
  body="$(printf 'Zach, %s (realisateur `/ideate`), verbatim:\n\n> %s\n' "$TODAY" "$quote"
          [ -z "$when" ] || printf '\nCLOSES WHEN: %s\n' "$when"
          printf '\nWas: "%s"\n\n' "$old_title"; jq -r '.description // ""' <<<"$m")"
  printf '%s\n\n%s\n' "${title:-$old_title}" "$body"
  [ "$apply" -eq 1 ] || { printf '\n(not written -- re-run with --apply)\n'; exit 0; }
  gh api -X PATCH "repos/$OWNER/$repo/milestones/$n" -f title="${title:-$old_title}" -f description="$body" --jq '"written: \(.html_url)"' || exit 1
  ;;
*) cli_die "expected queue, card or record" ;;
esac
