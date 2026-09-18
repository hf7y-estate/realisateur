#!/usr/bin/env bash
#
# SUBJECT: bin/monkey-watch.sh -- the only observer OUTSIDE the system it
# observes, and the invoker of the dashboard Zach reads.
#
# THE DEFECT THIS PINS, 2026-08-22. realisateur#511's reachability scan read
# .github/workflows/ and this repo's bin/, found no caller for monkey-watch.sh,
# and deleted it. Its caller was a CRONTAB LINE ON ANOTHER MACHINE -- dexter,
# every ten minutes, out of a checkout dexter pulls itself.
# The blast radius was not one script: #511 protected the
# dashboard payload BY NAME while the same PR deleted its only invoker, keeping
# the payload and cutting its clock (#518); #524 then deleted the merge lib as
# an orphan. Dexter's cron kept firing into a deleted path, appending
# `not found` to a 47 MB log -- a fault indicator nobody reads.
#
# So: the observer exists, names the parts it needs, those parts exist -- and
# THE DASHBOARD PAYLOAD HAS AN INVOKER, which is the guard.

set -uo pipefail
. "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib/harness.sh"
REPO="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../.." && pwd)"
W="$REPO/bin/monkey-watch.sh"

echo "monkey-watch.test.sh"

section "A. the observer exists and runs only where it can see"
[ -x "$W" ] && ok "bin/monkey-watch.sh is present and executable" \
  || bad "bin/monkey-watch.sh is present and executable" "missing -- the estate has no observer outside monkey"
out="$(bash "$W" 2>&1)"; rc=$?
if [ "$rc" = 2 ]; then ok "off the VM host it FAILS LOUD (2) rather than reporting a healthy world"
else bad "off-host exit is 2" "got $rc: $out"; fi
case "$out" in *VBoxManage*) ok "...and says which host it must run on" ;;
  *) bad "the refusal names the host" "got: $out" ;; esac

section "B. the parts it names still exist"
for f in bin/monkey-status-collect.py share/monkey-status.html bin/lib/monkey-watch-merge.py bin/lib/zaxon.sh; do
  if grep -q "$(basename "$f")" "$W"; then
    [ -e "$REPO/$f" ] && ok "$f -- named by the observer, and present" \
      || bad "$f is present" "the observer names it and it is gone; this run would die at that line"
  else
    bad "$W names $(basename "$f")" "it no longer does -- either the observer changed or this check has stopped checking"
  fi
done

section "C. THE GUARD -- the payload is EXECUTED, not merely named"
# The first draft of this section counted `grep -rl <name>` as an invoker and
# reported 3 for a payload nothing ran -- two comments and a classification
# row. That is the silence-audit defect verbatim ("counts named-in-a-doc as
# wired"), which is what got silence-audit deleted. Assert the CALL SITE.
code() { grep -v '^[[:space:]]*#' "$1"; }   # comments are not wiring
if code "$W" | grep -q '< *"\$COLLECTOR"'; then
  ok "the collector is FED to monkey over stdin -- a real call site, not a mention"
else
  bad "monkey-watch.sh executes the collector" "no '< \$COLLECTOR' redirect in non-comment code"
fi
if code "$W" | grep -q 'cp "\$PAGE_SRC"'; then
  ok "the page source is COPIED into the published tree"
else
  bad "monkey-watch.sh publishes the page" "no 'cp \$PAGE_SRC' in non-comment code"
fi
if code "$W" | grep -q 'monkey-watch-merge.py'; then
  ok "the merge helper is INVOKED, so #524's orphan reading cannot recur"
else
  bad "monkey-watch.sh invokes the merge helper" "not in non-comment code"
fi
# And the superseded publisher stays gone: two writers of one status.json with
# different failure semantics is how the 2026-08-14 outage got hidden.
[ -e "$REPO/bin/publish-monkey-status.sh" ] \
  && bad "publish-monkey-status.sh stays deleted" "it is back -- two publishers, and the mandark one refuses to publish exactly when it matters" \
  || ok "publish-monkey-status.sh stays deleted -- one publisher, with the outside vantage"

