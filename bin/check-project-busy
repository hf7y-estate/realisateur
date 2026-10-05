#!/usr/bin/env bash
# check-project-busy.sh <project> -- offline-first concurrency guard.
#
# KIND: verb
# Tested by bin/tests/check-project-busy.test.sh; deliberately not declared
# a guard -- this is a front door, and that census is for guards.
#
# One narrow question: is a scheduler-dispatched job OR a human running
# against <project> right now? It gates a DIRECT write into that project's
# tree while its own automation is mid-run -- the same spirit as the "a dirty
# tree is a stop" rule -- the gate is about the tree.
#
# Mechanism, the same two-half lockout as scheduler/lib/registry-lock.sh:
#   job vs job   -- a scheduler job dir holds a sweep.lock (or run.lock), or
#                   the registry's <project>.lock, taken via `flock` for the
#                   run's duration. A non-blocking flock probe answers with no
#                   AI cost and no race window -- no PID files, no mtimes.
#   job vs human -- the registry's <project>.interactive marker, pid-probed
#                   with `kill -0` (#1158): the marker can outlive the session
#                   that wrote it, so its mere existence is not read as busy.
#
# usage and exit codes: `--help`. One source.
set -uo pipefail

CLI_NAME='check-project-busy.sh'
CLI_SUMMARY='is a scheduler-dispatched job running against <project> right now?'
CLI_USAGE='  check-project-busy.sh <project>   probe that project'"'"'s locks; print BUSY or free'
CLI_FLAGS=''
CLI_EXITS='  0  free -- no job holds a lock for that project
  1  BUSY -- a job does, and the row names it
  2  usage error, or a name the scheduler does not register
  6  BLIND -- the project has an account whose job state this caller cannot
     read. Never 0: could-not-look is not not-busy.'
CLI_POSITIONAL=any
. "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib/cli-guard.sh"
cli_guard "$@"

project="${1:?usage: check-project-busy.sh <project>}"
[ "$#" -eq 1 ] || { echo "check-project-busy.sh: takes exactly one project, got $#" >&2; exit 2; }

# A MISSPELLED PROJECT MUST NOT READ AS "free": the safe-looking answer here
# is the permissive one, so an unregistered name returning "free" is a guard
# failing open -- `check-project-busy.sh --not-a-real-flag` once did.
# Host-portability, as in notify-senechal.sh: an absolute /home/zach path made
# EVERY project read on another host as
# unregistered. That direction is at least safe -- it refuses rather than
# answering "free" -- but a guard that refuses everything is no guard.
# THE ROSTER IS HOST-WIDE, NOT A CLONE IN THE CALLER'S HOME (#634). The old
# default read $HOME/Documents/Projects/scheduler -- a clone inside whichever
# account happened to be asking. A /srv/scheduler branch used to sit here as
# the preferred answer; it was the reading half of a provisioner nobody ever
# ran. No such directory exists on monkey, dexter or mandark (measured
# 2026-08-30) and hf7y/scheduler#303 settled the no-checkout dispatch path on
# the release payload, so the branch could not fire and was not going to
# start. SCHED_ROOT stays as the override for a host that keeps it elsewhere.
PROJECTS_ROOT="${INSTALLE_PROJECTS:-$HOME/Documents/Projects}"
SCHED_ROOT="${SCHED_ROOT:-$PROJECTS_ROOT/scheduler}"
if [ ! -f "$SCHED_ROOT/schedule/$project.conf" ]; then
  echo "check-project-busy.sh: '$project' is not a scheduler-registered project" >&2
  echo "  (no $SCHED_ROOT/schedule/$project.conf -- refusing to answer 'free' for a name I cannot check)" >&2
  exit 2
fi
# THE LOCK LIVES IN THE PROJECT'S OWN ACCOUNT, NOT THE CALLER'S. Each account
# holds its own scheduler-registry, so probing $HOME asked "is a job running
# under MY account?" -- always no for anyone else's. On 2026-08-21 this
# reported senechal free while unable to read senechal's lock at all.
BUSY_HOME_ROOT="${BUSY_HOME_ROOT:-/home}"
# Right for the caller's own project; explicit so a test can redirect it.
share_dir="${BUSY_SHARE_DIR:-$HOME/.local/share}"
if [ "$project" != "$(id -un)" ]; then
  owner_share="$BUSY_HOME_ROOT/$project/.local/share"
  if [ -d "$BUSY_HOME_ROOT/$project" ] && [ -r "$owner_share" ] && [ -x "$owner_share" ]; then
    share_dir="$owner_share"
  else
    # COULD-NOT-LOOK IS NOT NOT-BUSY, and NO ACCOUNT HERE IS NOT NOT-BUSY
    # EITHER (#1158): the project's account can be sealed, OR simply not on
    # this host at all -- groc-mangr@monkey has no /home/groc-mangr on
    # mandark, and falling through to the CALLER's own share_dir answered
    # "free" about the wrong host's job state entirely. Both are BLIND, 6.
    echo "check-project-busy.sh: BLIND -- $project's job state is in $owner_share," >&2
    echo "  which this account ($(id -un)) cannot read (no such account on this host," >&2
    echo "  or its home is sealed). Refusing to answer 'free'." >&2
    exit 6
  fi
fi

declare -A INFRA_EXCLUDE=( [scheduler-paced-runner]=1 [scheduler-registry]=1 [scheduler-glance]=1 )

busy=0
shopt -s nullglob

# -- 1. THE CANONICAL PER-PROJECT LOCK ---------------------------------------
registry_dir="$share_dir/scheduler-registry"
reg_lock="$registry_dir/$project.lock"
if [ -f "$reg_lock" ] && ! flock -n "$reg_lock" -c true 2>/dev/null; then
  holder="$(cat "$registry_dir/$project.active" 2>/dev/null || echo 'unknown job')"
  echo "BUSY: $holder"
  busy=1
fi

# -- 1b. JOB vs HUMAN, the other half of the lockout (#1158) -----------------
# scheduler/lib/registry-lock.sh writes this marker and reads it with a PID
# probe, never the file's mere existence (a crash leaves no SessionEnd to
# clean up after it) -- this is the same test, `registry_human_pid`'s reader
# copied so the two cannot drift apart by field name or liveness rule.
interactive="$registry_dir/$project.interactive"
if [ -f "$interactive" ]; then
  human_pid="$(awk -F= '$1=="pid"{print $2}' "$interactive" 2>/dev/null)"
  if [ -n "$human_pid" ] && kill -0 "$human_pid" 2>/dev/null; then
    echo "BUSY: interactive session (pid $human_pid)"
    busy=1
  fi
fi

# -- 2. per-job-dir fallback (pre-registry jobs) ------------------------------
# Skipped when the registry already answered: both sources describe the same
# job, and reporting it twice makes one busy job read like two.
reg_answered="$busy"
for dir in "$share_dir/$project"-*/; do
  [ "$reg_answered" -eq 1 ] && break
  job="$(basename "$dir")"
  [ -n "${INFRA_EXCLUDE[$job]:-}" ] && continue
  lock="$dir/sweep.lock"
  [ -f "$lock" ] || lock="$dir/run.lock"
  [ -f "$lock" ] || continue
  if ! flock -n "$lock" -c true 2>/dev/null; then
    echo "BUSY: $job"
    busy=1
  fi
done

if [ "$busy" -eq 0 ]; then
  echo "free"
  exit 0
fi
exit 1
