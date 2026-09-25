#!/usr/bin/env bash
# monkey-watch.sh -- publish monkey's status on a schedule, FROM DEXTER, and
# alert when it changes state.
#
# TRAPS (the rest of this header is in the vault):
# WHY THIS EXISTS (#274). PUBLISHING MUST NOT REQUIRE THE THING THAT BROKE.
# The predecessor published only on a successful ssh collection, so an
# unreachable monkey rendered as the healthy world from before it went away.
# THE COLLECTOR IS THE SOURCE OF THE ACCOUNT ROWS. THIS SCRIPT IS NOT.
# monkey-status-collect.py runs as root ON monkey and reads each account's real
# crontab and ledger; a missing ledger on an ARMED account is a finding, not a
# blank. None of that is derivable from dexter.
#
# Deleted by #511: a reachability scan cannot see an off-host caller, and
# bin/lib/cron-invoked.tsv is where they are written down instead.

set -uo pipefail

CLI_NAME='monkey-watch'
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VM="${VM:-monkey}"
# OFF the tailnet: the PORT selects monkey -- 2223 is Ubuntu's own sshd here.
MONKEY_HOST="${MONKEY_HOST:-127.0.0.1}"
MONKEY_PORT="${MONKEY_PORT:-2224}"
SSH_KEY="${SSH_KEY:-$HOME/.ssh/id_dexter_monkey}"
COLLECTOR="${COLLECTOR:-$HERE/bin/monkey-status-collect.py}"
PAGE_SRC="${PAGE_SRC:-$HERE/share/monkey-status.html}"
STATE_FILE="${STATE_FILE:-$HOME/.local/state/monkey-watch.last}"
ALERT_EVERY_H="${ALERT_EVERY_H:-12}"
# The dexter cron cadence, DECLARED so the page carries a valid_until and can
# tell "monkey is down" from "the watcher stopped".
CADENCE_MIN="${CADENCE_MIN:-10}"
GRACE_MIN="${GRACE_MIN:-20}"
. "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib/estate-set.sh"
PUBLISH_REPO="${PUBLISH_REPO:-$GH_ESTATE_SITE_OWNER/$GH_ESTATE_SITE_REPO}"
PUBLISH_DIR="${PUBLISH_DIR:-monkey}"
# shellcheck source=lib/zaxon.sh
. "$HERE/bin/lib/zaxon.sh"
# shellcheck source=lib/monkey-watch-alert.sh
. "$HERE/bin/lib/monkey-watch-alert.sh"
. "$HERE/bin/lib/vmhost.sh"
APPLY=0
[ "${1:-}" = "--apply" ] && APPLY=1

die() { printf '%s: FAIL: %s\n' "$CLI_NAME" "$*" >&2; exit 2; }

# --install-cadence below targets the host pin, never $BASH_SOURCE: `readlink -f`
# on a copy under the pin resolves THROUGH it to a dated build and freezes the
# row on that build. Ground truth on dexter (2026-09-15): the line actually
# installed still wraps a live `git pull --ff-only` clone in `flock`, not this
# path -- --install-cadence was never run to replace it.
CRON_TAG='# realisateur:monkey-watch:WATCH'
CRON_SPEC="${MONKEY_WATCH_CRON_SPEC:-*/10 * * * *}"
if [ "${1:-}" = "--install-cadence" ]; then
  # shellcheck source=lib/propagation-set.sh
  . "$HERE/bin/lib/propagation-set.sh"
  self="$PROP_HOST_PIN/realisateur/bin/monkey-watch.sh"
  line="$CRON_SPEC PATH=/usr/local/bin:/usr/bin:/bin $self --apply >> \$HOME/.local/state/monkey-watch.log 2>&1 $CRON_TAG"
  if [ "${2:-}" != "--apply" ]; then
    echo "  would   install into $(id -un)'s crontab: $line"; exit 0
  fi
  ( crontab -l 2>/dev/null | grep -v 'realisateur:monkey-watch:WATCH'; printf '%s\n' "$line" ) | crontab -
  if crontab -l 2>/dev/null | grep -q 'realisateur:monkey-watch:WATCH'; then
    echo "  OK      cadence in $(id -un)'s crontab (re-read, not asserted): $line"; exit 0
  fi
  echo "  BAD     the cadence is NOT in the crontab -- nothing will watch monkey" >&2
  exit 1
