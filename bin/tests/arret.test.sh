#!/usr/bin/env bash
#
# arret.test.sh -- witness for the estate's stop switch.
#
# WHY IT MATTERS MORE THAN MOST: this verb stops dispatch on every host at
# once. The failure that costs is not "it did not stop" -- that is loud. It is
# a stop that reports success while the clocks keep running, or a survey that
# quietly acts, or a blind probe reporting a comforting zero. Each of those is
# asserted here.
#
# Offline by construction: ARRET_SSH points at a stub that records every
# command and answers from a script, so nothing here reaches a host.
set -uo pipefail
# shellcheck source=bin/tests/lib/harness.sh
. "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib/harness.sh"
SCRIPT="$(cd "$(dirname "$0")/.." && pwd)/arret.sh"
[ -x "$SCRIPT" ] || { echo "FAIL: $SCRIPT not executable"; exit 1; }
harness_tmp

LOG="$T/ssh.log"
# The stub answers by what it is ASKED, not by position: arret sends a survey
# heredoc, a stop, a pkill and a re-read, and the order is the thing under test.
mkstub() { # $1 = what `systemctl is-active cron` reports AFTER an action
  cat > "$T/ssh" <<STUB
#!/usr/bin/env bash
host="\$1"; shift; cmd="\$*"
printf '%s\t%s\n' "\$host" "\$cmd" >> "$LOG"
case "\$cmd" in
  *"stop cron"*|*"start cron"*|*pkill*) exit 0 ;;
  *is-active*) printf '$1\n' ;;
esac
case "\$cmd" in
  *"printf 'cron"*)
    printf 'cron\t$1\n'; printf 'armed\t7\n'; printf 'run\t4242 usage-paced-runner.sh\n' ;;
  *"docker ps"*)
    printf 'roster\tUp 3 days\n'; printf 'ci-sequestria\tUp 20 minutes\n' ;;
esac
exit 0
STUB
  chmod +x "$T/ssh"; : > "$LOG"
}
run() { ARRET_SSH="$T/ssh" ARRET_SSH_OPTS='' ARRET_HOSTS='monkey vaporwave' \
        ARRET_DOCKER_HOST=dexter "$SCRIPT" "$@" 2>&1; }

section "A. a survey acts on nothing"
mkstub active
out="$(run)"; got=$?
rc    "A1 exits 0"                        0 "$got"
has   "A2 it names the clock state"       "$out" "cron active"
has   "A3 and says nothing changed"       "$out" "nothing changed"
hasnt "A4 no stop was ever sent"          "$(cat "$LOG")" "stop cron"
hasnt "A5 no agent was killed"            "$(cat "$LOG")" "pkill"

section "B. --stop halts the clocks and RE-READS"
mkstub inactive
out="$(run --stop --yes)"; got=$?
rc  "B1 exits 0 once the re-read agrees" 0 "$got"
has "B2 the stop was sent"               "$(cat "$LOG")" "sudo -n systemctl stop cron"
has "B3 and the state was re-read"       "$(cat "$LOG")" "is-active cron"
has "B4 it reports the state it READ"    "$out" "cron is now inactive"
hasnt "B5 running work was not killed"   "$(cat "$LOG")" "pkill"

section "C. a stop that did not take is a FAILURE, whatever the command returned"
mkstub active            # the stop 'succeeds' and cron is still running
out="$(run --stop --yes)"; got=$?
rc  "C1 exits 1"                          1 "$got"
has "C2 and says BAD, not ok"             "$out" "BAD"
has "C3 naming what it wanted"            "$out" "wanted inactive"

section "D. --now is the only thing that kills work in flight"
mkstub inactive
run --stop --now --yes >/dev/null
has "D1 --now pkills the paced runner"    "$(cat "$LOG")" "pkill -f"

section "E. --host narrows to one host"
mkstub inactive
run --stop --host monkey --yes >/dev/null
has   "E1 monkey was acted on"            "$(cat "$LOG")" "monkey"
hasnt "E2 vaporwave was not touched"      "$(cat "$LOG")" "vaporwave"

section "F. the containers Zach is reached through are never stopped"
mkstub active
out="$(run)"
has   "F1 roster is listed"               "$out" "roster"
hasnt "F2 but nothing is docker-stopped"  "$(cat "$LOG")" "docker stop"

section "G. --start asks for the opposite, and verifies it the same way"
mkstub active
out="$(run --start --yes)"; got=$?
rc  "G1 exits 0 when cron comes back"     0 "$got"
has "G2 the start was sent"               "$(cat "$LOG")" "sudo -n systemctl start cron"
has "G3 reported from the re-read"        "$out" "cron is now active"
mkstub inactive          # start 'succeeds', cron stays down
out="$(run --start --yes)"; got=$?
rc  "G4 a start that did not take fails"  1 "$got"
has "G5 and wanted active"                "$out" "wanted active"

