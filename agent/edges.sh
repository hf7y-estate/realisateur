#!/usr/bin/env bash
# edges.sh list <target> | add <target> <blocker> | rm <target> <blocker>
# -- draw, remove or list ONE blocked-by edge ("target is blocked by blocker").
# Both sides are `repo#n` (owner ${EDGES_OWNER:-hf7y-estate}) or `owner/repo#n`;
# the numeric issue ids the API wants are resolved here (#1561).
#
# WHY IT WALKS. GitHub rejects a direct two-issue cycle and accepted a
# three-issue one (#38 <- #336 <- #1119 <- #38, 2026-10-06), so `add` follows
# blocked_by from the blocker first and writes nothing if it reaches the target.
#
# exit 2 usage   4 rm of an edge that is not there   5 a gh call failed
#      6 could not look (walk passed 200 issues)     7 cycle, refused
set -uo pipefail

usage() { echo "usage: edges.sh list <target> | add|rm <target> <blocker>   (repo#n or owner/repo#n)" >&2; exit 2; }

norm() {  # repo#n | owner/repo#n -> owner/repo#n, lowercased so keys compare
  local r="${1,,}"
  [[ "$r" == */* ]] || r="${EDGES_OWNER:-hf7y-estate}/$r"
  [[ "$r" =~ ^[a-z0-9._-]+/[a-z0-9._-]+#[0-9]+$ ]] && printf '%s\n' "$r"
}
path() { printf 'repos/%s/issues/%s' "${1%#*}" "${1##*#}"; }
call() {  # a failed call names itself and exits 5; it is never an empty answer
  local out
  out="$(gh api "$@" </dev/null)" || { echo "edges: FAILED gh api $*" >&2; exit 5; }
  [ -z "$out" ] || printf '%s\n' "$out"
}
blockers() {  # one `owner/repo#n state` per line
  call "$(path "$1")/dependencies/blocked_by" --paginate \
    --jq '.[] | "\(.repository_url | sub(".*/repos/"; ""))#\(.number) \(.state)"'
}

walk() {  # walk(target, blocker): breadth-first up blocked_by from the blocker
  local target="$1" queue=("$2") i=0 node b list
  declare -A via=(["$2"]="$2")
  while [ "$i" -lt "${#queue[@]}" ]; do
    node="${queue[$i]}"; i=$((i + 1))
    [ "$node" != "$target" ] || { echo "edges: REFUSED, cycle: ${target} <- ${via[$node]}" >&2; exit 7; }
    [ "$i" -le 200 ] || { echo "edges: could not look -- walk passed 200 issues from $2, nothing written" >&2; exit 6; }
    list="$(blockers "$node")" || exit $?
    while read -r b _; do
      b="${b,,}"
      [ -z "$b" ] || [ -n "${via[$b]:-}" ] || { via[$b]="${via[$node]} <- $b"; queue+=("$b"); }
    done <<< "$list"
  done
}

cmd="${1:-}"
t="$(norm "${2:-}")" || usage
case "$cmd $#" in
  "list 2") blockers "$t"; exit ;;
  "add 3"|"rm 3") b="$(norm "$3")" || usage ;;
  *) usage ;;
esac

if [ "$cmd" = add ]; then
  walk "$t" "$b"
  id="$(call "$(path "$b")" --jq .id)" || exit $?
  call -X POST "$(path "$t")/dependencies/blocked_by" -F "issue_id=${id}" >/dev/null
  echo "added   ${t} <- ${b}"
else
  list="$(blockers "$t")" || exit $?
  awk -v b="$b" 'tolower($1) == b { f = 1 } END { exit !f }' <<< "$list" \
    || { echo "edges: ${t} is not blocked by ${b}, nothing removed" >&2; exit 4; }
  id="$(call "$(path "$b")" --jq .id)" || exit $?
  call --method DELETE "$(path "$t")/dependencies/blocked_by/${id}" >/dev/null
  echo "removed ${t} <- ${b}"
fi
blockers "$t"
