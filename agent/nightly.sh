#!/usr/bin/env bash
# nightly.sh -- spawn one agent container per repo, in order, one at a time.
# This is the whole overnight scheduler. There is no pacer, no rotation index,
# no usage gate, no ledger and no ROSTER; the file next to this one is the list
# and `flock` is the concurrency control.
#
# What replaced what:
#   usage-paced-runner.sh 1365 lines  ->  this loop
#   sweep-loop-common.sh  1024 lines  ->  run-agent.sh's docker run
#   usage-gate.sh          409 lines  ->  nothing. A 429 fails one repo's pass
#                                         and the loop moves on. A coordinator
#                                         traded for a retry, deliberately.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
turns="${TURNS:-150}"
list="${REPO_LIST:-$here/repos}"
log="/srv/agent/nightly.$(date -u +%Y%m%dT%H%M%SZ).log"

# One night at a time. Without this, a pass that outlives its interval gets a
# second container on the same checkout and they fight over the branch.
exec 9>/srv/agent/.nightly.lock
flock -n 9 || { echo "another nightly holds the lock -- exiting"; exit 0; }

exec > >(tee -a "$log") 2>&1
export GH_TOKEN="${GH_TOKEN:-$(sudo -n cat /etc/selfdev/gh-token)}"

echo "=== nightly $(date -u +%FT%TZ)  turns=$turns  list=$list ==="
grep -vE '^\s*(#|$)' "$list" | while read -r repo; do
  # BEFORE the queue check, not after it. A repo is skipped below when its queue
  # is empty -- and a queue is empty precisely when the work is already sitting
  # in the previous pass's unmerged PRs, which is the case that most needs them
  # merged. Called here as well as in run-agent.sh because that one never runs
  # for a skipped repo; both calls are idempotent and the second prints nothing.
  "$here/merge-carry.sh" "$repo" || echo "--- $repo: merge-carry.sh exited $?"

  # Do not spend a container on an empty queue. This is the same predicate the
  # brief hands the agent, so a repo that gets picked always has something.
  n=$(gh issue list --repo "hf7y-estate/$repo" --state open --limit 200 \
        --search '-label:needs-host -label:needs-human' --json number --jq 'length' 2>&1) || n=ERR
  case "$n" in
    0)   echo "--- $repo: queue empty, skipping"; continue ;;
    ERR) echo "--- $repo: COULD NOT READ THE QUEUE -- skipping, not guessing"; continue ;;
  esac
  echo "--- $repo: $n runnable, dispatching $(date -u +%FT%TZ)"
  "$here/run-agent.sh" "$repo" "$turns" >/dev/null 2>&1 \
    && echo "--- $repo: pass finished" \
    || echo "--- $repo: pass exited $? (its own log has the reason)"
done

echo "=== nightly done $(date -u +%FT%TZ) ==="
# NOT `select(.author.login|test("claude|agent"))`: run-agent.sh sets
# claude-agent as the COMMITTER, while the PR is authored `hf7y`, the token's
# identity -- so that filter matched nobody and this block printed an empty
# list on every night that opened PRs. Recency is the pass's own artifact.
since="$(date -u -d '12 hours ago' +%FT%TZ)"
echo "=== PRs opened on the estate since ${since} ==="
for repo in $(grep -vE '^\s*(#|$)' "$list"); do
  # gh's --jq takes no --arg, so both the cutoff and the repo name are
  # stitched in -- the cutoff into the program, the name onto each line.
  gh pr list --repo "hf7y-estate/$repo" --limit 10 \
    --json number,title,createdAt \
    --jq ".[] | select(.createdAt >= \"$since\") |
       \"#\(.number) \(.createdAt) \(.title)\"" 2>/dev/null \
    | sed "s|^|  $repo |" || true
done
