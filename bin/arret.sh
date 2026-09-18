#!/usr/bin/env bash
set -uo pipefail

CLI_NAME='arret'
CLI_SUMMARY="Zach's stop switch for self-dev: what is running, and stop it"
CLI_USAGE='  arret                  survey only: what is dispatching, on every host, right now
  arret --stop           stop the CLOCKS: no new dispatch anywhere. Running work finishes.
  arret --stop --now     ...and terminate the agents already running. Work in flight dies.
  arret --start          undo --stop: the clocks run again

  --host <h>   just one of: monkey vaporwave
  --yes        skip the confirmation prompt'
CLI_FLAGS='--stop --start --now --host --yes'
CLI_POSITIONAL=none
CLI_EXITS='  0  surveyed, or the action was applied and re-read
  1  a host could not be reached, or a stop did not verify on re-read
  2  usage error'

HOSTS="${ARRET_HOSTS:-monkey vaporwave}"
DOCKER_HOST_SSH="${ARRET_DOCKER_HOST:-dexter}"
SSH="${ARRET_SSH:-ssh}"
SSH_OPTS="${ARRET_SSH_OPTS:--o BatchMode=yes -o ConnectTimeout=10}"
# NEVER STOPPED BY THIS TOOL. zaxon is the only channel that reaches Zach, so a
# stop that kills it cannot report that it worked; roster is the arming
# authority every dispatcher reads, and a blind roster is worse than an armed
# one. Listed, marked, and left alone -- `docker stop` them by hand if you mean it.
PROTECTED='zaxon-relay zaxon-gateway zaxon-watcher roster'

MODE=survey; NOW=0; ONE=''; YES=0
while [ $# -gt 0 ]; do
  case "$1" in
    --stop)  MODE=stop ;;
    --start) MODE=start ;;
    --now)   NOW=1 ;;
    --host)  ONE="${2:?--host needs a name}"; shift ;;
    --yes)   YES=1 ;;
    -h|--help) printf '%s -- %s\n\nusage:\n%s\n\nexits:\n%s\n' "$CLI_NAME" "$CLI_SUMMARY" "$CLI_USAGE" "$CLI_EXITS"; exit 0 ;;
    *) printf '%s: unknown argument: %s\n' "$CLI_NAME" "$1" >&2; exit 2 ;;
  esac
  shift
done
[ -n "$ONE" ] && HOSTS="$ONE"

sshx() { local h="$1"; shift; timeout 45 $SSH $SSH_OPTS "$h" "$@" 2>/dev/null; }

# The runner a dispatch tick actually execs. Matched by its cron TAG, not by the
# word "scheduler": sync-crontab.sh also runs out of the scheduler clone and
# arms nothing (bin/monkey-status-collect.py says the same about dispatch_line).
RUNNER_PAT="${ARRET_RUNNER_PAT:-usage-paced-runner|scheduler-paced-runner}"

survey_host() {  # <host> -> prints its block, returns 1 if unreachable
  local h="$1" out
  out="$(sshx "$h" "
    printf 'cron\t%s\n' \"\$(systemctl is-active cron 2>/dev/null || echo unknown)\"
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
  if [ "$MODE" = stop ]; then
    [ "$NOW" = 1 ] && echo "About to STOP every clock above AND KILL the agents listed as running." \
                   || echo "About to STOP every clock above. Agents already running will finish."
  else
    echo "About to START the clocks above: dispatch resumes."
  fi
  printf 'Type yes to proceed: '
  read -r a; [ "$a" = yes ] || { echo "no change."; exit 0; }
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
  state="$(sshx "$h" 'systemctl is-active cron 2>/dev/null || echo unknown')"
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
