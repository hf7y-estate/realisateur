#!/usr/bin/env bash
set -uo pipefail  # SUBJECT: bin/lib/vmhost.sh -- pins the virtualbox backend against a stub VBoxManage as an inert wrap of the old vbm() call shape (#563)
. "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib/harness.sh"
REPO="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../.." && pwd)"
harness_tmp

echo "vmhost.test.sh"

FAKE="$T/VBoxManage.exe"  # showvminfo prints $FAKE_VMINFO; controlvm screenshotpng writes a dummy PNG; savestate/startvm log to $CALLS
FAKE_VMINFO="$T/vminfo"
CALLS="$T/calls"
cat > "$FAKE" <<STUB
#!/usr/bin/env bash
case "\$1" in
  showvminfo) cat "$FAKE_VMINFO" ;;
  controlvm)  [ "\$3" = screenshotpng ] && printf '\x89PNG-fake' > "\$4"
              [ "\$3" = savestate ] && printf 'controlvm %s savestate\n' "\$2" >> "$CALLS" ;;
  startvm)    printf 'startvm %s %s %s\n' "\$2" "\$3" "\$4" >> "$CALLS" ;;
  list)       [ "\$2" = runningvms ] && printf '"monkey" {a1b2}\n"nomac" {c3d4}\n' ;;
esac
STUB
chmod +x "$FAKE"
printf 'VMState="running"\n"SATA-0-0"="C:\\VMs\\monkey.vdi"\n' > "$FAKE_VMINFO"

VMHOST_VBOX="$FAKE"
. "$REPO/bin/lib/vmhost.sh"

section "A. backend detection"
unset VMHOST_BACKEND
eq "A1 an executable VBoxManage at \$VMHOST_VBOX detects as virtualbox" "$(vmhost_backend)" "virtualbox"
eq "A2 no driver at all and no override detects as unknown" \
  "$(VMHOST_VBOX="$T/nowhere" VMHOST_WSL="$T/nowhere" vmhost_backend)" "unknown"
eq "A3 \$VMHOST_BACKEND overrides detection" "$(VMHOST_BACKEND=hyperv vmhost_backend)" "hyperv"

section "B. vmhost_require -- the fail-loud precondition monkey-watch.sh calls"
vmhost_require; rc "B1 virtualbox backend with VBoxManage present succeeds" 0 $?
VMHOST_VBOX="$T/nowhere" vmhost_require 2>/dev/null; rc "B2 virtualbox backend with VBoxManage missing fails" 2 $?
VMHOST_BACKEND=hyperv vmhost_require 2>/dev/null; rc "B3 an unimplemented backend fails, not silently no-ops" 2 $?

section "C. vmhost_state -- wraps showvminfo verbatim (#563's 'inert refactor')"
eq "C1 reads VMState out of --machinereadable" "$(vmhost_state monkey)" "running"
printf 'VMState="poweroff"\n' > "$FAKE_VMINFO"
eq "C2 a different fixture value passes through unchanged" "$(vmhost_state monkey)" "poweroff"
printf '' > "$FAKE_VMINFO"
eq "C3 no VMState line at all reads unknown, not empty" "$(vmhost_state monkey)" "unknown"

section "D. vmhost_disk_raw / vmhost_classify_disk -- the value monkey-watch.sh publishes as-is, and its classing"
printf '"SATA-0-0"="C:\\VMs\\monkey.vdi"\n' > "$FAKE_VMINFO"
eq "D1 the raw descriptor passes through for publishing" "$(vmhost_disk_raw monkey)" 'C:\VMs\monkey.vdi'
eq "D2 a C: drive letter classes internal" "$(vmhost_classify_disk 'C:\VMs\monkey.vdi')" "internal"
eq "D3 a D: drive letter classes EXTERNAL-USB -- the outage this exists to catch" \
  "$(vmhost_classify_disk 'D:\VMs\monkey.vdi')" "EXTERNAL-USB"
