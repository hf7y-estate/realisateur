#!/usr/bin/env bash
# merge-carry.sh <repo>|<owner>/<repo> -- merge the PRs the PREVIOUS pass over
# this repo opened, then forget them. Called by run-agent.sh before it
# dispatches; safe to run by hand, which is how it was first proven.
#
# Zach, 2026-09-26, choosing between "next night's pass merges", "an interactive
# agent may merge" and "only you merge":
#
#   "Next night's pass merges"
#
# Nothing gates a merge anywhere in the estate -- measured the same day, 0
# required status checks on all 32 repos -- so this bypasses no check that exists.
#
# WHY A LIST AND NOT A QUERY. The PRs cannot be recognised by identity: on the
# six open that day the head commit's committer read `claude-agent` on three,
# `Claude` on one, `test` on another, and every one of them is AUTHORED `hf7y`,
# which is also the identity of Zach's own PRs. Anything matching on author or
# committer eventually merges a human's work. run-agent.sh instead records the
# numbers it opened, partitioned on its own start time, and this merges exactly
# those.
set -uo pipefail

target="${1:?usage: merge-carry.sh <repo>|<owner>/<repo>}"
# A bare name still means hf7y-estate/<name> (#1602); an owner/repo target
# runs against that owner instead. Keyed on the owner only when it isn't the
# default, so the state file for a bare name is unchanged.
case "$target" in
  */*) owner="${target%%/*}"; repo="${target#*/}" ;;
  *)   owner="hf7y-estate"; repo="$target" ;;
esac
key="$repo"; [ "$owner" = hf7y-estate ] || key="${owner}.${repo}"
carry="${AGENT_STATE:-/srv/agent/state}/${key}.prs"
# PRs already given their one update-branch call while RED or CONFLICTING
# (#1596) -- next to carry, pruned to the PRs still held so it cannot grow
# past what merge-carry is actually tracking.
updated="${carry%.prs}.updated"

tok="$(sudo -n cat "${GH_TOKEN_FILE:-/etc/selfdev/gh-token}")"

# A repo with Actions disabled can never clear a FAILURE or a pending check --
# crt measured 2026-10-06 holding 12 PRs forever on `gitleaks`, which cannot
# re-run once Actions is off there (#1587, #1583). Read this once per repo,
# before any PR's statusCheckRollup is trusted, and default to trusting it
# (as before) when the read fails -- an unreadable permission is not a
# license to skip checks.
actions_enabled="$(GH_TOKEN="$tok" gh api "repos/${owner}/${repo}/actions/permissions" \
  --jq .enabled </dev/null 2>/dev/null)" || actions_enabled=""

# ADOPT WHAT THE APP OPENED. The list alone orphans a PR whose pass died before
# writing it down: senechal#1094 sat open with nobody to merge it (a 75-minute
# pass, #1504). Since #1460 every pass's PR is authored by the App, so author
# now separates a pass's work from a person's, which it could not when the list
# was introduced. A listing that fails adopts nothing and the list still runs.
mkdir -p "$(dirname "$carry")"
adopt="$(GH_TOKEN="$tok" gh pr list --repo "${owner}/${repo}" --state open \
  --author "app/${AGENT_APP:-unattended-monkey}" --json number --jq '.[].number' 2>/dev/null)" || adopt=""
{ cat "$carry" 2>/dev/null; printf '%s\n' "$adopt"; } | awk 'NF && !seen[$0]++' > "$carry.new" && mv "$carry.new" "$carry"

[ -s "$carry" ] || exit 0

echo "=== the previous pass's PRs on ${target} ==="
# Actions disabled means statusCheckRollup can never change, so it is dropped
# from the query entirely rather than trusted for RED/PENDING; YOUNG still
# applies since it is about the PR's age, not its checks.
#
# A second line rides every query: the PR's own permission/instruction files,
# named so a GUARDED hold can say which one. Checks say nothing about this --
# a bot PR that edits `.claude/settings.json` or `CLAUDE.md` can be green and
# mergeable and still be unread (#1606).
guardjq='[.files[]?.path]|map(select(. == ".claude/settings.json" or . == ".claude/settings.local.json" or . == "CLAUDE.md" or startswith(".claude/hooks/") or startswith("hooks/")))|join(",")'
if [ "$actions_enabled" = "false" ]; then
  jqf='([.state,(.isDraft|tostring),.mergeable]+(if (.createdAt|fromdateiso8601) > (now - 300) then ["YOUNG"] else [] end)|join(" ")), ('"$guardjq"')'
  note=" -- Actions disabled on ${owner}/${repo}, check records ignored"