section "D. it is declared, so it reaches dexter by a named channel"
# LOCAL is correct and is not "never runs anywhere": dexter pulls this repo.
. "$REPO/bin/lib/propagation-set.sh"
ch="$(prop_channel monkey-watch.sh 2>/dev/null)" || ch=""
[ "$ch" = local ] && ok "prop_channel says local -- the checkout dexter pulls itself" \
  || bad "monkey-watch.sh is classified local" "got '${ch:-unclassified}'"

section "E. THE RENDERER READS THE VERDICT -- it does not re-derive one"
# THE DEFECT THIS PINS: the page headlined off accounts[], which is EMPTY when
# the guest is unreachable -- so a DOWN monkey rendered `0 ARMED` in GREEN.
# #535 removed the publisher that hid outages, not the renderer that still
# could. Asserted by RENDERING, not by grepping for a field name.
PAGE="$REPO/share/monkey-status.html"
if command -v node >/dev/null 2>&1; then
  render() {   # render <json> -> "<class> <headline>"
    node -e '
      const fs=require("fs");
      const src=fs.readFileSync(process.argv[1],"utf8").match(/<script>([\s\S]*)<\/script>/)[1];
      let out="";
      global.document={getElementById:()=>({set innerHTML(v){out=v;}})};
      const body=src.replace(/fetch\([\s\S]*?\.then\(d=>\{/,"(d=>{").replace(/\}\)\.catch\([\s\S]*$/,"})(D);");
      new Function("D",body)(JSON.parse(process.argv[2]));
      const m=out.match(/class="verdict (\w+)">([^<]*)</);
      console.log(m?m[1]+" "+m[2].trim():"NO-HEADLINE");
    ' "$PAGE" "$1" 2>/dev/null
  }
  FRESH='"generated":"2999-01-01T00:00:00Z","valid_until":"2999-01-01T00:00:00Z"'
  got="$(render "{\"accounts\":[],\"watcher\":{$FRESH,\"verdict\":\"DOWN\",\"why\":\"sshd silent\",\"vm_state\":\"running\",\"sshd\":\"silent\",\"disk_home\":\"internal\"}}")"
  case "$got" in bad\ DOWN*) ok "an unreachable monkey headlines DOWN, in red -- not a green 0 ARMED" ;;
    *) bad "DOWN document renders DOWN" "got [$got] -- the page is deriving its own verdict again" ;; esac

  itemsrender() {
    node -e '
      const fs=require("fs");
      const src=fs.readFileSync(process.argv[1],"utf8").match(/<script>([\s\S]*)<\/script>/)[1];
      let out="";
      global.document={getElementById:()=>({set innerHTML(v){out=v;}})};
      const body=src.replace(/fetch\([\s\S]*?\.then\(d=>\{/,"(d=>{").replace(/\}\)\.catch\([\s\S]*$/,"})(D);");
      new Function("D",body)(JSON.parse(process.argv[2]));
      console.log(out);
    ' "$PAGE" "$1" 2>/dev/null
  }
  got="$(itemsrender "{\"accounts\":[],\"watcher\":{$FRESH,\"verdict\":\"DOWN\",\"why\":\"sshd silent\",\"vm_state\":\"running\",\"sshd\":\"silent\",\"disk_home\":\"internal\",\"screenshot\":true}}")"
  has "a captured console screenshot is linked from the page" "$got" 'href="console.png"'
  got="$(itemsrender "{\"accounts\":[],\"watcher\":{$FRESH,\"verdict\":\"DOWN\",\"why\":\"sshd silent\",\"vm_state\":\"running\",\"sshd\":\"silent\",\"disk_home\":\"internal\",\"screenshot\":false}}")"
  hasnt "no screenshot means no dangling link to one" "$got" 'href="console.png"'

  got="$(render "{\"accounts\":[],\"watcher\":{$FRESH,\"verdict\":\"PAUSED\",\"why\":\"declared pause, resumes 2999-01-01T00:00:00Z\",\"vm_state\":\"poweroff\",\"sshd\":\"silent\",\"disk_home\":\"internal\"}}")"
  case "$got" in warn\ PAUSED*) ok "#704 a declared pause headlines PAUSED, in warn -- not DOWN in red" ;;
    *) bad "PAUSED renders as its own state, not DOWN" "got [$got]" ;; esac

  got="$(render "{\"accounts\":[],\"watcher\":{\"generated\":\"2020-01-01T00:00:00Z\",\"valid_until\":\"2020-01-01T00:00:00Z\",\"verdict\":\"OK\",\"why\":\"fine\",\"vm_state\":\"running\",\"sshd\":\"answering\",\"disk_home\":\"internal\"}}")"
  case "$got" in *UNWATCHED*) ok "a watcher past its own valid_until reads UNWATCHED, not OK" ;;
    *) bad "a stale watcher reads UNWATCHED" "got [$got] -- a dead dexter would show its last verdict as current" ;; esac

  W_OK="\"watcher\":{$FRESH,\"verdict\":\"OK\",\"why\":\"fine\",\"vm_state\":\"running\",\"sshd\":\"answering\",\"disk_home\":\"internal\"}"
  A_OK='"armed":true,"dispatch_line":true,"last_run":{},"containment":{"foreign_clones":[],"outside_home":[],"sudoers":[]},"credentials":{"k":"0640"}'
  FORGED="{\"accounts\":[{\"account\":\"chezz\",$A_OK,\"identity\":{\"declared\":\"chezz@selfdev.invalid\",\"clones\":[{\"path\":\"/home/chezz/Documents/Projects/chezz\",\"local_identity\":null,\"count\":2,\"commits\":[\"ca6fb2c hf7y <dangerpine@gmail.com> 2026-07-30\"]}]}}],$W_OK}"
  got="$(render "$FORGED")"
  case "$got" in bad\ *NOT\ COMMITTING\ AS\ ITSELF*) ok "#841 an account committing under a human's identity headlines RED" ;;
    *) bad "a forged-identity account headlines" "got [$got] -- the collector reported it and the page ate it" ;; esac
  got="$(itemsrender "$FORGED")"
  has "and the finding names the offending identity" "$got" "dangerpine@gmail.com"

  IDBLIND="{\"accounts\":[{\"account\":\"chezz\",$A_OK,\"identity\":null}],$W_OK}"
  got="$(render "$IDBLIND")"
  case "$got" in *UNVERIFIED*) ok "an identity the probe could not read is UNVERIFIED, never a green ARMED" ;;
    *) bad "identity BLIND is not counted as clean" "got [$got]" ;; esac

  REACH='"armed":true,"dispatch_line":true,"last_run":{},"containment":{"foreign_clones":[],"outside_home":["/srv/ecosystem1-vault/x"],"sudoers":[]},"credentials":{"k":"0640"}'
  REACH_ONLY="{\"accounts\":[{\"account\":\"bibliothecaire\",$REACH}],$W_OK}"
  got="$(render "$REACH_ONLY")"
  case "$got" in bad\ *NOT\ CONTAINED*) ok "#825 a containment breach still headlines when nothing else is wrong" ;;
    *) bad "a lone containment breach headlines NOT CONTAINED" "got [$got]" ;; esac

  REACH_AND_PARKED="{\"accounts\":[{\"account\":\"bibliothecaire\",\"armed\":false,\"dispatch_line\":true,\"last_run\":{},\"containment\":{\"foreign_clones\":[],\"outside_home\":[\"/srv/ecosystem1-vault/x\"],\"sudoers\":[]},\"credentials\":{\"k\":\"0640\"}}],$W_OK}"
  got="$(render "$REACH_AND_PARKED")"
  case "$got" in warn\ ALL*PARKED*) ok "#825 containment is demoted below an arming headline, not hiding it" ;;
    *) bad "containment demoted below arming" "got [$got] -- ALL 1 PARKED should win, not NOT CONTAINED" ;; esac
  got="$(itemsrender "$REACH_AND_PARKED")"
  has "#825 the containment finding still lands in findings after losing the headline" "$got" "is not contained"

  got="$(render '{"accounts":[],"generated":"2999-01-01T00:00:00Z"}')"
  case "$got" in *UNWATCHED*) ok "a document with no watcher block cannot report health" ;;
    *) bad "a watcher-less document reads UNWATCHED" "got [$got]" ;; esac
