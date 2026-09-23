#!/usr/bin/env bash
set -uo pipefail
#
# arret.sh -- the stop switch, and the thing to reach for before any window
# that takes a host down (a VHDX compact, a reboot, a distro migration).
#
# KIND: verb -- Zach types it, and so does an agent that needs the fleet still
# RUNNER: no -- it is a front door, never on a clock. Nothing schedules a stop.
# GUARD-TEST: bin/tests/arret.test.sh, offline behind a stubbed ssh
# GATE: none. The survey is read-only; --stop and --start need passwordless
#   sudo on each host and verify by RE-READING, never by the exit code of the
#   command they just sent.
# TRAP: a stop leaves no deadline behind it. Nothing restarts these clocks but
#   `arret --start`, and a fleet with cron down looks exactly like a fleet with
#   nothing to do -- see the survey's `armed BLIND` row for the same shape one
#   level down.

CLI_NAME='arret'
CLI_SUMMARY="Zach's stop switch for self-dev: what is running, and stop it"
CLI_USAGE='  arret                  survey only: what is dispatching, on every host, right now
  arret --stop           stop the CLOCKS: no new dispatch anywhere. Running work finishes.
  arret --stop --now     ...and terminate the agents already running. Work in flight dies.
  arret --start          undo --stop: the clocks run again

  arret --down --host H  a WINDOW: stop the clocks on H, then terminate the distro.
  arret --down --host H --compact
                         ...and make its disk sparse while it is down, so space
                         freed inside it returns to the Windows volume.
  arret --up   --host H  boot the distro, wait for sshd, start the clocks again
  arret --up   --host H --clocks-off
                         ...but leave dispatch off: the host and its CI runners
                         come back, nothing is dispatched until --start

  --host <h>   just one of: monkey vaporwave
  --yes        skip the confirmation prompt'
CLI_FLAGS='--stop --start --now --down --up --compact --clocks-off --host --yes'
CLI_POSITIONAL=none
CLI_EXITS='  0  surveyed, or the action was applied and re-read
  1  a host could not be reached, or a stop did not verify on re-read
  2  usage error'

HOSTS="${ARRET_HOSTS:-monkey vaporwave}"
# The machine that DRIVES the distros: monkey and vaporwave are WSL2 distros on
# dexter, so their power switch is reached through dexter's interop, never from
# inside the distro being stopped.
VMHOST_SSH="${ARRET_VMHOST_SSH:-dexter}"
DOCKER_HOST_SSH="${ARRET_DOCKER_HOST:-dexter}"
SSH="${ARRET_SSH:-ssh}"
SSH_OPTS="${ARRET_SSH_OPTS:--o BatchMode=yes -o ConnectTimeout=10}"
# NEVER STOPPED BY THIS TOOL. zaxon is the only channel that reaches Zach, so a
# stop that kills it cannot report that it worked; roster is the arming
# authority every dispatcher reads, and a blind roster is worse than an armed
# one. Listed, marked, and left alone -- `docker stop` them by hand if you mean it.
PROTECTED='zaxon-relay zaxon-gateway zaxon-watcher roster'

MODE=survey; NOW=0; ONE=''; YES=0; COMPACT=0; CLOCKS_OFF=0
while [ $# -gt 0 ]; do
  case "$1" in
    --stop)  MODE=stop ;;
    --start) MODE=start ;;
    --down)  MODE=down ;;
    --up)    MODE=up ;;
    --compact) COMPACT=1 ;;
    --clocks-off) CLOCKS_OFF=1 ;;
    --now)   NOW=1 ;;
    --host)  ONE="${2:?--host needs a name}"; shift ;;
    --yes)   YES=1 ;;
    -h|--help) printf '%s -- %s\n\nusage:\n%s\n\nexits:\n%s\n' "$CLI_NAME" "$CLI_SUMMARY" "$CLI_USAGE" "$CLI_EXITS"; exit 0 ;;
    *) printf '%s: unknown argument: %s\n' "$CLI_NAME" "$1" >&2; exit 2 ;;
  esac
  shift
done
[ -n "$ONE" ] && HOSTS="$ONE"