else
  jqf='([.state,(.isDraft|tostring),.mergeable]+(if any(.statusCheckRollup[]?; .conclusion=="FAILURE") then ["RED"] elif any(.statusCheckRollup[]?; (.status // "COMPLETED") != "COMPLETED") then ["PENDING"] elif (.createdAt|fromdateiso8601) > (now - 300) then ["YOUNG"] else [] end)|join(" ")), ('"$guardjq"')'
  note=""
fi
keep=""
# A repo's carry file is a stacked chain, oldest first (#1593): a later PR
# can target an earlier one's branch, so merging #3 while #2 is still HELD
# can read MERGEABLE and land, but only onto a branch #1's merge is about to
# delete -- a later line succeeding while an earlier one holds is not "earlier
# links land" in any order a reader can trust. Stop at the first entry that
# does not reach MERGED or DONE this run; every line after it, untried, stays
# on the list for the next pass. Lines already merged earlier in this same
# run are not undone by a later line holding.
mapfile -t entries < "$carry"
for idx in "${!entries[@]}"; do
  n="${entries[$idx]}"
  [ -n "$n" ] || continue
  out="$(GH_TOKEN="$tok" gh pr view "$n" --repo "${owner}/${repo}" \
    --json state,isDraft,mergeable,statusCheckRollup,createdAt,files \
    --jq "$jqf" </dev/null 2>/dev/null)" || out=""
  st="$(printf '%s\n' "$out" | sed -n 1p)"
  guarded="$(printf '%s\n' "$out" | sed -n 2p)"
  # GUARDED wins over every other reading, including a green, mergeable PR:
  # the hold is about WHAT changed, not whether it passed. Checked ahead of
  # the main case below so a mergeable-and-guarded PR never reaches the merge.
  if [ -n "$guarded" ]; then
    echo "  HELD     #${n} -- GUARDED path:${guarded}"
    keep="${keep}${n}"$'\n'
    break
  fi
  case "$st" in
    "OPEN false MERGEABLE")
      if GH_TOKEN="$tok" gh pr merge "$n" --repo "${owner}/${repo}" \
           --merge --delete-branch </dev/null >/dev/null 2>&1; then
        echo "  MERGED   #${n}${note}"
      else
        # A merge that fails is not a merge that was not wanted, so it stays on
        # the list rather than being dropped silently -- and nothing stacked
        # on it is attempted this run either.
        echo "  FAILED   #${n} -- merge refused, kept for the next pass${note}"
        keep="${keep}${n}"$'\n'
        break
      fi ;;
    # RED is a failed check. MERGEABLE only ever meant "no conflict", and
    # realisateur#1440 landed on a failed suite and turned main red.
    # PENDING is a check still running, YOUNG a PR under five minutes old whose
    # checks may not have registered. #1481 and #1482 merged 45s after opening,
    # their suites failed two minutes later, and main was red again (#1516).
    OPEN*)
      # Draft, CONFLICTING, or mergeability not computed yet: all states that can
      # change on their own, so none is a reason to forget the PR.
      case "$st" in
        *CONFLICTING*|*" RED")
          # One real chance to resolve, not every pass (#1596): update-branch
          # is async, so this same pass still reports the state unchanged --
          # the next pass reads whatever resulted and decides fresh.
          if ! grep -qxF "$n" "$updated" 2>/dev/null; then
            GH_TOKEN="$tok" gh api --method PUT \
              "repos/${owner}/${repo}/pulls/${n}/update-branch" </dev/null >/dev/null 2>&1
            printf '%s\n' "$n" >> "$updated"
          fi ;;
      esac
      echo "  HELD     #${n} -- ${st}${note}"
      keep="${keep}${n}"$'\n'
      break ;;
    "")
      echo "  UNREADABLE #${n} -- could not be read, kept and left alone${note}"
      keep="${keep}${n}"$'\n'
      break ;;
    *)
      echo "  DONE     #${n} -- ${st}${note}" ;;
  esac
done
# Everything after the line that stopped the loop was never queried -- not
# MERGED, not DONE, not even looked at -- so it is kept exactly as recorded.
if [ -n "${idx:-}" ]; then
  for ((j = idx + 1; j < ${#entries[@]}; j++)); do
    [ -n "${entries[$j]}" ] && keep="${keep}${entries[$j]}"$'\n'
  done
fi
printf '%s' "$keep" > "$carry"
if [ -s "$updated" ]; then
  grep -xFf <(printf '%s' "$keep") "$updated" > "$updated.new" 2>/dev/null
  mv "$updated.new" "$updated"
fi
