#!/usr/bin/env bash
# rang-selfdev -- rank the self-dev repos by what to work next.
# Answers three questions with three sections: which repo is dispatching into
# nothing, which unblocks the most, which needs vision clarity.
set -euo pipefail

OWNER=${RANG_OWNER:-hf7y}
ROSTER=${RANG_ROSTER:-$HOME/Documents/Projects/scheduler/schedule/ROSTER}
ACTIVE_SINCE=${RANG_ACTIVE_SINCE:-$(date -u -d '30 days ago' +%Y-%m-%d)}

roster_state() { # <repo> -> live|parked|no-row|?
  [ -r "$ROSTER" ] || { echo '?'; return; }
  awk -F'|' -v p="$1" '
    /^[[:space:]]*#/ {next}
    {gsub(/[[:space:]]/,"",$1); gsub(/[[:space:]]/,"",$4)}
    $1==p {print $4; found=1; exit}
    END {if (!found) print "no-row"}' "$ROSTER"
}

tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

# Candidates: every ROSTER row, plus any repo pushed recently with open issues.
{ [ -r "$ROSTER" ] && awk -F'|' '!/^[[:space:]]*#/ && NF>1 {gsub(/[[:space:]]/,"",$1); print $1}' "$ROSTER"
  gh repo list "$OWNER" --limit 200 --no-archived \
     --json name,pushedAt,isArchived \
     --jq ".[]|select(.pushedAt>\"$ACTIVE_SINCE\")|.name"
} | sort -u > "$tmp/repos"

# One GraphQL call for the whole estate.
{ echo 'query {'
  n=0
  while read -r r; do
    n=$((n+1))
    printf '  r%s: repository(owner:"%s", name:"%s") {
      name
      open: issues(states:OPEN) { totalCount }
      human: issues(states:OPEN, labels:["needs-human"]) { totalCount }
      decision: issues(states:OPEN, labels:["needs-decision"]) { totalCount }
      host: issues(states:OPEN, labels:["needs-host"]) { totalCount }
      prs: pullRequests(states:OPEN) { totalCount }
      milestones(states:OPEN, first:25) { nodes { title issues(states:OPEN){ totalCount } } }
    }\n' "$n" "$OWNER" "$r"
  done < "$tmp/repos"
  echo '}'
} > "$tmp/q"

# A ROSTER row naming a repo that does not exist is a finding, not a crash
# (realisateur#1111): GraphQL still returns .data for every row it resolved.
gh api graphql -f query="$(cat "$tmp/q")" > "$tmp/out" 2> "$tmp/err" || true
jq -e '.data' "$tmp/out" >/dev/null 2>&1 || {
  echo "rang-selfdev: GraphQL read FAILED -- no ranking. Do not read this as a quiet estate." >&2
  cat "$tmp/err" >&2; exit 1
}
grep -o "name '[^']*'" "$tmp/err" 2>/dev/null | sort -u \
  | sed 's/^/!! ROSTER names a repo that does not exist: /' >&2 || true

# repo open runnable unmilestoned prs human decision host state topbucket
jq -r '.data | to_entries[] | .value | select(.!=null)
  | (.milestones.nodes | map(.issues.totalCount) | add // 0) as $run
  | (.milestones.nodes | max_by(.issues.totalCount)) as $top
  | [ .name, .open.totalCount, $run, (.open.totalCount-$run),
      .prs.totalCount, .human.totalCount, .decision.totalCount, .host.totalCount,
      (if $top and $top.issues.totalCount>0 then "\($top.issues.totalCount) \($top.title)" else "-" end)
    ] | @tsv' "$tmp/out" > "$tmp/rows"

while IFS=$'\t' read -r name rest; do
  printf '%s\t%s\t%s\n' "$name" "$(roster_state "$name")" "$rest"
done < "$tmp/rows" > "$tmp/t"

[ -r "$ROSTER" ] || echo "!! ROSTER unreadable at $ROSTER -- dispatch state is ? for every row, NOT 'fine'."

echo "== GATE CLOSED: armed, but no open milestone issue -- it dispatches into nothing =="
awk -F'\t' '$2=="live" && $4==0 {printf "  %-16s %s open, 0 runnable\n", $1, $3}' "$tmp/t" | sort || true

echo
echo "== UNBLOCKS MOST: open PRs + human-owned blockers, ranked =="
printf '  %-16s %-8s %5s %5s %5s %5s\n' repo state PRs human decis host
awk -F'\t' '{s=$6+$7+$8+$9; if (s>0) printf "%d\t  %-16s %-8s %5s %5s %5s %5s\n", s, $1, $2, $6, $7, $8, $9}' "$tmp/t" \
  | sort -k1,1nr | cut -f2-

echo
echo "== VISION DEBT: unmilestoned stock, and the biggest single bucket =="
printf '  %-16s %-8s %6s  %s\n' repo state unmiles "largest open milestone"
awk -F'\t' '{if ($5>0 || $10!="-") printf "%d\t  %-16s %-8s %6s  %s\n", $5, $1, $2, $5, $10}' "$tmp/t" \
  | sort -k1,1nr | cut -f2- | head -15
