#!/usr/bin/env bash
set -uo pipefail  # SUBJECT: bin/repose.sh -- the declared-pause verb (#704): a human's front door onto vmhost_save/vmhost_start and the pause record they read
. "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib/harness.sh"
REPO="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../.." && pwd)"
R="$REPO/bin/repose.sh"
harness_tmp

echo "repose.test.sh"

section "A. present, executable, and classified"
[ -x "$R" ] && ok "A1 bin/repose.sh is present and executable" \
  || bad "A1 bin/repose.sh is present and executable" "missing"
. "$REPO/bin/lib/propagation-set.sh"
ch="$(prop_channel repose.sh 2>/dev/null)" || ch=""
eq "A2 repose.sh is classified LOCAL -- a dexter-side tool, like monkey-watch.sh" "$ch" "local"

section "B. usage errors, before touching any VM"
out="$(bash "$R" 2>&1)"; rc="$?"
rc "B1 no arguments at all is a usage error" 2 "$rc"
out="$(bash "$R" monkey 2>&1)"; rc="$?"
rc "B2 a vm with no duration/--status/--cancel is a usage error" 2 "$rc"
out="$(bash "$R" monkey 2h30m 2>&1)"; rc="$?"
rc "B3 a duration that is not <N>h is a usage error" 2 "$rc"
out="$(bash "$R" monkey h 2>&1)"; rc="$?"
rc "B4 a bare 'h' with no number is a usage error" 2 "$rc"

section "C. off the VM host it fails loud, same as monkey-watch.sh"
VMHOST_VBOX="$T/nowhere" bash "$R" monkey 2h >/tmp/repose-c1.$$  2>&1; rc="$?"
rc "C1 declaring off-host refuses (2)" 2 "$rc"
grep -q VBoxManage /tmp/repose-c1.$$ && ok "C1b ...and says which tool is missing" \
  || bad "C1b names the missing tool" "$(cat /tmp/repose-c1.$$)"
rm -f /tmp/repose-c1.$$
VMHOST_VBOX="$T/nowhere" bash "$R" monkey --cancel >/dev/null 2>&1; rc="$?"
rc "C2 cancelling off-host also refuses (2)" 2 "$rc"

section "D. against a fake VBoxManage: declare, status, resume, cancel"
FAKE="$T/VBoxManage.exe"; CALLS="$T/calls"
# THE STUB MODELS STATE, because repose now re-reads it: a fake that only
# records the call cannot tell a pause that happened from one that did not, and
# that gap is the bug this suite exists to catch (realisateur, 2026-09-18 --
# `repose monkey 4h` printed "paused" while monkey kept running).
STATE="$T/vmstate"; echo running > "$STATE"
cat > "$FAKE" <<STUB
#!/usr/bin/env bash
case "\$1" in
  controlvm)   [ "\$3" = savestate ] && { printf 'savestate %s\n' "\$2" >> "$CALLS"; echo saved > "$STATE"; } ;;
  startvm)     printf 'startvm %s %s %s\n' "\$2" "\$3" "\$4" >> "$CALLS"; echo running > "$STATE" ;;
  showvminfo)  printf 'VMState="%s"\n' "\$(cat "$STATE")" ;;
esac
STUB
chmod +x "$FAKE"
export VMHOST_VBOX="$FAKE"
export VMHOST_PAUSE_DIR="$T/pause"

out="$(bash "$R" monkey --status)"
eq "D1 no declaration yet: --status reads NONE" "$out" "NONE"

out="$(bash "$R" monkey 2h)"
case "$out" in *"paused (state re-read: saved), resumes"*) ok "D2 declaring reports the VERIFIED state and the resume time" ;;
  *) bad "D2 declaring reports the verified state and resume time" "got: $out" ;; esac
eq "D3 the actuator ran: controlvm savestate, not an ACPI request" "$(cat "$CALLS")" "savestate monkey"

out="$(bash "$R" monkey --status)"
case "$out" in PAUSED\ *) ok "D4 --status now reads PAUSED with an until" ;;
  *) bad "D4 --status reads PAUSED" "got: $out" ;; esac

rm -f "$CALLS"
out="$(bash "$R" monkey --cancel)"
case "$out" in *"resumed, declaration cleared"*) ok "D5 --cancel reports the resume" ;;
  *) bad "D5 --cancel reports the resume" "got: $out" ;; esac
eq "D6 --cancel drove startvm" "$(cat "$CALLS")" "startvm monkey --type headless"
out="$(bash "$R" monkey --status)"
eq "D7 after --cancel the declaration is gone" "$out" "NONE"

