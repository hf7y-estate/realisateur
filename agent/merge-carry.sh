#!/usr/bin/env bash
# merge-carry.sh <repo> -- merge the PRs the PREVIOUS pass over this repo opened,
# then forget them. Called by run-agent.sh before it dispatches; safe to run by
# hand, which is how it was first proven.
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

repo="${1:?usage: merge-carry.sh <repo>}"
carry="${AGENT_STATE:-/srv/agent/state}/${repo}.prs"

[ -s "$carry" ] || exit 0

echo "=== the previous pass's PRs on ${repo} ==="
tok="$(sudo -n cat "${GH_TOKEN_FILE:-/etc/selfdev/gh-token}")"
keep=""
while read -r n; do
  [ -n "$n" ] || continue
  st="$(GH_TOKEN="$tok" gh pr view "$n" --repo "hf7y-estate/${repo}" \
    --json state,isDraft,mergeable \
    --jq '[.state,(.isDraft|tostring),.mergeable]|join(" ")' </dev/null 2>/dev/null)" || st=""
  case "$st" in
    "OPEN false MERGEABLE")
      if GH_TOKEN="$tok" gh pr merge "$n" --repo "hf7y-estate/${repo}" \
           --merge --delete-branch </dev/null >/dev/null 2>&1; then
        echo "  MERGED   #${n}"
      else
        # A merge that fails is not a merge that was not wanted, so it stays on
        # the list rather than being dropped silently.
        echo "  FAILED   #${n} -- merge refused, kept for the next pass"
        keep="${keep}${n}"$'\n'
      fi ;;
    OPEN*)
      # Draft, CONFLICTING, or mergeability not computed yet: all states that can
      # change on their own, so none is a reason to forget the PR.
      echo "  HELD     #${n} -- ${st}"
      keep="${keep}${n}"$'\n' ;;
    "")
      echo "  UNREADABLE #${n} -- could not be read, kept and left alone"
      keep="${keep}${n}"$'\n' ;;
    *)
      echo "  DONE     #${n} -- ${st}" ;;
  esac
done < "$carry"
printf '%s' "$keep" > "$carry"