else
  # NOT a silent skip: a guard that passes when it cannot run is C's defect.
  bad "node is available to render the page" \
    "node is not on PATH, so the renderer contract went UNCHECKED -- install node or run this suite where it exists"
fi

section "F. an outage that persists gets re-pinged, not one ticket and silence (#549)"
. "$REPO/bin/lib/monkey-watch-alert.sh"
harness_tmp
SF="$T/state"
T0="2026-08-20T00:00:00Z"; T0_1H="2026-08-20T01:00:00Z"; T0_13H="2026-08-20T13:00:00Z"

d="$(mw_alert_decide DOWN OK "$SF" 12 "$T0")"
eq "F1 OK -> DOWN is one TRANSITION ping" "$d" "TRANSITION OK DOWN"
mw_alert_mark_sent "$SF" "$T0"

d="$(mw_alert_decide DOWN DOWN "$SF" 12 "$T0_1H")"
eq "F2 +1h against a 12h cadence is silence" "$d" "NONE"

d="$(mw_alert_decide DOWN DOWN "$SF" 12 "$T0_13H")"
eq "F3 +13h re-pings, carrying elapsed down-time" "$d" "PERSIST DOWN 13"
mw_alert_mark_sent "$SF" "$T0_13H"

rm -f "$SF" "$SF.since" "$SF.alerted"
n=0; for now in "$T0" "$T0_1H" "$T0_13H"; do
  d="$(mw_alert_decide OK OK "$SF" 12 "$now")"
  [ "$d" = NONE ] || n=$((n + 1))