eq "D4 anything else classes unknown, not a guess" "$(vmhost_classify_disk '')" "unknown"
printf '"SATA-0-0"="D:\\VMs\\monkey.vdi"\n' > "$FAKE_VMINFO"
eq "D5 vmhost_disk composes raw + classify against a live fixture" "$(vmhost_disk monkey)" "EXTERNAL-USB"

section "E. vmhost_screenshot -- the #560 console capture, via the backend"
SHOT="$T/console.png"
rm -f "$SHOT"
vmhost_screenshot monkey "$SHOT"
[ -s "$SHOT" ] && ok "E1 a screenshot lands at the given path" || bad "E1 a screenshot lands at the given path" "nothing written to $SHOT"

section "H. vmhost_save -- #704's pause actuator, savestate not acpipowerbutton"
rm -f "$CALLS"
vmhost_save monkey
eq "H1 drives controlvm savestate, not an ACPI request" "$(cat "$CALLS")" "controlvm monkey savestate"

section "I. vmhost_start -- #704's resume actuator"
rm -f "$CALLS"
vmhost_start monkey
eq "I1 defaults to a headless launch" "$(cat "$CALLS")" "startvm monkey --type headless"
rm -f "$CALLS"
VMHOST_START_TYPE=gui vmhost_start monkey
eq "I2 \$VMHOST_START_TYPE overrides the launch type" "$(cat "$CALLS")" "startvm monkey --type gui"

section "G. vmhost_logdir -- the query AND the path translation, both backend-specific (#639)"
printf 'LogFldr="C:\\Users\\zach\\VirtualBox VMs\\monkey\\Logs"\n' > "$FAKE_VMINFO"
eq "G1 the folder comes from the backend, and lands in coordinates this host can open" \
  "$(vmhost_logdir monkey)" "/mnt/c/Users/zach/VirtualBox VMs/monkey/Logs"
printf '' > "$FAKE_VMINFO"
eq "G2 no LogFldr line yields nothing, so the caller skips rather than reading /VBox.log" \
  "$(vmhost_logdir monkey)" ""

section "J. vmhost_pause_* -- #704's declared-pause record, pure file+clock logic"
VMHOST_PAUSE_DIR="$T/pause"
eq "J1 no declaration reads NONE" "$(vmhost_pause_status monkey 2026-08-29T00:00:00Z)" "NONE"
vmhost_pause_declare monkey 2026-08-29T18:00:00Z
eq "J2 before the expiry reads PAUSED with the declared until" \
  "$(vmhost_pause_status monkey 2026-08-29T10:00:00Z)" "PAUSED 2026-08-29T18:00:00Z"
eq "J3 at or past the expiry reads EXPIRED, still naming until" \
  "$(vmhost_pause_status monkey 2026-08-29T18:00:01Z)" "EXPIRED 2026-08-29T18:00:00Z"
vmhost_pause_mark_resumed monkey 2026-08-29T18:00:05Z
eq "J4 once the actuator fires it reads RESUMING, not EXPIRED again" \
  "$(vmhost_pause_status monkey 2026-08-29T18:05:00Z)" "RESUMING 2026-08-29T18:00:05Z"
eq "J5 \`until\` survives the resumed_at rewrite" "$(vmhost_pause_field monkey until)" "2026-08-29T18:00:00Z"
vmhost_pause_clear monkey
eq "J6 clearing removes the declaration outright" "$(vmhost_pause_status monkey 2026-08-29T18:05:00Z)" "NONE"
[ ! -f "$(vmhost_pause_file monkey)" ] && ok "J6b the file itself is gone" || bad "J6b the file itself is gone"

vmhost_pause_mark_resumed monkey 2026-08-29T18:00:05Z
eq "J7 marking resumed with no declaration is a no-op, not a fabricated record" \
  "$(vmhost_pause_status monkey 2026-08-29T18:05:00Z)" "NONE"