case "$MODE" in
  down|up)
    # ONE HOST, NAMED. --stop across the fleet is recoverable in a second; a
    # fleet-wide `--terminate` is an outage, and "every host" is never what
    # someone means by it.
    [ -n "$ONE" ] || { printf '%s: --%s needs --host <name>. Taking every distro down at once is not a thing this offers.\n' "$CLI_NAME" "$MODE" >&2; exit 2; }
    [ "$ONE" = "$VMHOST_SSH" ] && { printf '%s: %s IS the machine that drives the distros. Terminating it from inside itself is the route out, gone.\n' "$CLI_NAME" "$ONE" >&2; exit 2; }
    # shellcheck source=bin/lib/vmhost.sh
    . "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib/vmhost.sh"
    # The DRIVERS live on the VM host, not here, so detection cannot see them
    # and every call below only PRINTS a command for the far side to run.
    VMHOST_BACKEND="${VMHOST_BACKEND:-wsl}"
    ;;
esac
[ "$COMPACT" = 1 ] && [ "$MODE" != down ] && { printf '%s: --compact only means something with --down: the disk cannot be made sparse while the distro is using it.\n' "$CLI_NAME" >&2; exit 2; }
[ "$CLOCKS_OFF" = 1 ] && [ "$MODE" != up ] && { printf '%s: --clocks-off only means something with --up. To stop clocks that are running, that is --stop.\n' "$CLI_NAME" >&2; exit 2; }

# shellcheck disable=SC2086  # SSH_OPTS is a flag STRING and must word-split
sshx() { local h="$1"; shift; timeout 45 $SSH $SSH_OPTS "$h" "$@" 2>/dev/null; }

# The runner a dispatch tick actually execs. Matched by its cron TAG, not by the
# word "scheduler": sync-crontab.sh also runs out of the scheduler clone and
# arms nothing (bin/monkey-status-collect.py says the same about dispatch_line).
RUNNER_PAT="${ARRET_RUNNER_PAT:-usage-paced-runner|scheduler-paced-runner}"

survey_host() {  # <host> -> prints its block, returns 1 if unreachable
  local h="$1" out
  out="$(sshx "$h" "
    _c=\"\$(systemctl is-active cron 2>/dev/null)\"; [ -n \"\$_c\" ] || _c=unknown
    printf 'cron\t%s\n' \"\$_c\"
    # CAN WE LOOK AT ALL? A crontab this account cannot read counts 0 RUNNER
    # lines and reports as unarmed -- the estate's signature defect, a blind
    # probe wearing a healthy number. Asked ONCE, and the whole count is BLIND
    # if it fails, never a comforting zero.
    if sudo -n true 2>/dev/null; then
      n=0; for u in \$(getent passwd | awk -F: '\$3>=3000 && \$3<3100 {print \$1}'); do
        c=\$(sudo -n crontab -l -u \"\$u\" 2>/dev/null | grep -c RUNNER)
        [ \"\$c\" -gt 0 ] && n=\$((n+1))
      done
      printf 'armed\t%s\n' \"\$n\"
    else
      printf 'armed\tBLIND\n'
    fi
    # -a so the pattern is visible, and \$\$ excluded so the probe never counts ITSELF
    pgrep -fa '$RUNNER_PAT' 2>/dev/null | grep -v \"^\$\$ \" | head -8 | sed 's/^/run\t/'
  ")"
  if [ -z "$out" ]; then printf '  %-11s UNREACHABLE\n' "$h"; return 1; fi
  local cron armed runs
  cron="$(printf '%s\n' "$out" | awk -F'\t' '$1=="cron"{print $2}')"
  armed="$(printf '%s\n' "$out" | awk -F'\t' '$1=="armed"{print $2}')"
  runs="$(printf '%s\n' "$out" | awk -F'\t' '$1=="run"{print $2}')"
  local nrun; nrun="$(printf '%s' "$runs" | grep -c . )"
  if [ "$armed" = BLIND ]; then
    printf '  %-11s cron %-8s armed count BLIND (no passwordless sudo) %s agent(s) running now\n' \
      "$h" "$cron" "$nrun"
  else
    printf '  %-11s cron %-8s %2s account(s) armed   %s agent(s) running now\n' \
      "$h" "$cron" "$armed" "$nrun"
  fi
  [ "$nrun" -gt 0 ] && printf '%s\n' "$runs" | sed 's/^/                 -> /'
  return 0
}

survey_docker() {
  local out; out="$(sshx "$DOCKER_HOST_SSH" 'sudo -n docker ps --format "{{.Names}}\t{{.Status}}" 2>/dev/null')"
  [ -n "$out" ] || { printf '  %-11s no docker answer\n' "$DOCKER_HOST_SSH"; return 0; }
  printf '  %s containers:\n' "$DOCKER_HOST_SSH"
  printf '%s\n' "$out" | while IFS=$'\t' read -r name status; do
    case " $PROTECTED " in
      *" $name "*) printf '    %-22s %-22s PROTECTED (never stopped here)\n' "$name" "$status" ;;
      *)           printf '    %-22s %-22s\n' "$name" "$status" ;;
    esac
  done
}

