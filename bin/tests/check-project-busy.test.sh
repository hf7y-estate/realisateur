#!/usr/bin/env bash
set -uo pipefail
# shellcheck source=bin/tests/lib/harness.sh
. "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib/harness.sh"
harness_tmp

SCRIPT="$(dirname "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")")/check-project-busy.sh"
mkdir -p "$T/sched/schedule" "$T/homes"
mk() { mkdir -p "$T/homes/$1/.local/share/scheduler-registry"; : > "$T/sched/schedule/$1.conf"; }
run() { SCHED_ROOT="$T/sched" BUSY_HOME_ROOT="$T/homes" bash "$SCRIPT" "$@" 2>&1; }
rcof() { SCHED_ROOT="$T/sched" BUSY_HOME_ROOT="$T/homes" bash "$SCRIPT" "$@" >/dev/null 2>&1; printf '%s' "$?"; }

section "A. an unregistered name never reads as free"
rc  "A1 exit 2" 2 "$(rcof no-such-project)"
has "A2 and says why" "$(run no-such-project)" "not a scheduler-registered project"

section "B. the lock is read in the PROJECT's account, not the caller's"
mk otherproj
rc  "B1 a readable project with no lock held is free (0)" 0 "$(rcof otherproj)"

mk busyproj
lock="$T/homes/busyproj/.local/share/scheduler-registry/busyproj.lock"
: > "$lock"
exec 9<>"$lock"; flock -n 9
rc  "B2 a lock held in the OWNER's account is BUSY (1), not free" 1 "$(rcof busyproj)"
has "B3 and it names the holder" "$(run busyproj)" "BUSY"
exec 9>&-

section "C. could-not-look is not not-busy"
mk sealed
chmod 000 "$T/homes/sealed/.local/share"
out="$(run sealed)"; r="$(rcof sealed)"
chmod 755 "$T/homes/sealed/.local/share"
rc  "C1 an unreadable owner home is BLIND (6), never free" 6 "$r"
has "C2 and it refuses in those words" "$out" "Refusing to answer 'free'"

section "D. no account on this host is not not-busy either (#1158)"
# Registered with the scheduler, but this host has no /home/<project> at all
# -- groc-mangr@monkey probed from mandark, where groc-mangr has no home.
: > "$T/sched/schedule/elsewhere.conf"
rc  "D1 a registered project absent from BUSY_HOME_ROOT is BLIND (6), never free" \
    6 "$(rcof elsewhere)"
has "D2 and it refuses in those words, not a silent fallback to the caller's own home" \
    "$(run elsewhere)" "Refusing to answer 'free'"

section "E. a live human session is BUSY, not just a job lock (#1158)"
mk human
reg="$T/homes/human/.local/share/scheduler-registry"
printf 'pid=%s\nstarted_at=2026-01-01\ncwd=/tmp\n' "$$" > "$reg/human.interactive"
rc  "E1 a .interactive marker whose pid is alive is BUSY (1)" 1 "$(rcof human)"
has "E2 and it says so" "$(run human)" "BUSY: interactive session"

mk stalehuman
reg="$T/homes/stalehuman/.local/share/scheduler-registry"
deadpid=99999
while kill -0 "$deadpid" 2>/dev/null; do deadpid=$((deadpid + 1)); done
printf 'pid=%s\nstarted_at=2026-01-01\ncwd=/tmp\n' "$deadpid" > "$reg/stalehuman.interactive"
rc  "E3 a .interactive marker whose pid is gone is NOT busy -- litter, not a human" \
    0 "$(rcof stalehuman)"

summary