vmhost_pause_declare gardien 2026-08-29T18:00:00Z
eq "J8 declarations are per-vm; a second vm's file does not collide" \
  "$(vmhost_pause_status monkey 2026-08-29T18:05:00Z)" "NONE"
eq "J8b the second vm's own declaration is intact" \
  "$(vmhost_pause_status gardien 2026-08-29T10:00:00Z)" "PAUSED 2026-08-29T18:00:00Z"
vmhost_pause_clear gardien
unset VMHOST_PAUSE_DIR

section "K. the wsl backend -- monkey becomes a distro on dexter and VirtualBox goes away (#704 follow-on)"
WSL="$T/wsl.exe"; WCALLS="$T/wcalls"; WLIST="$T/wlist"; WRUN="$T/wrun"; WFAIL="$T/wfail"
cat > "$WSL" <<STUB
#!/usr/bin/env bash
n=\$(cat "$WFAIL" 2>/dev/null || echo 0)   # the real interop failure: an error where the answer goes, on stderr, exit 0
if [ "\$n" -gt 0 ]; then
  printf '%s\\n' "\$((n - 1))" > "$WFAIL"
  printf '<3>WSL (650213 - ) ERROR: UtilAcceptVsock:273: accept4 failed 110\\n' >&2
  exit 0
fi
case "\$1" in
  -l) if [ "\$3" = --running ]; then cat "$WRUN"; else cat "$WLIST"; fi ;;
  --terminate) printf 'terminate %s\n' "\$2" >> "$WCALLS" ;;
  --shutdown)  printf 'SHUTDOWN-ALL\n' >> "$WCALLS" ;;
  -d) printf -- '-d %s %s %s\n' "\$2" "\$3" "\$4" >> "$WCALLS" ;;
esac
STUB
chmod +x "$WSL"
printf 'Ubuntu\nmonkey\n' > "$WLIST"
printf 'Ubuntu\nmonkey\n' > "$WRUN"
export VMHOST_WSL="$WSL"

_VMHOST_WSL_DISTROS=""
eq "K1 no VBoxManage but a wsl.exe detects as wsl" \
  "$(VMHOST_VBOX="$T/nowhere" vmhost_backend)" "wsl"
_VMHOST_WSL_DISTROS=""
eq "K2 both drivers present: a distro by that name wins -- the migration window, not a hardcoded backend" \
  "$(vmhost_backend monkey)" "wsl"
_VMHOST_WSL_DISTROS=""
eq "K3 both present but no distro by that name stays virtualbox" \
  "$(vmhost_backend gardien)" "virtualbox"
_VMHOST_WSL_DISTROS=""
eq "K4 with no vm named at all, detection cannot ask, and keeps the driver it has" \
  "$(vmhost_backend)" "virtualbox"

VMHOST_VBOX="$T/nowhere"          # from here on: the post-migration host, VirtualBox deleted
_VMHOST_WSL_DISTROS=""
vmhost_require monkey; rc "K5 vmhost_require succeeds on a wsl-only host" 0 $?
VMHOST_WSL="$T/nowhere" vmhost_require monkey 2>/dev/null; rc "K6 ...and fails 2 with no driver at all" 2 $?
out="$(VMHOST_WSL="$T/nowhere" vmhost_require monkey 2>&1)"
has "K6b the no-driver refusal names both drivers it looked for" "$out" "wsl.exe"
has "K6c ...including VBoxManage, so the off-host message stays true either way" "$out" "VBoxManage"

eq "K7 a running distro reads running" "$(vmhost_state monkey)" "running"
export VMHOST_WSL_RETRY_S=0   # the gap is measured in the driver; the suite does not pay it
printf '1\n' > "$WFAIL"
eq "K7b one lost interop call is retried, not published -- monkey was up 5 days when this alarmed" \
  "$(vmhost_state monkey)" "running"
printf '2\n' > "$WFAIL"
eq "K7b2 ...and so is a second, because the vsock window outlives one retry (#1226)" \
  "$(vmhost_state monkey)" "running"
