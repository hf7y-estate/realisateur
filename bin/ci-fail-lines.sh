#!/usr/bin/env bash
# ci-fail-lines.sh -- what failed in a CI run, not the whole log (#1140).
#
# `gh run view --log-failed` prints nothing and exits 0 on gh 2.45.0 (the
# Ubuntu noble package -- no newer build exists in that release) even on a
# run with failed jobs. The only reliable read left is the per-job logs API,
# and THAT returns the whole log: one measured run was 2 `##[error]` lines
# and one `FAILED:` line inside 4,582 lines and 347 KB. This greps each
# failed job's log for the three things anyone actually wants, with a little
# leading context, instead of paying that price to find one filename.
#
# A job the API calls "failure" that yields zero matching lines is BLIND,
# never reported as clean -- that silent fold is the defect #1140 is about.
set -uo pipefail

CLI_NAME='ci-fail-lines.sh'
CLI_SUMMARY="a CI run's failure lines, not its whole log"
CLI_USAGE='  ci-fail-lines.sh <run-id> [--repo <owner/repo>]
                                   for every failed job in the run, print its
                                   ##[error] and FAILED: lines (with 3 lines
                                   of leading context). --repo defaults to
                                   this checkout'"'"'s origin.'
CLI_FLAGS='--repo'
CLI_POSITIONAL=run-id
CLI_EXITS='  0  no job failed, or every failed job yielded failure line(s)
  6  BLIND -- a job the API calls failed yielded zero matching lines, or its
     log, or the job list itself, could not be read. NEVER "clean".
  2  usage error'
HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
. "$HERE/lib/cli-guard.sh"
cli_guard "$@"

GH="${CI_FAIL_LINES_GH:-gh}"

RUN=''
REPO=''
while [ $# -gt 0 ]; do
  case "$1" in
    --repo) REPO="${2:?--repo needs owner/repo}"; shift ;;
    -*) cli_die "unknown flag: $1" ;;
    *)
      [ -z "$RUN" ] || cli_die "one run id only (already have $RUN)"
      RUN="$1" ;;
  esac
  shift
done
[ -n "$RUN" ] || cli_die "need a run id"
case "$RUN" in *[!0-9]*) cli_die "run id must be numeric, got: $RUN" ;; esac

if [ -z "$REPO" ]; then
  REPO="$("$GH" repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null)" || REPO=''
  if [ -z "$REPO" ]; then
    printf '%s: BLIND -- no --repo given and none could be read from this checkout\n' "$CLI_NAME" >&2
    exit 6
  fi
fi

jobs="$("$GH" api "repos/$REPO/actions/runs/$RUN/jobs" --paginate \
  --jq '.jobs[] | select(.conclusion=="failure") | [(.id|tostring), .name] | @tsv' 2>/dev/null)"
jobs_rc=$?
if [ "$jobs_rc" -ne 0 ]; then
  printf '%s: BLIND -- could not read the job list for run %s in %s\n' "$CLI_NAME" "$RUN" "$REPO" >&2
  exit 6
fi
if [ -z "$jobs" ]; then
  echo "run $RUN in $REPO: no failed jobs."
  exit 0
fi

blind=0
while IFS=$'\t' read -r id name; do
  [ -n "$id" ] || continue
  log="$("$GH" api "repos/$REPO/actions/jobs/$id/logs" 2>/dev/null)"
  log_rc=$?
  if [ "$log_rc" -ne 0 ]; then
    printf 'BLIND  %s (job %s) is marked failed and its log could not be read\n' "$name" "$id"
    blind=1
    continue
  fi
  lines="$(printf '%s\n' "$log" | grep -nE -B3 '##\[error\]|FAILED:')"
  if [ -z "$lines" ]; then
    total="$(printf '%s\n' "$log" | wc -l)"
    printf 'BLIND  %s (job %s) is marked failed and its log (%s lines) has zero ##[error]/FAILED: lines -- not clean\n' "$name" "$id" "$total"
    blind=1
  else
    printf -- '-- %s (job %s) --\n%s\n' "$name" "$id" "$lines"
  fi
done <<<"$jobs"

[ "$blind" -eq 0 ] && exit 0
exit 6