done
eq "F4 zero pings across any run where the verdict is OK" "$n" "0"

d="$(mw_alert_decide DOWN OK "$SF" 12 "$T0")"; mw_alert_mark_sent "$SF" "$T0"
d="$(mw_alert_decide OK DOWN "$SF" 12 "$T0_13H")"
eq "F5 DOWN -> OK is one TRANSITION ping (recovery is not silence)" "$d" "TRANSITION DOWN OK"

rm -f "$SF" "$SF.since" "$SF.alerted"
d="$(mw_alert_decide PAUSED OK "$SF" 12 "$T0")"
eq "F6 OK -> PAUSED pages nobody -- a declared pause is not a fault" "$d" "NONE"
d="$(mw_alert_decide PAUSED PAUSED "$SF" 12 "$T0_13H")"
eq "F7 PAUSED persisting past the alert cadence still never re-pings" "$d" "NONE"
d="$(mw_alert_decide OK PAUSED "$SF" 12 "$T0_13H")"
eq "F8 PAUSED -> OK (a clean resume) also pages nobody" "$d" "NONE"
rm -f "$SF" "$SF.since" "$SF.alerted"
d="$(mw_alert_decide PAUSED OK "$SF" 12 "$T0")"
d="$(mw_alert_decide DOWN PAUSED "$SF" 12 "$T0_1H")"
eq "F9 PAUSED -> DOWN (the resume actuator itself failing) still pages -- #704's one loud case" \
  "$d" "TRANSITION PAUSED DOWN"

section "G. a DOWN verdict captures the console, not a guess about the cause (#560)"
has "G1 no cause is baked into the sshd-down WHY string" "$(grep 'sshd is \$SSHD' "$W")" 'WHY="VM running but sshd is $SSHD"'
hasnt "G1b the read-only-root inference is gone from the source" "$(code "$W")" "this is what a read-only root looks like"
has "G2 the console is captured only on DOWN" "$(code "$W")" 'if [ "$VERDICT" = DOWN ]; then'
has "G2b via vmhost_screenshot (#563), not a direct VBoxManage call" "$(code "$W")" 'vmhost_screenshot "$VM"'
has "G3 vmhost's virtualbox backend uses screenshotpng, the same probe the issue's own repro used" \
  "$(code "$REPO/bin/lib/vmhost.sh")" 'screenshotpng'
has "G4 a stale screenshot from a past incident is cleared before republishing" "$(code "$W")" 'rm -f "$WORK/site/$PUBLISH_DIR/console.png"'

section "H. the observer cannot inherit the outage it exists to report (2026-08-25)"
# Measured that day: monkey answered TCP, sent its SSH banner, then stalled in
# auth. The banner probe reported "answering", every mssh hung with no deadline,
# seven --apply runs stacked at one per cron tick, and hf7y.com/monkey stayed
# frozen on the last healthy publish for 35 minutes while the fleet was down.
has "H1 every guest ssh carries a deadline, not just a ConnectTimeout" \
  "$(code "$W")" 'timeout "$SSH_DEADLINE" ssh'