section "D3. a pause that did not happen declares NOTHING (2026-09-18)"
# MEASURED BY HAND on dexter while WSL interop was wedged: `_wsl` returned the
# exit status of its own printf, so it was 0 even when every attempt lost the
# vsock. repose printed "monkey paused", wrote the declaration, and monkey kept
# running -- after which monkey-watch's tick reads PAUSED for a live host and
# schedules a resume for a VM that never stopped.
rm -rf "$T/pause"; echo running > "$STATE"
cat > "$FAKE" <<STUB
#!/usr/bin/env bash
case "\$1" in
  showvminfo) printf 'VMState="%s"\n' "\$(cat "$STATE")" ;;
esac
STUB
chmod +x "$FAKE"
out="$(bash "$R" monkey 2h 2>&1)"; drc=$?
rc "D3a an actuator that changed nothing exits 1" 1 "$drc"
case "$out" in *"did NOT pause"*) ok "D3b ...and says so, naming the state it re-read" ;;
  *) bad "D3b names the state it re-read" "got: $out" ;; esac
case "$out" in *paused,*) bad "D3c never claims a pause it did not verify" "got: $out" ;;
  *) ok "D3c never claims a pause it did not verify" ;; esac
eq "D3d and NOTHING is declared, so no resume is scheduled for a running host" \
  "$(bash "$R" monkey --status)" "NONE"

# put the working stub back for the sections below
echo running > "$STATE"
cat > "$FAKE" <<STUB
#!/usr/bin/env bash
case "\$1" in
  controlvm)   [ "\$3" = savestate ] && { printf 'savestate %s\n' "\$2" >> "$CALLS"; echo saved > "$STATE"; } ;;
  startvm)     printf 'startvm %s %s %s\n' "\$2" "\$3" "\$4" >> "$CALLS"; echo running > "$STATE" ;;
  showvminfo)  printf 'VMState="%s"\n' "\$(cat "$STATE")" ;;
esac
STUB
chmod +x "$FAKE"

section "E. a failed actuator leaves nothing declared or cleared"
FAILING="$T/VBoxManage-fail.exe"
cat > "$FAILING" <<'STUB'
#!/usr/bin/env bash
exit 1
STUB
chmod +x "$FAILING"
VMHOST_VBOX="$FAILING" bash "$R" monkey 3h >/dev/null 2>&1; rc="$?"
rc "E1 a savestate that fails exits nonzero" 1 "$rc"
out="$(bash "$R" monkey --status)"
eq "E2 ...and nothing was declared" "$out" "NONE"

bash "$R" monkey 3h >/dev/null 2>&1
VMHOST_VBOX="$FAILING" bash "$R" monkey --cancel >/dev/null 2>&1; rc="$?"
rc "E3 a resume that fails exits nonzero" 1 "$rc"
out="$(bash "$R" monkey --status)"
case "$out" in PAUSED\ *) ok "E4 ...and the declaration is left in place, not silently dropped" ;;
  *) bad "E4 the declaration survives a failed --cancel" "got: $out" ;; esac
bash "$R" monkey --cancel >/dev/null 2>&1

section "F. --check -- the dry run: name the backend and the exact actuator, touch nothing"
rm -f "$CALLS"
out="$(bash "$R" monkey --check)"; rcv="$?"
rc "F1 --check exits 0 on the VM host" 0 "$rcv"
has "F2 names the backend it detected" "$out" "backend=virtualbox"
has "F3 prints the command verbatim -- savestate, not pause" "$out" "controlvm monkey savestate"
[ -f "$CALLS" ] && bad "F4 --check drove nothing" "the actuator ran: $(cat "$CALLS")" || ok "F4 --check drove nothing"
out="$(bash "$R" monkey --status)"
eq "F5 ...and declared nothing" "$out" "NONE"

WSL="$T/wsl.exe"
cat > "$WSL" <<'STUB'
#!/usr/bin/env bash
[ "$1" = -l ] && printf 'Ubuntu\nmonkey\n'
STUB
chmod +x "$WSL"
out="$(VMHOST_VBOX="$T/nowhere" VMHOST_WSL="$WSL" bash "$R" monkey --check)"
has "F6 on a wsl-only host it detects the wsl backend, with no VirtualBox present" "$out" "backend=wsl"
has "F7 ...and the actuator is --terminate <distro>" "$out" "--terminate monkey"
hasnt "F8 ...never --shutdown, which would kill dexter's own Ubuntu" "$out" "--shutdown"

VMHOST_VBOX="$T/nowhere" VMHOST_WSL="$T/nowhere" bash "$R" monkey --check >/dev/null 2>&1
rc "F9 off any VM host, --check refuses (2) rather than reporting a backend" 2 "$?"

summary