fi

vmhost_require || die "VBoxManage not at $VMHOST_VBOX -- this must run on the VM host (dexter)."
[ -f "$COLLECTOR" ] || die "collector not found at $COLLECTOR.
  This runs from a repo-shaped tree -- a checkout, or the same layout in a
  verb build -- so carry it (bin/lib/carries.tsv), never copy it next to me."

# ONE AT A TIME (#629): the tick is every 10 minutes and a stalled run outlives
# it -- seven stacked on 2026-08-25 without this.
# shellcheck source=lib/cron-lock.sh
. "$HERE/bin/lib/cron-lock.sh"
cron_lock monkey-watch

NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

# --- guest-side: best effort ------------------------------------------------
# THE SSH BANNER IS THE PROBE, NOT A TCP CONNECT. A read-only root accepts TCP
# and then resets at key exchange, so a port check reports green on precisely
# the failure this watcher exists to catch.
BANNER="$(timeout 8 bash -c "exec 3<>/dev/tcp/$MONKEY_HOST/$MONKEY_PORT && head -c 12 <&3" 2>/dev/null || true)"
case "$BANNER" in
  SSH-2.0*) SSHD="answering" ;;
  '')       SSHD="silent" ;;
  *)        SSHD="reset" ;;
esac

# --- host-side: consulted ONLY when its answer can change the verdict ---------
# WHY THIS IS NOT A HEARTBEAT (#1226). `wsl.exe` loses the vsock on about a
# quarter of calls here -- `ERROR: UtilAcceptVsock:273: accept4 failed 110`,
# ETIMEDOUT, ~40s a miss -- and this tick was spending TWO of those calls every
# ten minutes, 288 a day, for two facts it did not need:
#   VM state -- sshd answering IS the distro running. The host is the only
#     witness in exactly one case: the guest is silent, and someone has to say
#     whether it is powered off or hung. That case is worth 40s and a retry.
#   the disk  -- where the vhdx lives changes when a HUMAN moves it. Asking 144
#     times a day cannot catch it sooner than the next tick, and every ask was
#     another chance to publish a blind row.
# So a healthy tick now makes NO interop call at all, and the bug cannot
# produce a finding on a host that is fine.
HOST_ASKED=0
if [ "$SSHD" = "answering" ]; then
  VMSTATE=running   # proven by the banner, not inferred from it
else
  VMSTATE="$(vmhost_state "$VM")"; HOST_ASKED=1
fi

PSTATUS="$(vmhost_pause_status "$VM" "$NOW")"  # #704: repose only writes the declaration -- THIS TICK is the resume actuator, so a missed one costs at most CADENCE_MIN
PKIND="${PSTATUS%% *}"; PWHEN="${PSTATUS#* }"
if [ "$PKIND" = EXPIRED ]; then
  vmhost_start "$VM" >/dev/null 2>&1
  vmhost_pause_mark_resumed "$VM" "$NOW"
  VMSTATE="$(vmhost_state "$VM")"; HOST_ASKED=1   # the resume actuator just fired: this is the one read worth an interop call on a live guest
  PKIND="RESUMING"; PWHEN="$NOW"
fi