has "H2 the deadline is overridable for tests" "$(code "$W")" 'SSH_DEADLINE="${SSH_DEADLINE:-'
mw_deadline="$(sed -n 's/^SSH_DEADLINE="${SSH_DEADLINE:-\([0-9]*\)}"/\1/p' "$W")"
[ "${mw_deadline:-0}" -ge 120 ] \
  && ok "H2b the deadline clears the collector's measured 53.5s cost" \
  || bad "H2b the deadline clears the collector's measured 53.5s cost" "got: ${mw_deadline:-unset}"
hasnt "H3 no bare ssh call survives in the guest helpers" \
  "$(grep -E '^mssh(_n)?\(\)' -A1 "$W" | grep -c 'timeout "\$SSH_DEADLINE" ssh' | grep -q '^2$' && echo '' || echo 'undeadlined-helper')" \
  "undeadlined-helper"
# The five inline lock lines became `cron_lock` (#632); lib/cron-lock.sh owns
# the flock spelling and cron-lock.test.sh holds it there. What this file
# still owns is that the lock is taken AT ALL, and taken BEFORE the first
# probe -- an ordering claim no library can make for its caller.
has "H4 a tick that finds a run in flight leaves rather than stacking" "$(code "$W")" 'cron_lock monkey-watch'
lock_ln="$(grep -n 'cron_lock monkey-watch' "$W" | head -1 | cut -d: -f1)"
probe_ln="$(grep -n 'vmhost_state\|/dev/tcp/' "$W" | head -1 | cut -d: -f1)"
if [ -n "$lock_ln" ] && [ -n "$probe_ln" ] && [ "$lock_ln" -lt "$probe_ln" ]; then
  ok "H5 the lock is taken before any probe"
else
  bad "H5 the lock is taken before any probe" "cron_lock at line ${lock_ln:-none}, first probe at line ${probe_ln:-none}"
fi
has "H6 a stalled session is named as such, not as a bad payload" \
  "$(code "$W")" 'the session stalled'
has "H7 timeout's 124 is what distinguishes them" "$(code "$W")" '"$guest_rc" -eq 124'

section "I. the virtual clock is published before it takes sshd (realisateur#630)"
# 2026-08-25: VirtualBox gave up 41.8h of virtual sync across a 54h session and
# the guest read as a hung kernel. `controlvm reset` could not clear it -- the
# deficit belongs to the VMM process. Nothing measured it, so the first symptom
# was sshd dying.
has "I1 the drift is read from the VM's own log" "$(code "$W")" 'offVirtualSyncGivenUp'
# The LogFldr= query itself moved to lib/vmhost.sh with the rest of the
# backend vocabulary (#563); vmhost.test.sh C4/C5 hold it there. What this
# file still owns is that monkey-watch ASKS the backend rather than knowing
# where a VirtualBox log lives.
has "I2 the log folder is asked of the backend, not a hardcoded path" \
  "$(code "$W")" "vmhost_logdir"
has "I3 the value reaches the document" "$(code "$W")" 'CLOCK_DRIFT_H="$CLOCK_DRIFT_H"'
has "I4 merge publishes it" "$(code "$REPO/bin/lib/monkey-watch-merge.py")" 'clock_drift_hours'
has "I5 an unreadable log is null, not zero" \
  "$(code "$REPO/bin/lib/monkey-watch-merge.py")" 'else None'

# THE PARSING TRAP, pinned with the real shape. VirtualBox writes the value in
# nanoseconds with SPACE thousands separators; without `tr -d " "` this parses
# as 150 and reports 0.0h forever -- a sensor that is always green.
drift_of() {  # <log line> -> hours, using the script's own pipeline
  printf '%s\n' "$1" | grep -o 'offVirtualSyncGivenUp=[0-9 ]*' | tail -1 | cut -d= -f2 \
    | tr -d ' ' | awk 'length($0)>0 {printf "%.1f", $0/3600000000000}'
}
eq "I6 the real 2026-08-25 line reads 41.8h, not 0.0" \
  "$(drift_of 'TMR3UtcNow: nsNow=1 787 700 091 442 068 751 offVirtualSync=150 576 693 643 850 offVirtualSyncGivenUp=150 576 693 340 001, NowAgain=1')" \
  "41.8"