echo "== $CLI_NAME: self-dev across the estate =="
rc=0
for h in $HOSTS; do survey_host "$h" || rc=1; done
survey_docker
[ "$MODE" = survey ] && { echo; echo "nothing changed. --stop halts the clocks; --stop --now also kills work in flight."; exit "$rc"; }

if [ "$YES" = 0 ]; then
  echo
  if [ "$MODE" = down ]; then
    [ "$COMPACT" = 1 ] \
      && echo "About to stop $ONE's clocks, TERMINATE the distro, and make its disk sparse." \
      || echo "About to stop $ONE's clocks and TERMINATE the distro. Everything running on it dies."
  elif [ "$MODE" = up ]; then
    echo "About to boot $ONE and start its clocks."
  elif [ "$MODE" = stop ]; then
    [ "$NOW" = 1 ] && echo "About to STOP every clock above AND KILL the agents listed as running." \
                   || echo "About to STOP every clock above. Agents already running will finish."
  else
    echo "About to START the clocks above: dispatch resumes."
  fi
  printf 'Type yes to proceed: '
  read -r a; [ "$a" = yes ] || { echo "no change."; exit 0; }
fi

# Is <distro> listed as running by the machine that drives it? The distro
# cannot answer this about itself once it is gone, which is the whole point.
distro_running() { # <distro> -> 0 if running
  sshx "$VMHOST_SSH" "$(vmhost_running_vms_cmd)" | grep -qx "$1"
}

if [ "$MODE" = down ]; then
  sshx "$ONE" 'sudo -n systemctl stop cron' >/dev/null
  [ "$NOW" = 1 ] && sshx "$ONE" "sudo -n pkill -f '$RUNNER_PAT'" >/dev/null
  sshx "$VMHOST_SSH" "$(vmhost_save_cmd "$ONE")" >/dev/null
  if distro_running "$ONE"; then
    printf '  BAD     %-11s still listed as running after terminate; NOTHING further was done\n' "$ONE" >&2
    exit 1
  fi
  printf '  ok      %-11s terminated\n' "$ONE"
  if [ "$COMPACT" = 1 ]; then
    out="$(sshx "$VMHOST_SSH" "$(vmhost_sparse_cmd "$ONE")" 2>&1)"
    if distro_running "$ONE"; then
      printf '  BAD     %-11s came back up during the compact; treat the disk as unconverted\n' "$ONE" >&2; exit 1
    fi
    # READ THE ANSWER, DO NOT ANNOUNCE THE REQUEST. This printed "sparse
    # requested while down" over a refusal on 2026-09-23 and the caller spent
    # a trim and a measurement finding out: WSL answers
    #   "Sparse VHD support is currently disabled due to potential data
    #    corruption ... Error code: Wsl/Service/E_INVALIDARG"
    # and exits 0-ish through the interop layer, so only the TEXT says no.
    # --allow-unsafe is the documented override and is ruled OUT: it is the
    # fleet's disk.
    case "$out" in
      *"Error code:"*|*"E_INVALIDARG"*|*"disabled"*)
        printf '  BAD     %-11s the driver REFUSED the sparse conversion, disk unchanged:\n' "$ONE" >&2
        printf '%s\n' "$out" | sed 's/^/          /' >&2
        exit 1 ;;
    esac
    printf '  ok      %-11s sparse conversion accepted %s\n' "$ONE" "${out:+-- $out}"
  fi
  echo
  echo "$ONE is down. Bring it back with: $CLI_NAME --up --host $ONE"
  exit 0
