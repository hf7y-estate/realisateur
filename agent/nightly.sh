#!/usr/bin/env bash
# nightly.sh -- spawn one agent container per repo, in order, one at a time.
# This is the whole overnight scheduler. There is no pacer, no rotation index,
# no usage gate, no ledger, no ROSTER and no hand list; the org is the list,
# the pass logs are the order, and `flock` is the concurrency control.
#
# What replaced what:
#   usage-paced-runner.sh  ->  this loop
#   sweep-loop-common.sh   ->  run-agent.sh's docker run
#   usage-gate.sh          ->  nothing. A 429 fails a repo's pass and the loop
#                              moves on. A coordinator traded for a retry,
#                              deliberately.
set -Eeuo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
turns="${TURNS:-150}"
passes="${PASSES:-1}"
# --send <passes> <target>...  THE ONE WAY TO START A RUN BY HAND (#1379). A
# target is <repo>, <repo>#<issue>, <owner>/<repo> or <owner>/<repo>#<issue>
# (#1602) -- a bare name still means hf7y-estate/<repo>. It
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
    --setenv=HOME="$HOME" --setenv=PATH="$PATH" --setenv=PASSES="$p" --setenv=ONLY="$*" ${TURNS:+--setenv=TURNS="$TURNS"} \
    "$here/nightly.sh"
fi
only="${ONLY:-}"
# The log and the lock live where the dispatch layer does. Named once, and
# overridable, so the suite can run this loop somewhere that is not the host.
dir="${AGENT_DIR:-/srv/agent}"
log="${dir}/nightly.$(date -u +%Y%m%dT%H%M%SZ).log"

# One night at a time. Without this, a pass that outlives its interval gets a
# second container on the same checkout and they fight over the branch.
#
# A SENT RUN DOES NOT TAKE IT (Zach, 2026-10-03: "15 minute timer, spawn new
# ones on timer"). Chains on different repos run side by side, and a chain no
# longer makes the 01:00 night exit 0 having run nothing. What must not overlap
# is two containers on ONE checkout, so that lock is per repo and sits on the
# pass itself, below.
if [ -z "$only" ]; then
  exec 9>"${dir}/.nightly.lock"
  flock -n 9 || { echo "another nightly holds the lock -- exiting"; exit 0; }
fi

exec > >(tee -a "$log") 2>&1
export GH_TOKEN="${GH_TOKEN:-$(sudo -n cat /etc/selfdev/gh-token)}"

echo "=== nightly $(date -u +%FT%TZ)  turns=$turns ==="

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
# THE ORG IS THE CANDIDATE SET (#1383) AND THE PASS LOGS ARE THE ORDER (#1476).
# There was a hand list, `agent/repos`, layered on top: it ordered the repos it
# named, the rest went last in name order, and the budget was its line count --
# so every night restarted at the top and the tail never ran. apms-2173 held 14
# runnable issues and got no pass from 2026-10-05 to 2026-10-09. Zach,
# 2026-10-09: "the old agents/repos folder thing makes no sense seems like a
# layered not replaced failure". Now: whoever was passed longest ago goes
# first, a repo never passed goes before all of them, and a foreign-owner repo
# runs by `--send owner/repo` (#1602).
#
# AN UNREADABLE ORG DISPATCHES NOTHING, and exits 1 so cron says so: with no
# hand list there is no order to fall back to.
# A SENT RUN NAMES ITS REPOS, in the sender's order, and asks the org nothing.
if [ -n "$only" ]; then
  read -ra repos <<<"$only"
  echo "=== sent run: only ${repos[*]} ==="
else
  org_repos="$(gh repo list hf7y-estate --no-archived --limit 1000 --json name --jq '.[].name')" \
    && [ -n "$org_repos" ] \
    || { echo "=== COULD NOT LIST hf7y-estate -- dispatching nothing ==="; exit 1; }
  repos=()
  while read -r _ r; do repos+=("$r"); done < <(
    while IFS= read -r r; do
      last="$(ls "${dir}/${r}".[0-9]*Z.log 2>/dev/null | tail -1 || true)"; last="${last%.log}"
      printf '%s %s\n' "${last:+${last##*.}}" "$r"
    done <<<"$org_repos" | sed 's/^ /0 /' | sort)
  echo "=== org: ${#repos[@]} non-archived repos, oldest pass first: ${repos[*]} ==="
fi