section "H. without --yes, an answer that is not yes changes nothing"
mkstub inactive
out="$(printf 'no\n' | ARRET_SSH="$T/ssh" ARRET_SSH_OPTS='' ARRET_HOSTS='monkey' \
      ARRET_DOCKER_HOST=dexter "$SCRIPT" --stop 2>&1)"
has   "H1 it says no change"              "$out" "no change"
hasnt "H2 and sent no stop"               "$(cat "$LOG")" "stop cron"

section "I. an unreachable host is not a quiet zero"
cat > "$T/ssh" <<'STUB'
#!/usr/bin/env bash
exit 255
STUB
chmod +x "$T/ssh"; : > "$LOG"
out="$(run)"; got=$?
rc  "I1 exits 1 rather than reporting a healthy fleet" 1 "$got"

section "J. --down and --up refuse what they cannot do safely"
mkstub inactive
out="$(run --down)"; got=$?
rc  "J1 --down without --host exits 2"    2 "$got"
has "J2 and says why"                     "$out" "needs --host"
out="$(run --down --host dexter)"; got=$?
rc  "J3 --down on the driving host exits 2" 2 "$got"
has "J4 naming the route out"             "$out" "drives the distros"
out="$(run --stop --compact --host monkey --yes)"; got=$?
rc  "J5 --compact without --down exits 2" 2 "$got"

# From here the stub must answer for TWO machines: monkey (its clocks) and
# dexter (the switch). RUNNING lists what the driver still sees.
RUNNING="$T/running"
mkvm() { # $1 = what the VM host lists as running, after the terminate
  printf '%s\n' "$1" > "$RUNNING"
  cat > "$T/ssh" <<STUB
#!/usr/bin/env bash
host="\$1"; shift; cmd="\$*"
printf '%s\t%s\n' "\$host" "\$cmd" >> "$LOG"
case "\$cmd" in
  *"--running"*)   cat "$RUNNING" ;;
  *is-active*)     printf 'active\n' ;;
  *"printf 'cron"*) printf 'cron\tactive\n'; printf 'armed\t7\n' ;;
esac
exit 0
STUB
  chmod +x "$T/ssh"; : > "$LOG"
}

section "K. --down stops the clocks, then terminates, then CHECKS"
mkvm ""                                   # nothing running after the terminate
out="$(run --down --host monkey --yes)"; got=$?
rc  "K1 exits 0"                          0 "$got"
has "K2 the clocks stopped first"         "$(cat "$LOG")" "systemctl stop cron"
has "K3 the terminate went to the DRIVER" "$(cat "$LOG")" "dexter"
has "K4 and it was --terminate"           "$(cat "$LOG")" "--terminate monkey"
hasnt "K5 never --shutdown, which takes every distro" "$(cat "$LOG")" "--shutdown"
has "K6 it reports terminated"            "$out" "terminated"
has "K7 and says how to undo it"          "$out" "--up --host monkey"

section "L. a terminate that did not take is a FAILURE"
mkvm "monkey"                             # still listed as running
out="$(run --down --host monkey --yes)"; got=$?
rc  "L1 exits 1"                          1 "$got"
has "L2 says BAD"                         "$out" "BAD"
has "L3 and did nothing further"          "$out" "NOTHING further"

section "M. --compact only runs while the distro is down"
mkvm ""
out="$(run --down --host monkey --compact --yes)"; got=$?
rc  "M1 exits 0"                          0 "$got"
has "M2 the sparse call was sent"         "$(cat "$LOG")" "--set-sparse true"
mkvm "monkey"
run --down --host monkey --compact --yes >/dev/null 2>&1
hasnt "M3 and is never sent when the terminate failed" "$(cat "$LOG")" "--set-sparse"

section "N. --up boots, waits for SSHD, and starts the clocks"
mkvm ""
out="$(run --up --host monkey --yes)"; got=$?
rc  "N1 exits 0"                          0 "$got"
has "N2 the distro was started"           "$(cat "$LOG")" "-d monkey"
has "N3 cron was started"                 "$(cat "$LOG")" "systemctl start cron"
has "N4 and read back"                    "$out" "cron is now active"

section "O. --up --clocks-off brings the host back without dispatch"
mkvm ""
out="$(run --up --host monkey --clocks-off --yes)"; got=$?
rc    "O1 exits 0"                        0 "$got"
has   "O2 the distro was still started"   "$(cat "$LOG")" "-d monkey"
hasnt "O3 but cron was NOT started"       "$(cat "$LOG")" "systemctl start cron"
has   "O4 and it says so out loud"        "$out" "NOT dispatching"
out="$(run --stop --host monkey --clocks-off --yes)"; got=$?
rc    "O5 --clocks-off without --up exits 2" 2 "$got"

summary