# WHERE THE DISK LIVES IS A PUBLISHED FACT, not trivia: the whole outage was a
# virtual disk on an external USB drive that logged 1580 controller errors in a
# week. If this ever reads EXTERNAL-USB again, someone reverted the fix and the
# page should say so rather than waiting to be asked.
# CACHED, WITH THE TIME IT WAS READ. A human moves this, so re-reading every
# ten minutes buys nothing and costs an interop call. A failed read keeps the
# last value AND its original timestamp -- it never restamps, so a stale fact
# cannot present itself as a fresh one (#1226).
DISK_CACHE="${DISK_CACHE:-$STATE_FILE.disk}"
DISK_MAX_AGE_H="${DISK_MAX_AGE_H:-24}"
DISK=""; DISK_AT=""
[ -r "$DISK_CACHE" ] && IFS=$'\t' read -r DISK_AT DISK < "$DISK_CACHE"
disk_fresh=0
if [ -n "$DISK_AT" ]; then
  then_s="$(date -u -d "$DISK_AT" +%s 2>/dev/null || echo 0)"
  now_s="$(date -u -d "$NOW" +%s 2>/dev/null || echo 0)"
  [ "$then_s" -gt 0 ] && [ $(( now_s - then_s )) -lt $(( DISK_MAX_AGE_H * 3600 )) ] && disk_fresh=1
fi
if [ "$disk_fresh" = 0 ]; then
  fresh_disk="$(vmhost_disk_raw "$VM")"
  if [ -n "$fresh_disk" ]; then
    DISK="$fresh_disk"; DISK_AT="$NOW"
    if [ "$APPLY" = 1 ]; then
      mkdir -p "$(dirname "$DISK_CACHE")"
      printf '%s\t%s\n' "$DISK_AT" "$DISK" > "$DISK_CACHE"
    fi
  fi
fi
DISK_HOME="$(vmhost_classify_disk "$DISK")"

# --- host-side: the virtual clock -------------------------------------------
# realisateur#630. Nanoseconds with SPACE separators: strip them or 41.8h reads
# as 0.0h forever. Pinned by monkey-watch.test.sh I6 with the real log line.
CLOCK_DRIFT_H=""
LOGDIR="$(vmhost_logdir "$VM")"
if [ -n "$LOGDIR" ]; then
  VBOXLOG="$LOGDIR/VBox.log"
  if [ -r "$VBOXLOG" ]; then
    CLOCK_DRIFT_H="$(grep -o 'offVirtualSyncGivenUp=[0-9 ]*' "$VBOXLOG" 2>/dev/null \
      | tail -1 | cut -d= -f2 | tr -d ' ' \
      | awk 'length($0)>0 {printf "%.1f", $0/3600000000000}')"
  fi
fi

# NOTE THE MISSING -n. `ssh -n` redirects stdin from /dev/null, which silently
# feeds the collector an EMPTY program -- it ran, printed nothing usable, and
# the watcher correctly reported DEGRADED instead of publishing a lie. Keep
# stdin free here; mssh_n below is the variant for calls that send nothing.
# EVERY ssh IS DEADLINED. ConnectTimeout bounds the CONNECT only, so a monkey
# that completes TCP, sends its banner and then stalls in auth hangs these
# forever -- and the banner probe above reports "answering" throughout, because
# the banner does arrive. Measured 2026-08-25: seven --apply runs stacked up,
# each holding an ssh, while hf7y.com/monkey stayed frozen on the last healthy
# publish. The watcher that exists to report monkey being down inherited the
# hang instead. Its header already tells this story about REFUSING to publish;
# this is the same failure by a slower route.
SSH_DEADLINE="${SSH_DEADLINE:-180}"
mssh()   { timeout "$SSH_DEADLINE" ssh -i "$SSH_KEY" -p "$MONKEY_PORT" -o BatchMode=yes -o ConnectTimeout=20 \
               -o StrictHostKeyChecking=accept-new "$MONKEY_HOST" "$@" 2>/dev/null; }