# THE NIGHT HAS ONE BUDGET, NOT ONE PER REPO (Zach, 2026-10-01: "It shouldn't be
# per-repo at all. It should be ecosystem-wide"). 13 is what a night cost when
# the hand list set it, kept so removing the list changes the order and not the
# spend; #1476 replaces the number with the gate. A sent run is bounded by what
# it was sent with.
if [ -n "$only" ]; then night="${NIGHT_PASSES:-$(( ${#repos[@]} * passes ))}"
else night="${NIGHT_PASSES:-13}"; fi
spent=0

# The queue predicate: open issues in an open milestone, minus needs-host and
# needs-human. The same one the brief hands the agent below, so a repo that
# gets picked always has something the agent's own read will find too (#1383
# -- Zach: "Nightly should read milestones. That's the failure."). `ERR`, not
# a guess, when either call fails -- an unreadable queue is not an empty one.
queue_count() {
  local owner="$1" repo="$2" ms n
  ms="$(gh api "repos/${owner}/${repo}/milestones?state=open&per_page=100" --jq '[.[].number]' 2>/dev/null)" \
    || { echo ERR; return; }
  n="$(gh issue list --repo "${owner}/${repo}" --state open --limit 200 \
        --search '-label:needs-host -label:needs-human' --json milestone 2>/dev/null \
      | jq --argjson ms "$ms" '[.[] | select(.milestone and (.milestone.number as $m | $ms|index($m)))] | length')" \
    || { echo ERR; return; }
  echo "$n"
}