eq "I7 a fresh session reads 0.0" "$(drift_of 'offVirtualSyncGivenUp=0,')" "0.0"
eq "I8 no such line yields nothing, not a number" "$(drift_of 'nothing here')" ""

section "J. the declared pause and its resume actuator (#704)"
has "J1 the pause status is read from vmhost's own declaration, not re-derived" \
  "$(code "$W")" 'vmhost_pause_status "$VM" "$NOW"'
has "J2 an EXPIRED declaration drives vmhost_start -- THIS TICK is the scheduler" \
  "$(code "$W")" 'vmhost_start "$VM" >/dev/null 2>&1'
has "J3 firing the actuator is recorded, so the next tick reads RESUMING not EXPIRED again" \
  "$(code "$W")" 'vmhost_pause_mark_resumed "$VM" "$NOW"'
has "J4 a clean resume (vm running, sshd answering) clears the declaration" \
  "$(code "$W")" 'vmhost_pause_clear "$VM"'
has "J5 PAUSED is checked first, ahead of the ordinary VM-state chain" \
  "$(code "$W")" 'if   [ "$PAUSE_ACTIVE" = 1 ];           then VERDICT="PAUSED"'
has "J6 the boot window after an expired pause is bounded, not open-ended" \
  "$(code "$W")" 'RESUME_GRACE_MIN="${RESUME_GRACE_MIN:-30}"'
pause_ln="$(grep -n 'PAUSE_ACTIVE=1; PAUSE_WHY="pause expired' "$W" | head -1 | cut -d: -f1)"  # THE ONE LOUD CASE: past grace, still not up, must fall through to DOWN and page
grace_ln="$(grep -n '# else: grace exhausted' "$W" | head -1 | cut -d: -f1)"
if [ -n "$pause_ln" ] && [ -n "$grace_ln" ] && [ "$pause_ln" -lt "$grace_ln" ]; then
  ok "J7 the grace window is a bound, with the exhausted case named as falling through"
else
  bad "J7 grace exhaustion falls through to DOWN" "expected the bound before its exhausted-case comment"
fi


section "K. the clocksource early warning is guest-side, present under both backends (#805)"
has "K1 read from the guest's own kernel log, not a hypervisor artifact" \
  "$(code "$W")" 'Long readout interval'