mssh_n() { timeout "$SSH_DEADLINE" ssh -n -i "$SSH_KEY" -p "$MONKEY_PORT" -o BatchMode=yes -o ConnectTimeout=20 \
               -o StrictHostKeyChecking=accept-new "$MONKEY_HOST" "$@" 2>/dev/null; }

GUEST_JSON=""; GUEST_ERR=""; ROOTMOUNT=""; UPTIME=""; LONG_READOUT=""
if [ "$SSHD" = "answering" ]; then
  # Fed over STDIN rather than installed on monkey, so the version that runs is
  # the version in this checkout -- no second copy to drift.
  GUEST_JSON="$(mssh 'sudo -n python3 -' < "$COLLECTOR")"; guest_rc=$?
  if ! printf '%s' "$GUEST_JSON" | python3 -c 'import json,sys; d=json.load(sys.stdin); sys.exit(0 if isinstance(d.get("accounts"),list) else 1)' 2>/dev/null; then
    # 124 is `timeout`'s. A stalled ssh and a collector that answered badly are
    # different outages and the page said the second when it meant the first.
    if [ "$guest_rc" -eq 124 ]; then
      GUEST_ERR="sshd sent its banner but the session stalled -- no answer in ${SSH_DEADLINE}s"
    else
      GUEST_ERR="collector ran but returned no usable accounts array"
    fi
    GUEST_JSON=""
  fi
  ROOTMOUNT="$(mssh_n 'mount | grep " / " | grep -o "(r[wo]" | tr -d "("' || true)"
  UPTIME="$(mssh_n 'uptime -p' || true)"
  LONG_READOUT="$(mssh_n "journalctl -k -b 2>/dev/null | grep -c 'Long readout interval'" || true)"  # #805: guest-side successor to CLOCK_DRIFT_H above -- offVirtualSyncGivenUp is VMM-only and absent under WSL2 (#804), this reads identically under either backend, same grammar as provision/monkey-wsl2/constate.sh
  case "$LONG_READOUT" in *[!0-9]*|'') LONG_READOUT="" ;; esac  # ssh failure or stray stderr reads as absent, never as a count
else
  GUEST_ERR="sshd is $SSHD -- the collector could not be run"
fi

RESUME_GRACE_MIN="${RESUME_GRACE_MIN:-30}"  # bounds RESUMING after an expired pause; past it and still not up is DOWN, loud -- the resume actuator's own failure mode
PAUSE_ACTIVE=0; PAUSE_WHY=""
case "$PKIND" in
  PAUSED)
    PAUSE_ACTIVE=1; PAUSE_WHY="declared pause, resumes $PWHEN"
    ;;
  RESUMING)
    if [ "$VMSTATE" = running ] && [ "$SSHD" = answering ]; then
      vmhost_pause_clear "$VM"   # the pause cycle is complete
    else
      resumed_s="$(date -u -d "$PWHEN" +%s 2>/dev/null || echo 0)"
      now_s="$(date -u -d "$NOW" +%s 2>/dev/null || echo 0)"
      if [ $(( now_s - resumed_s )) -lt $(( RESUME_GRACE_MIN * 60 )) ]; then
        PAUSE_ACTIVE=1; PAUSE_WHY="pause expired, resume triggered $PWHEN -- waiting for boot"
      fi  # else: grace exhausted and still not up -- fall through to DOWN, loud
    fi
    ;;
esac

# A LOST HOST-SIDE CALL IS NOT A SICK GUEST (#1226). `VMSTATE" = "unknown"`
# while sshd answers means wsl.exe lost the vsock -- and sshd answering, plus a
# root collection that returned accounts, is the very thing the host read was
# reaching for. The watcher graded monkey on its own blindness for it: 30 of 40
# ticks on 2026-09-18, each transition spending a Zaxon alert. The unread
# fields stay unread and `host_read: blind` publishes the loss; what stops is
# calling the guest degraded because the observer could not see.
# guest = the host was never asked, because the banner already answered. It is
# NOT "live": a field that says it was read when nothing read it is the defect
# this whole change is about.
HOST_READ=live; VMSTATE_GRADED="$VMSTATE"
[ "$HOST_ASKED" = 0 ] && HOST_READ=guest
if [ "$HOST_ASKED" = 1 ] && [ "$VMSTATE" = "unknown" ] && [ "$SSHD" = "answering" ]; then
  HOST_READ=blind; VMSTATE_GRADED=running