fi

if [ "$MODE" = up ]; then
  sshx "$VMHOST_SSH" "$(vmhost_start_cmd "$ONE")" >/dev/null
  # ITS OWN sshd IS THE WITNESS, not the distro list: WSL calls a distro
  # running the moment its init starts, and dispatch needs the thing that
  # answers on port 22.
  n=0
  until sshx "$ONE" true; do
    n=$((n + 1))
    [ "$n" -ge 12 ] && { printf '  BAD     %-11s booted but its sshd never answered\n' "$ONE" >&2; exit 1; }
    sleep 5
  done
  printf '  ok      %-11s up, sshd answering\n' "$ONE"
  if [ "$CLOCKS_OFF" = 1 ]; then
    # STOPS cron, it does not merely decline to start it. A distro that boots
    # brings its own enabled units up with it, so "leave the clocks alone"
    # means dispatch resumes the moment the host does -- measured 2026-09-23,
    # when this printed "cron left active, as asked" and meant the opposite.
    # The CI runners still come back with the distro; only dispatch is withheld.
    sshx "$ONE" 'sudo -n systemctl stop cron' >/dev/null
    state="$(sshx "$ONE" 'systemctl is-active cron 2>/dev/null')"; [ -n "$state" ] || state=unknown
    if [ "$state" != inactive ]; then
      printf '  BAD     %-11s cron reads %s after --clocks-off; dispatch is RUNNING\n' "$ONE" "$state" >&2
      exit 1
    fi
    printf '  ok      %-11s cron is %s, as asked\n' "$ONE" "$state"
    echo
    echo "$ONE is up and NOT dispatching. Start it with: $CLI_NAME --start --host $ONE"
    exit 0
  fi
  sshx "$ONE" 'sudo -n systemctl start cron' >/dev/null
  state="$(sshx "$ONE" 'systemctl is-active cron 2>/dev/null')"; [ -n "$state" ] || state=unknown
  [ "$state" = active ] || { printf '  BAD     %-11s cron reads %s, wanted active\n' "$ONE" "$state" >&2; exit 1; }
  printf '  ok      %-11s cron is now %s\n' "$ONE" "$state"
  echo
  echo "re-surveying:"
  survey_host "$ONE"
  exit $?
fi

for h in $HOSTS; do
  case "$MODE" in
    stop)
      sshx "$h" 'sudo -n systemctl stop cron' >/dev/null
      [ "$NOW" = 1 ] && sshx "$h" "sudo -n pkill -f '$RUNNER_PAT'" >/dev/null
      ;;
    start) sshx "$h" 'sudo -n systemctl start cron' >/dev/null ;;
  esac
  # RE-READ, never trust the exit code of the thing that was asked to change
  # `systemctl is-active` EXITS 3 when the unit is inactive -- the very answer
  # a successful --stop is looking for. Appending `|| echo unknown` made every
  # successful stop read "inactive\nunknown", fail the comparison, and report
  # BAD with rc=1. The output is the answer; an EMPTY output is the failure.
  state="$(sshx "$h" 'systemctl is-active cron 2>/dev/null')"; [ -n "$state" ] || state=unknown
  want=inactive; [ "$MODE" = start ] && want=active
  if [ "$state" = "$want" ]; then
    printf '  ok      %-11s cron is now %s\n' "$h" "$state"
  else
    printf '  BAD     %-11s cron reads %s, wanted %s\n' "$h" "$state" "$want" >&2; rc=1
  fi
done
echo
echo "re-surveying:"
for h in $HOSTS; do survey_host "$h" || rc=1; done
exit "$rc"