printf '9\n' > "$WFAIL"
eq "K7c a driver that never answers reads unknown, NEVER poweroff -- poweroff is what monkey-watch alerts Zach on" \
  "$(vmhost_state monkey)" "unknown"
printf '0\n' > "$WFAIL"
printf 'Ubuntu\n' > "$WRUN"
eq "K8 a distro that is not running reads poweroff -- it holds no RAM" "$(vmhost_state monkey)" "poweroff"
printf 'Ubuntu\nmonkey\n' > "$WRUN"

rm -f "$WCALLS"
vmhost_save monkey
eq "K9 freeing RAM is --terminate <distro>" "$(cat "$WCALLS")" "terminate monkey"
hasnt "K10 and NEVER --shutdown, which kills dexter's own Ubuntu -- the route in" "$(cat "$WCALLS")" "SHUTDOWN-ALL"

rm -f "$WCALLS"
vmhost_start monkey
eq "K11 resuming runs a command in the distro, which boots it" "$(cat "$WCALLS")" "-d monkey --exec /bin/true"

section "L. vmhost_save_cmd -- the dry run prints the actuator, it does not paraphrase it"
eq "L1 wsl" "$(vmhost_save_cmd monkey)" "$WSL --terminate monkey"
VMHOST_VBOX="$FAKE"
_VMHOST_WSL_DISTROS=""
eq "L2 virtualbox names savestate, not pause -- pause holds the RAM" \
  "$(VMHOST_WSL="$T/nowhere" vmhost_save_cmd monkey)" "$FAKE controlvm monkey savestate"
VMHOST_BACKEND=hyperv vmhost_save_cmd monkey 2>/dev/null; rc "L3 an unsupported backend fails loud rather than printing a wrong command" 2 $?
section "M. vmhost_running_vms_cmd -- the liveness probe runs ON the VM host, so the seam has to travel to it as a command"
run_vms() { sh -c "$(vmhost_running_vms_cmd)" | tr '\n' ','; }
eq "M1 virtualbox: the name comes back unwrapped from VBoxManage's quotes and UUID" \
  "$(VMHOST_WSL="$T/nowhere" run_vms)" "monkey,nomac,"
eq "M2 wsl: a running distro IS the VM once monkey moves -- the answer the literal VBoxManage path could never give" \
  "$(VMHOST_VBOX="$T/nowhere" run_vms)" "Ubuntu,monkey,"
eq "M3 the migration window: both drivers answer, so neither host shape reads empty mid-move" \
  "$(run_vms)" "monkey,nomac,Ubuntu,monkey,"
has "M4 a command is emitted even where no driver is installed -- the HOST it lands on decides, not this one" \
  "$(VMHOST_VBOX="$T/nowhere" VMHOST_WSL="$T/nowhere" vmhost_running_vms_cmd)" "nowhere"
eq "M5 ...and running it there is empty, not a crash -- the probe reports BLIND on its own terms" \
  "$(VMHOST_VBOX="$T/nowhere" VMHOST_WSL="$T/nowhere" run_vms)" ""

unset VMHOST_WSL

section "F. an unsupported backend fails loud on every verb, not just detection"
VMHOST_BACKEND=hyperv vmhost_state monkey 2>/dev/null; rc "F1 vmhost_state" 2 $?
VMHOST_BACKEND=hyperv vmhost_disk_raw monkey 2>/dev/null; rc "F2 vmhost_disk_raw" 2 $?
VMHOST_BACKEND=hyperv vmhost_screenshot monkey "$T/x.png" 2>/dev/null; rc "F3 vmhost_screenshot" 2 $?
VMHOST_BACKEND=hyperv vmhost_logdir monkey 2>/dev/null; rc "F4 vmhost_logdir" 2 $?
VMHOST_BACKEND=hyperv vmhost_save monkey 2>/dev/null; rc "F5 vmhost_save" 2 $?
VMHOST_BACKEND=hyperv vmhost_start monkey 2>/dev/null; rc "F6 vmhost_start" 2 $?

summary