# A LOCKED REPO GETS ONE REQUEUE, NOT A WAIT. `.pass.<repo>.lock` is the
# per-repo lock named above -- a sent chain on the same repo holds it too --
# and blocking on it here is how one long sent pass stalled the whole night
# behind it (#1476). `flock -n` fails fast instead, with `-E 254` so "the
# lock was held" cannot be confused with run-agent.sh's own exit codes; the
# repo goes to the back of the queue once and is skipped for the night if it
# is still held on the second try.
declare -A relocked=()
repo_i=0
while [ "$repo_i" -lt "${#repos[@]}" ]; do
  target="${repos[$repo_i]}"; repo_i=$((repo_i + 1))
  # `repo#n` IS A LINK OF A CHAIN: that issue, one pass, in the order it was
  # sent. merge-carry lands the previous link first, so the next one builds on it.
  label="${target%%#*}"; issue=""
  [ "$label" = "$target" ] || issue="${target#*#}"
  # A bare name still means hf7y-estate/<name> (#1602): the automatic org
  # listing above stays hf7y-estate only, but a line or a --send target that
  # names its own owner runs against that owner, undiscovered.
  case "$label" in
    */*) owner="${label%%/*}"; repo="${label#*/}" ;;
    *)   owner="hf7y-estate"; repo="$label" ;;
  esac
  # Keyed so two orgs with a same-named repo cannot share a lock or a log;
  # identical to the bare name for the default owner, so nothing that runs
  # today changes.
  key="$repo"; [ "$owner" = hf7y-estate ] || key="${owner}.${repo}"
  # A SILENT KILL HERE NAMES ITSELF (#1649): a `var=$(cmd)` whose cmd fails
  # exits under `set -e` with NO output at all -- not even the dispatch line
  # -- because the failure is in the assignment, not in anything already
  # wrapped with `||`. Measured 2026-10-07 on a sent run: eleven seconds,
  # through merge-carry.sh, dead before `--- <repo>: ... dispatching`, nothing
  # said why. This trap is the net for that and anything shaped like it
  # between here and the dispatch line below; it does not fire on the two
  # failures already handled with their own `||` (merge-carry.sh, etiquette.sh).
  trap 'echo "--- $label: failed before dispatch (exit $?, line $LINENO) -- the last line above this one is what ran" >&2' ERR
  # BEFORE the queue check, not after it. A repo is skipped below when its queue
  # is empty -- and a queue is empty precisely when the work is already sitting
  # in the previous pass's unmerged PRs, which is the case that most needs them
  # merged. Called here as well as in run-agent.sh because that one never runs
  # for a skipped repo; both calls are idempotent and the second prints nothing.
  "$here/merge-carry.sh" "$label" || echo "--- $label: merge-carry.sh exited $?"

  # Do not spend a container on an empty queue. A named issue was sent, not
  # chosen, so the queue is not asked about it.
  # THE EXECUTOR `DEFAULT-AFTER` NEVER HAD (#1410). The label is what keeps an
  # issue out of the queue below, and nothing on any clock re-derived it.
  "$(dirname "$(readlink -f "$here/run-agent.sh")")/../bin/etiquette.sh" "$owner/$repo" --apply 2>&1 \
    | grep -E '^ +[-+]label|REFUSED|BLIND' || true
  n=1
  [ -n "$issue" ] || n="$(queue_count "$owner" "$repo")"
  trap - ERR
  case "$n" in
    0)   echo "--- $label: queue empty, skipping"; continue ;;
    ERR) echo "--- $label: COULD NOT READ THE QUEUE -- skipping, not guessing"; continue ;;
  esac
  # THE QUEUE IS THE MILESTONE, and PASSES is how far one run drains it. There
  # was a `first` label layered on top: it ordered a queue it could not put an
  # issue into, so five labelled issues with no milestone never ran. Zach,
  # 2026-10-03: "the first tag, along with milestones, feels like layered not
  # replaced." Order is `--send repo#n ...`; the default stays 1 pass.
  i=0
  locked=0
  while :; do
    [ "$spent" -lt "$night" ] || { echo "=== night budget of $night pass(es) spent -- $label and everything after it waits ==="; break 2; }
    spent=$((spent + 1))
    i=$((i + 1))
    echo "--- $label: $n runnable, dispatching $(date -u +%FT%TZ) pass $i/$passes${issue:+ issue #$issue}"   # the timestamp stays third: estate-status-collect.py:181 parses this line
    flock -n -E 254 "${dir}/.pass.${key}.lock" "$here/run-agent.sh" "$label" "$turns" $issue >/dev/null 2>&1 && rc=0 || rc=$?
    case "$rc" in
      0) echo "--- $label: pass finished" ;;
      # 254 is flock -n refusing the lock, not a run-agent.sh exit: another
      # chain holds this repo's pass. Give the budget back -- nothing ran --
      # and try the rest of the night before coming back to it once.
      254) spent=$((spent - 1)); i=$((i - 1)); locked=1
           echo "--- $label: locked by another chain, not waiting -- deferring"
           break ;;
      # 3 is run-agent.sh refusing to run as hf7y. The mint is per host, not per
      # repo, so every later pass would refuse too: stop, and tell a person once.
      3) echo "=== NO BOT TOKEN: $label refused, dispatching nothing more ==="
         ( . "$(dirname "$(readlink -f "$here/run-agent.sh")")/../bin/lib/zaxon.sh" \
             && zaxon_send "nightly stopped on dexter: no bot token, nothing dispatched" nightly ) || true
         break 2 ;;
      *) echo "--- $label: pass exited $rc (its own log has the reason)" ;;
    esac
    [ -z "$issue" ] && [ "$i" -lt "$passes" ] || break
    n="$(queue_count "$owner" "$repo")"
    case "$n" in 0|ERR) break ;; esac
  done
  if [ "$locked" -eq 1 ]; then
    if [ -z "${relocked[$target]:-}" ]; then
      relocked[$target]=1
      echo "--- $label: back of the queue for one retry this night"
      repos+=("$target")
    else
      echo "--- $label: still locked on retry -- skipping for the rest of the night"
    fi
  fi
done

echo "=== nightly done $(date -u +%FT%TZ) ==="
# NOT `select(.author.login|test("claude|agent"))`: run-agent.sh sets
# claude-agent as the COMMITTER, while the PR is authored `hf7y`, the token's
# identity -- so that filter matched nobody and this block printed an empty
# list on every night that opened PRs. Recency is the pass's own artifact.
since="$(date -u -d '12 hours ago' +%FT%TZ)"
echo "=== PRs opened on the estate since ${since} ==="
for pr_label in $(printf '%s\n' "${repos[@]%%#*}" | awk '!seen[$0]++'); do
  case "$pr_label" in
    */*) pr_owner="${pr_label%%/*}"; pr_repo="${pr_label#*/}" ;;
    *)   pr_owner="hf7y-estate"; pr_repo="$pr_label" ;;
  esac
  # gh's --jq takes no --arg, so both the cutoff and the repo name are
  # stitched in -- the cutoff into the program, the name onto each line.
  gh pr list --repo "$pr_owner/$pr_repo" --limit 10 \
    --json number,title,createdAt \
    --jq ".[] | select(.createdAt >= \"$since\") |
       \"#\(.number) \(.createdAt) \(.title)\"" 2>/dev/null \
    | sed "s|^|  $pr_label |" || true
done