fi

# --- verdict ----------------------------------------------------------------
# read-only root is called out separately from "down": it is the specific
# recurring failure here, and it looks like up from most angles.
if   [ "$PAUSE_ACTIVE" = 1 ];           then VERDICT="PAUSED";   WHY="$PAUSE_WHY"
elif [ "$VMSTATE_GRADED" != "running" ]; then VERDICT="DOWN";    WHY="VM is $VMSTATE"
elif [ "$SSHD" != "answering" ];        then VERDICT="DOWN";     WHY="VM running but sshd is $SSHD"
elif [ "$ROOTMOUNT" = "ro" ];           then VERDICT="DEGRADED"; WHY="root is mounted READ-ONLY"
elif [ "$DISK_HOME" = "EXTERNAL-USB" ]; then VERDICT="DEGRADED"; WHY="disk is back on the external USB drive"
elif [ -z "$GUEST_JSON" ];              then VERDICT="DEGRADED"; WHY="${GUEST_ERR:-guest detail unavailable}"
elif [ "$HOST_READ" = blind ];          then VERDICT="OK";       WHY="sshd answering, root rw, guest collection returned -- the host-side read lost interop, so vm_state and disk are unread (#1226)"
else                                         VERDICT="OK";       WHY="running, sshd answering, root rw, disk internal"
fi

SCREENSHOT=""
if [ "$VERDICT" = DOWN ]; then
  vmhost_screenshot "$VM" "$WORK/console.png"
  [ -s "$WORK/console.png" ] && SCREENSHOT=1
fi

payload="$(GUEST_JSON="$GUEST_JSON" NOW="$NOW" VMSTATE="$VMSTATE" DISK="$DISK" \
  CLOCK_DRIFT_H="$CLOCK_DRIFT_H" LONG_READOUT="$LONG_READOUT" \
  CADENCE_MIN="$CADENCE_MIN" GRACE_MIN="$GRACE_MIN" \
  DISK_HOME="$DISK_HOME" SSHD="$SSHD" UPTIME="$UPTIME" ROOTMOUNT="$ROOTMOUNT" \
  DISK_AT="$DISK_AT" \
  HOST_READ="$HOST_READ" CLOCK_DRIFT_APPLIES="$([ -n "$LOGDIR" ] && echo 1)" \
  VERDICT="$VERDICT" WHY="$WHY" GUEST_ERR="$GUEST_ERR" SCREENSHOT="$SCREENSHOT" \
  python3 "$HERE/bin/lib/monkey-watch-merge.py")"
[ -n "$payload" ] || die "payload builder produced nothing -- publishing nothing."

if [ "$APPLY" = 1 ]; then  # realisateur#850: the unrotated cron log grew 14.2 MB/day on this dump -- status.json (:267) is the payload's real channel, stdout is a human's
  printf '%s: %s -- %s\n' "$CLI_NAME" "$VERDICT" "$WHY"
else
  printf '%s\n' "$payload"
  printf '%s: %s -- %s\n' "$CLI_NAME" "$VERDICT" "$WHY"
  printf '%s: NOT published (need --apply)\n' "$CLI_NAME"
  exit 0
fi

