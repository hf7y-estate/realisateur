#!/usr/bin/env bash
set -uo pipefail  # repose.sh: declare/check/cancel a timed VM pause (#704) -- monkey-watch.sh's own cron tick fires vmhost_start at `until`, so there is no second scheduler to miss

CLI_NAME='repose'
CLI_SUMMARY='declare, check or cancel a timed pause on a VM host'
CLI_USAGE='  repose <vm> <Nh>       pause <vm> for N hours: savestate now, resume at now+Nh
  repose <vm> --check    dry run: which backend hosts <vm>, and the exact command that would free its RAM
  repose <vm> --status   NONE | PAUSED <until> | EXPIRED <until> | RESUMING <at>
  repose <vm> --cancel   resume <vm> now and clear the declaration'
CLI_FLAGS='--check --status --cancel'
CLI_POSITIONAL=any
CLI_EXITS='  0  declared, reported, or resumed
  1  the VM action failed
  2  usage error'
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/lib/cli-guard.sh"
cli_guard "$@"
. "$HERE/lib/vmhost.sh"

[ $# -ge 1 ] || cli_die "name a vm"
VM="$1"; shift
[ $# -ge 1 ] || cli_die "name a duration (e.g. 2h), --check, --status, or --cancel"

case "$1" in
  --check)  # the dry run: names the backend and prints the actuator verbatim, because "savestate, not pause" is the whole point and it is backend-specific
    vmhost_require "$VM" || exit 2
    printf '%s: %s backend=%s state=%s pause=%s\n' "$CLI_NAME" "$VM" \
      "$(vmhost_backend "$VM")" "$(vmhost_state "$VM")" "$(vmhost_pause_status "$VM" "$(date -u +%Y-%m-%dT%H:%M:%SZ)")"
    printf '%s: would run: %s\n' "$CLI_NAME" "$(vmhost_save_cmd "$VM")"
    ;;
  --status)
    vmhost_pause_status "$VM" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    ;;
  --cancel)  # always tries vmhost_start first: a cleared declaration with the VM still down reads as an unreported outage
    vmhost_require "$VM" || { printf '%s: this must run on the VM host (dexter).\n' "$CLI_NAME" >&2; exit 2; }
    if vmhost_start "$VM"; then
      vmhost_pause_clear "$VM"
      printf '%s: %s resumed, declaration cleared\n' "$CLI_NAME" "$VM"
    else
      printf '%s: vmhost_start %s failed -- declaration left in place\n' "$CLI_NAME" "$VM" >&2
      exit 1
    fi
    ;;
  *)
    case "$1" in [0-9]*h) N="${1%h}" ;; *) N="" ;; esac
    case "$N" in ''|*[!0-9]*) cli_die "duration must look like <N>h (got '$1')" ;; esac
    vmhost_require "$VM" || { printf '%s: this must run on the VM host (dexter).\n' "$CLI_NAME" >&2; exit 2; }
    UNTIL="$(date -u -d "+${N} hours" +%Y-%m-%dT%H:%M:%SZ)" || cli_die "could not compute +${N}h from now"
    # RE-READ, NEVER TRUST THE ACTUATOR'S OWN EXIT CODE. The declaration is what
    # monkey-watch's tick later acts on, so declaring a pause that did not happen
    # leaves the page reading PAUSED for a running host and schedules a resume
    # for a VM that never stopped.
    # `!= running` is NOT the test: `unknown` is the driver failing to look, and
    # accepting it declares a pause on a host nobody can see. Only a state that
    # POSITIVELY says stopped counts -- poweroff (wsl --terminate, or a powered
    # off guest), saved (VirtualBox savestate), paused.
    if vmhost_save "$VM" && { state="$(vmhost_state "$VM")"
         case "$state" in poweroff|saved|paused) true ;; *) false ;; esac; }; then
      vmhost_pause_declare "$VM" "$UNTIL"
      printf '%s: %s paused (state re-read: %s), resumes %s\n' "$CLI_NAME" "$VM" "$state" "$UNTIL"
    else
      printf '%s: %s did NOT pause (state reads %s) -- nothing declared\n' \
        "$CLI_NAME" "$VM" "${state:-unread}" >&2
      exit 1
    fi
    ;;
esac