# ANCHORED ON THE GUEST CALL ITSELF, not on the first `if [ "$SSHD" ... ]` in
# the file: #1226 put an earlier one above (the host state read, which now runs
# only when the guest does NOT answer), and matching by first-occurrence
# silently moved this assertion onto that block instead.
lr_ssh_ln="$(grep -n 'LONG_READOUT="\$(mssh_n' "$W" | head -1 | cut -d: -f1)"
guest_ln="$(grep -n 'GUEST_JSON="\$(mssh ' "$W" | head -1 | cut -d: -f1)"
guest_else_ln="$(grep -n 'GUEST_ERR="sshd is \$SSHD' "$W" | head -1 | cut -d: -f1)"
if [ -n "$lr_ssh_ln" ] && [ -n "$guest_ln" ] && [ -n "$guest_else_ln" ] \
   && [ "$lr_ssh_ln" -gt "$guest_ln" ] && [ "$lr_ssh_ln" -lt "$guest_else_ln" ]; then
  ok "K2 read only when sshd is answering -- it is a guest probe and costs an ssh"
else
  bad "K2 read only when sshd is answering" "expected the mssh_n call inside the guest-answering branch"
fi
has "K3 the count reaches the payload builder" "$(code "$W")" 'LONG_READOUT="$LONG_READOUT"'
has "K4 merge publishes it" "$(code "$REPO/bin/lib/monkey-watch-merge.py")" 'clocksource'
has "K5 an unreadable/unreachable count is null, not zero" \
  "$(code "$REPO/bin/lib/monkey-watch-merge.py")" '"LONG_READOUT", "").strip().isdigit() else None'

lr_of() {  # <raw mssh_n output> -> the script's own sanitizing pipeline
  local LONG_READOUT="$1"
  case "$LONG_READOUT" in *[!0-9]*|'') LONG_READOUT="" ;; esac
  printf '%s' "$LONG_READOUT"
}
eq "K6 a real count passes through" "$(lr_of '4')" "4"
eq "K7 a legitimate zero count is not conflated with absent" "$(lr_of '0')" "0"
eq "K8 a stalled/failed ssh (empty) stays empty" "$(lr_of '')" ""
eq "K9 stray stderr text is never mistaken for a count" \
  "$(lr_of 'ssh: connect to host monkey port 2224: Connection refused')" ""

has "K10 graded on a RISE against the last applied tick, never an absolute threshold" \
  "$(code "$W")" '"$LONG_READOUT" -gt "$CS_LAST"'
has "K11 the baseline lives beside the verdict state, per-metric not shared" \
  "$(code "$W")" 'CS_STATE="$STATE_FILE.clocksource"'
has "K12 no count at all neither alerts nor advances the baseline" \
  "$(code "$W")" 'if [ -n "$LONG_READOUT" ]; then'

mw_page() { ZM="${3:-120}" bash -c '
  u="https://hf7y.com/monkey/"; h="monkey: $1"; r=$(( ZM - ${#h} - ${#u} - 2 ))
  [ "$r" -lt 0 ] && r=0; w="$2"; [ "${#w}" -gt "$r" ] && w="${w:0:$r}"
  printf "%s\n%s\n%s" "$h" "$w" "$u"' _ "$1" "$2"; }

p="$(mw_page "OK -> DEGRADED" "sshd sent its banner but the session stalled -- no answer in 60s")"
[ "${#p}" -le 140 ] && ok "P1 the DEGRADED page that was refused at 162 chars now fits" \
  || bad "P1 the DEGRADED page that was refused at 162 chars now fits" "got ${#p}"
has "P2 and the reason survives untruncated" "$p" "no answer in 60s"
p="$(mw_page "still DOWN (down 24h, unread past 12h)" "$(printf 'x%.0s' $(seq 1 300))")"
[ "${#p}" -le 140 ] && ok "P3 even a 300-char WHY cannot push the page over the ceiling" \
  || bad "P3 even a 300-char WHY cannot push the page over the ceiling" "got ${#p}"
has "P4 and the status URL is never the part that gets trimmed" "$p" "https://hf7y.com/monkey/"
p="$(mw_page "still DOWN (down 24h, unread past 12h)" "$(printf 'x%.0s' $(seq 1 300))" 110)"
tag="[monkey-watch] "
[ $(( ${#p} + ${#tag} )) -le 140 ] && ok "P6 the page still fits once the relay prepends its [monkey-watch] tag" \
  || bad "P6 the page still fits once the relay prepends its [monkey-watch] tag" "got $(( ${#p} + ${#tag} ))"

refusal='data: {"jsonrpc":"2.0","result":{"content":[{"text":"{\n  \"status\": \"refused\",\n  \"error\": \"rendered message is 785 chars; must be at most 140\"\n}","type":"text"}]}}'
why="$(printf '%s' "$refusal" | grep -oE '\\?"error\\?": ?\\?"[^"\\]*' | sed 's/.*"//' | head -1)"
has "P5 zaxon reports the relay's OWN refusal reason, not 'no relay answered'" "$why" "must be at most 140"

section "Q. an unread probe is not an outage (2026-09-06: OK -> DOWN, \"VM is poweroff\", on a distro up 5 days)"
unk_ln="$(grep -n 'VMSTATE" = "unknown"' "$W" | head -1 | cut -d: -f1)"
down_ln="$(grep -n 'VMSTATE_GRADED" != "running"' "$W" | head -1 | cut -d: -f1)"
if [ -n "$unk_ln" ] && [ -n "$down_ln" ] && [ "$unk_ln" -lt "$down_ln" ]; then
  ok "Q1 an unreadable VM state with sshd answering is caught BEFORE the DOWN rung"
else
  bad "Q1 unknown+answering is caught before DOWN" "a lost wsl.exe call pages Zach as poweroff again"
fi
has "Q2 ...and the graded state, not the published one, is what the DOWN rung reads" \
  "$(code "$W")" 'HOST_READ=blind; VMSTATE_GRADED=running'

# #1226: the watcher spent 30 of 40 ticks calling monkey DEGRADED because its
# OWN wsl.exe call lost interop, alerting Zach on each transition.
has "Q3 a blind host read with the guest answering is OK, and the WHY says what went unread" \
  "$(code "$W")" 'HOST_READ" = blind ];          then VERDICT="OK"'
has "Q4 ...and the blindness is PUBLISHED, so the page can show what was not seen" \
  "$(code "$W")" 'HOST_READ="$HOST_READ"'
guest_ln="$(grep -n 'z "$GUEST_JSON" \];' "$W" | head -1 | cut -d: -f1)"
blind_ln="$(grep -n 'HOST_READ" = blind \];' "$W" | head -1 | cut -d: -f1)"
if [ -n "$guest_ln" ] && [ -n "$blind_ln" ] && [ "$guest_ln" -lt "$blind_ln" ]; then
  ok "Q5 a guest that did not answer still outranks it -- blind never buys an OK on its own"
else
  bad "Q5 the guest rung outranks the blind rung" "a lost host call would mask a failed collection"
fi

# #1226: the tick was spending two interop calls every ten minutes, 288 a day,
# on a driver that loses the vsock about a quarter of the time -- for two facts
# a healthy tick does not need.
vm_read_ln="$(grep -n 'VMSTATE="\$(vmhost_state' "$W" | head -1 | cut -d: -f1)"
banner_ln="$(grep -n 'BANNER="\$(timeout' "$W" | head -1 | cut -d: -f1)"
if [ -n "$vm_read_ln" ] && [ -n "$banner_ln" ] && [ "$banner_ln" -lt "$vm_read_ln" ]; then
  ok "Q6 the guest is asked FIRST -- the banner is the cheaper and better witness"
else
  bad "Q6 the guest is asked before the host" "an unconditional wsl.exe call is back at the top of every tick"
fi
has "Q7 sshd answering IS the VM running, with no interop call to confirm it" \
  "$(code "$W")" 'VMSTATE=running   # proven by the banner'
has "Q7b and the payload says GUEST, never `live` -- a field claiming a read nothing performed is the defect itself" \
  "$(code "$W")" '[ "$HOST_ASKED" = 0 ] && HOST_READ=guest'
has "Q8 the disk fact is cached, so a human-paced fact is not re-read 144 times a day" \
  "$(code "$W")" 'DISK_CACHE'
case "$(code "$W")" in
  *'DISK_AT="$NOW"'*) ok "Q9 ...and only a SUCCESSFUL read restamps it" ;;
  *) bad "Q9 only a successful read restamps the cache" "a failed read that restamps makes a stale fact look fresh" ;;
esac

section "R. alerts are fire-and-forget, not a question (2026-09-09: 113 asks, 0 answers)"
case "$(code "$W")" in
  *zaxon_ask*) bad "R1 no live call to zaxon_ask" "it is back -- alerts will flood the relay's one question slot again" ;;
  *)           ok  "R1 no live call to zaxon_ask" ;;
esac
has "R2 alerting goes through zaxon_send instead" "$(code "$W")" 'zaxon_send'

section "S. the WINDOWS watcher is gone (#1232)"
# monkey-watch-win.sh + its .ps1 were removed on Zach's call 2026-09-18: it read
# the page this watcher publishes, checked staleness and barked. Its own header
# conceded that zaxon is served out of WSL2 and so is down in the very case it
# existed for, leaving the Windows event log -- which nobody reads -- as its
# only reliable leg. Home Assistant reads the same document for the same
# coverage. Deleting it also drops the $HOME/.ssh/id_dexter_win dependency that
# has been unsatisfiable since 2026-08-31.
[ -e "$REPO/bin/monkey-watch-win.sh" ] \
  && bad "S1 the Windows watcher is gone" "bin/monkey-watch-win.sh is back without a decision" \
  || ok "S1 the Windows watcher is gone"
hasnt "S2 ...and nothing in this watcher still reaches for its key" "$(code "$W")" 'id_dexter_win'

summary