mkdir -p "$(dirname "$STATE_FILE")"
LAST="$(cat "$STATE_FILE" 2>/dev/null || echo "")"
DECISION="$(mw_alert_decide "$VERDICT" "$LAST" "$STATE_FILE" "$ALERT_EVERY_H" "$NOW")"
set -- $DECISION
if [ "$1" != NONE ]; then
  case "$1" in
    TRANSITION) LABEL="$2 -> $3" ;;
    PERSIST)    LABEL="still $2 (down ${3}h, unread past ${ALERT_EVERY_H}h)" ;;
  esac
  ZAXON_MAX="${ZAXON_MAX:-110}"
  alert_url="https://$GH_ESTATE_SITE/$PUBLISH_DIR/"
  alert_head="monkey: $LABEL"
  room=$(( ZAXON_MAX - ${#alert_head} - ${#alert_url} - 2 ))
  [ "$room" -lt 0 ] && room=0
  alert_why="$WHY"
  [ "${#alert_why}" -gt "$room" ] && alert_why="${alert_why:0:$room}"
  msg="$alert_head
$alert_why
$alert_url"
  sent="$(zaxon_send "$msg" monkey-watch)"
  if [ -n "$sent" ]; then
    mw_alert_mark_sent "$STATE_FILE" "$NOW"
    printf '%s: alerted (%s)\n' "$CLI_NAME" "$LABEL"
  fi
fi

CS_STATE="$STATE_FILE.clocksource"  # #805 early warning: graded on a RISE against the last applied tick, same as etat.sh grades constate.sh's before/after snapshot -- #530 called this "the only warning that the box is about to go"
if [ -n "$LONG_READOUT" ]; then  # no count at all (unreachable, or the trip failed) neither alerts nor advances the baseline -- silence here must not read as "still 0"
  CS_LAST="$(cat "$CS_STATE" 2>/dev/null || echo "")"
  if [ -n "$CS_LAST" ] && [ "$LONG_READOUT" -gt "$CS_LAST" ] 2>/dev/null; then
    cs_url="https://$GH_ESTATE_SITE/$PUBLISH_DIR/"
    cs_head="monkey: clocksource stalls rising ${CS_LAST}->${LONG_READOUT}"
    cs_msg="$cs_head
$cs_url"
    cs_sent="$(zaxon_send "$cs_msg" monkey-watch)"
    [ -n "$cs_sent" ] && printf '%s: clocksource alerted (%s)\n' "$CLI_NAME" "$cs_head"
  fi
  printf '%s\n' "$LONG_READOUT" > "$CS_STATE"
fi

# --- publish ----------------------------------------------------------------
# ALWAYS publishes. There is deliberately no "refusing to publish an empty
# page" guard: an empty accounts[] IS the report when monkey is unreachable,
# and refusing to publish it is exactly what hid the 2026-08-14 outage.
gh repo clone "$PUBLISH_REPO" "$WORK/site" -- -q --depth 1 2>/dev/null \
  || { echo "$CLI_NAME: could not clone $PUBLISH_REPO -- nothing published" >&2; exit 1; }
mkdir -p "$WORK/site/$PUBLISH_DIR"
printf '%s\n' "$payload" > "$WORK/site/$PUBLISH_DIR/status.json"
[ -f "$PAGE_SRC" ] && cp "$PAGE_SRC" "$WORK/site/$PUBLISH_DIR/index.html"
rm -f "$WORK/site/$PUBLISH_DIR/console.png"
[ -n "$SCREENSHOT" ] && cp "$WORK/console.png" "$WORK/site/$PUBLISH_DIR/console.png"
cd "$WORK/site" || die "could not enter the site clone"
if [ -n "$(git status --porcelain "$PUBLISH_DIR")" ]; then
  git add "$PUBLISH_DIR"
  git -c user.name='monkey-watch' -c user.email="noreply@$GH_ESTATE_SITE" \
      commit -q -m "monkey-watch: $VERDICT ($WHY)"
  git push -q || { echo "$CLI_NAME: push failed" >&2; exit 1; }
  printf '%s: published %s\n' "$CLI_NAME" "$VERDICT"
else
  printf '%s: no change to publish\n' "$CLI_NAME"
fi
