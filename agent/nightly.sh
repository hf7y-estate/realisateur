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
passes="${PASSES:-1}"
# --send <passes> <repo|repo#issue>...  THE ONE WAY TO START A RUN BY HAND (#1379). It
# re-runs this same file as one supervised, transient systemd unit, so the run
# is in `systemctl`, in the journal, and killable by name. Zach, 2026-10-01, on
# the 330-character ssh line this replaces: "That incantation proves the
# failure." Nothing else about a sent run differs from the 01:00 one.
if [ "${1:-}" = --send ]; then
  shift
  p="${1:-}"; [ $# -gt 0 ] && shift
  case "$p" in ''|*[!0-9]*) echo "usage: nightly.sh --send <passes> <repo>..." >&2; exit 2 ;; esac
  [ $# -gt 0 ] || { echo "usage: nightly.sh --send <passes> <repo>..." >&2; exit 2; }
  unit="agent-sent-$(date -u +%Y%m%dT%H%M%SZ)"
  echo "sending: $* -- up to $p pass(es) each, as unit $unit"
  exec sudo -n systemd-run --unit="$unit" --uid="$(id -u)" --gid="$(id -g)" \
    --setenv=HOME="$HOME" --setenv=PATH="$PATH" --setenv=PASSES="$p" --setenv=ONLY="$*" \
    "$here/nightly.sh"
fi
only="${ONLY:-}"
list="${REPO_LIST:-$here/repos}"
# The log and the lock live where the dispatch layer does. Named once, and
# overridable, so the suite can run this loop somewhere that is not the host.
dir="${AGENT_DIR:-/srv/agent}"
log="${dir}/nightly.$(date -u +%Y%m%dT%H%M%SZ).log"

# One night at a time. Without this, a pass that outlives its interval gets a
# second container on the same checkout and they fight over the branch.
exec 9>"${dir}/.nightly.lock"
flock -n 9 || { echo "another nightly holds the lock -- exiting"; exit 0; }

exec > >(tee -a "$log") 2>&1
export GH_TOKEN="${GH_TOKEN:-$(sudo -n cat /etc/selfdev/gh-token)}"

echo "=== nightly $(date -u +%FT%TZ)  turns=$turns  list=$list ==="

# THE IMAGE COMES FROM THE REGISTRY, which is what makes a merged
# `agent/Dockerfile` edit the thing tonight runs. `.github/workflows/agent-image.yml`
# builds and pushes it on every merge that touches the Dockerfile; with no pull
# here, `docker run` reuses whatever local copy exists and the merged edit stops
# at the registry -- a file the host can read, not an image the host runs (#1341).
#
# AND A FAILED PULL DISPATCHES NOTHING. Running the local copy instead is how a
# stale or broken image becomes another silent empty night, which is the failure
# the Dockerfile's own `claude --version` line exists to make loud.
export AGENT_IMAGE="${AGENT_IMAGE:-ghcr.io/hf7y-estate/agent:latest}"
sudo -n docker pull "$AGENT_IMAGE" \
  || { echo "=== PULL FAILED: $AGENT_IMAGE -- dispatching nothing ==="; exit 1; }
# By digest, so a night can be tied to the Dockerfile it ran, which `:latest`
# alone cannot say.
digest="$(sudo -n docker image inspect "$AGENT_IMAGE" --format '{{index .RepoDigests 0}}')" \
  && echo "=== image: $digest ===" \
  || echo "=== image: $AGENT_IMAGE -- pulled, digest unreadable ==="
# THE ORG IS THE CANDIDATE SET, not this file (#1383). `agent/repos` keeps
# only order: a repo named there runs where it's placed; a repo the org has
# and that file doesn't still runs, last. Before this, a repo absent from the
# hand list never ran no matter what its queue held -- space-canon sat
# unlisted while #4 and #11 were answered and milestoned, and nobody added
# the repo until it was fixed by hand (#1380).
org_repos="$(gh repo list hf7y-estate --no-archived --limit 1000 --json name --jq '.[].name' 2>&1)" \
  && echo "=== org: $(printf '%s\n' "$org_repos" | grep -c .) non-archived repos ===" \
  || { echo "=== COULD NOT LIST hf7y-estate -- running $list's order only, nothing appended ==="; org_repos=""; }

declare -A in_org=()
if [ -n "$org_repos" ]; then
  while IFS= read -r r; do
    [ -n "$r" ] || continue
    in_org["$r"]=1
  done <<<"$org_repos"
fi

declare -A in_list=()
repos=()
while IFS= read -r r; do
  [ -n "$r" ] || continue
  if [ -n "$org_repos" ] && [ -z "${in_org[$r]:-}" ]; then
    echo "--- $r: in $list but not in the hf7y-estate org -- skipping"
    continue
  fi
  in_list["$r"]=1
  repos+=("$r")
done < <(grep -vE '^\s*(#|$)' "$list")

extra=()
if [ -n "$org_repos" ]; then
  while IFS= read -r r; do
    [ -n "$r" ] || continue
    if [ -z "${in_list[$r]:-}" ]; then
      extra+=("$r")
    fi
  done < <(printf '%s\n' "$org_repos" | sort)
fi
if [ "${#extra[@]}" -gt 0 ]; then
  echo "=== org repos not in $list, appended last: ${extra[*]} ==="
  repos+=("${extra[@]}")
fi

# A SENT RUN NAMES ITS REPOS. The org is still what was listed above; ONLY
# narrows it to what the sender asked for, in the sender's order.
if [ -n "$only" ]; then
  read -ra repos <<<"$only"
  echo "=== sent run: only ${repos[*]} ==="
fi

# THE NIGHT HAS ONE BUDGET, NOT ONE PER REPO (Zach, 2026-10-01: "It shouldn't be
# per-repo at all. It should be ecosystem-wide"). Until something measured sets
# NIGHT_PASSES, the default is the number of repos the hand list names: what a
# night cost before the org became the set, and no more. A sent run is bounded
# by what it was sent with.
if [ -n "$only" ]; then night="${NIGHT_PASSES:-$(( ${#repos[@]} * passes ))}"
else night="${NIGHT_PASSES:-$(grep -cvE '^\s*(#|$)' "$list")}"; fi
spent=0

# The queue predicate: open issues in an open milestone, minus needs-host and
# needs-human. The same one the brief hands the agent below, so a repo that
# gets picked always has something the agent's own read will find too (#1383
# -- Zach: "Nightly should read milestones. That's the failure."). `ERR`, not
# a guess, when either call fails -- an unreadable queue is not an empty one.
queue_count() {
  local repo="$1" ms n
  ms="$(gh api "repos/hf7y-estate/${repo}/milestones?state=open&per_page=100" --jq '[.[].number]' 2>/dev/null)" \
    || { echo ERR; return; }
  n="$(gh issue list --repo "hf7y-estate/${repo}" --state open --limit 200 \
        --search '-label:needs-host -label:needs-human' --json milestone 2>/dev/null \
      | jq --argjson ms "$ms" '[.[] | select(.milestone and (.milestone.number as $m | $ms|index($m)))] | length')" \
    || { echo ERR; return; }
  echo "$n"
}

for target in "${repos[@]}"; do
  # `repo#n` IS A LINK OF A CHAIN: that issue, one pass, in the order it was
  # sent. merge-carry lands the previous link first, so the next one builds on it.
  repo="${target%%#*}"; issue=""
  [ "$repo" = "$target" ] || issue="${target#*#}"
  # BEFORE the queue check, not after it. A repo is skipped below when its queue
  # is empty -- and a queue is empty precisely when the work is already sitting
  # in the previous pass's unmerged PRs, which is the case that most needs them
  # merged. Called here as well as in run-agent.sh because that one never runs
  # for a skipped repo; both calls are idempotent and the second prints nothing.
  "$here/merge-carry.sh" "$repo" || echo "--- $repo: merge-carry.sh exited $?"

  # Do not spend a container on an empty queue. A named issue was sent, not
  # chosen, so the queue is not asked about it.
  n=1
  [ -n "$issue" ] || n="$(queue_count "$repo")"
  case "$n" in
    0)   echo "--- $repo: queue empty, skipping"; continue ;;
    ERR) echo "--- $repo: COULD NOT READ THE QUEUE -- skipping, not guessing"; continue ;;
  esac
  # THE QUEUE IS THE MILESTONE, and PASSES is how far one run drains it. There
  # was a `first` label layered on top: it ordered a queue it could not put an
  # issue into, so five labelled issues with no milestone never ran. Zach,
  # 2026-10-03: "the first tag, along with milestones, feels like layered not
  # replaced." Order is `--send repo#n ...`; the default stays 1 pass.
  i=0
  while :; do
    [ "$spent" -lt "$night" ] || { echo "=== night budget of $night pass(es) spent -- $repo and everything after it waits ==="; break 2; }
    spent=$((spent + 1))
    i=$((i + 1))
    echo "--- $repo: $n runnable, dispatching $(date -u +%FT%TZ) pass $i/$passes${issue:+ issue #$issue}"   # the timestamp stays third: estate-status-collect.py:181 parses this line
    "$here/run-agent.sh" "$repo" "$turns" $issue >/dev/null 2>&1 \
      && echo "--- $repo: pass finished" \
      || echo "--- $repo: pass exited $? (its own log has the reason)"
    [ -z "$issue" ] && [ "$i" -lt "$passes" ] || break
    n="$(queue_count "$repo")"
    case "$n" in 0|ERR) break ;; esac
  done
done

echo "=== nightly done $(date -u +%FT%TZ) ==="
# NOT `select(.author.login|test("claude|agent"))`: run-agent.sh sets
# claude-agent as the COMMITTER, while the PR is authored `hf7y`, the token's
# identity -- so that filter matched nobody and this block printed an empty
# list on every night that opened PRs. Recency is the pass's own artifact.
since="$(date -u -d '12 hours ago' +%FT%TZ)"
echo "=== PRs opened on the estate since ${since} ==="
for repo in $(printf '%s\n' "${repos[@]%%#*}" | awk '!seen[$0]++'); do
  # gh's --jq takes no --arg, so both the cutoff and the repo name are
  # stitched in -- the cutoff into the program, the name onto each line.
  gh pr list --repo "hf7y-estate/$repo" --limit 10 \
    --json number,title,createdAt \
    --jq ".[] | select(.createdAt >= \"$since\") |
       \"#\(.number) \(.createdAt) \(.title)\"" 2>/dev/null \
    | sed "s|^|  $repo |" || true
done
