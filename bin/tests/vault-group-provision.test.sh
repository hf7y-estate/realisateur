#!/usr/bin/env bash
set -uo pipefail
. "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib/harness.sh"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT/vault-group-provision.sh"
[ -x "$SCRIPT" ] || { echo "FAIL: $SCRIPT not executable"; exit 1; }

harness_tmp

echo "vault-group-provision.test.sh"

section "A. the argument contract"
"$SCRIPT" --not-a-real-flag >/dev/null 2>&1; eq "A1 unknown flag exits 2" "$?" "2"
"$SCRIPT" --help >/dev/null 2>&1;            eq "A2 --help exits 0" "$?" "0"
OUT="$("$SCRIPT" --help 2>&1)"
has "A3 --help documents the BLIND exit" "$OUT" "BLIND"
has "A4 --help documents the refused-without-root exit" "$OUT" "refused"

section "B. an empty roster is BLIND, not a silent pass"
mkdir -p "$T/emptyhome"
OUT="$(HOME_ROOT="$T/emptyhome" SUDO='' "$SCRIPT" --check 2>&1)"; RC=$?
eq  "B1 no accounts under HOME_ROOT exits 6" "$RC" "6"
has "B2 and says BLIND" "$OUT" "BLIND"
has "B3 and says nothing was measured" "$OUT" "nothing was measured"

section "C. a roster with one account, no privilege needed to read it (SUDO='')"
mkdir -p "$T/home/proj/.claude" "$T/home/zach/.claude"
OUT="$(HOME_ROOT="$T/home" SUDO='' "$SCRIPT" --check --group nonexistent-test-group 2>&1)"; RC=$?
has "C1 the fixture account is listed" "$OUT" "proj"
hasnt "C2 zach is excluded from the roster" "$OUT" "  ..      zach"
eq  "C3 a group that does not exist is a finding (exit 1), not exit 6" "$RC" "1"

section "D. --apply without root is refused, --check never needs it"
if [ "$(id -u)" -eq 0 ]; then
  ok "D1 skipped: running as root"
else
  OUT="$("$SCRIPT" --apply 2>&1)"; RC=$?
  eq  "D1 --apply without root exits 5" "$RC" "5"
  has "D1b and says so" "$OUT" "needs root"
fi
grep -q 'rm -rf' "$SCRIPT" && bad "D2 the script contains an rm -rf" || ok "D2 no rm -rf anywhere in the script"

section "F. the read door (#742): the spool, its clock, and the interlock"
mkdir -p "$T/home2/proj/.claude" "$T/vaultdir" "$T/fakebin"
chmod 2770 "$T/vaultdir"
OUT="$(HOME_ROOT="$T/home2" SUDO='' PATH="$T/fakebin:$PATH" \
       "$SCRIPT" --check --dir "$T/vaultdir" --spool "$T/no-spool" 2>&1)"
has "F1 a missing spool is a finding -- deposits would have nowhere to go" "$OUT" "no-spool does not exist"
has "F2 an undrained spool is a finding -- a queue nothing drains is a backlog" "$OUT" "does not drain the spool"

# SHADOW the real consigne rather than hoping the host has none. $PATH stays on
# the end for coreutils, so a mandark that HAS the build installed answered F3
# with the host's spool-capable copy and failed a test CI kept green.
printf '#!/bin/sh\n# no spool marker here\n' > "$T/fakebin/consigne"; chmod +x "$T/fakebin/consigne"
OUT="$(HOME_ROOT="$T/home2" SUDO='' PATH="$T/fakebin:$PATH" \
       "$SCRIPT" --check --dir "$T/vaultdir" 2>&1)"
has "F3 with no spool-capable consigne on PATH, tightening is REFUSED" "$OUT" "cannot spool"
has "F4 and it names the remedy -- install the build first" "$OUT" "verb build"

printf '#!/bin/sh\n# CONSIGNE_SPOOL\n' > "$T/fakebin/consigne"; chmod +x "$T/fakebin/consigne"
OUT="$(HOME_ROOT="$T/home2" SUDO='' PATH="$T/fakebin:$PATH" \
       "$SCRIPT" --check --dir "$T/vaultdir" 2>&1)"
hasnt "F5 with a spool-capable consigne the interlock stands down" "$OUT" "cannot spool"
has   "F6 and 2770 is still reported as the open door it is" "$OUT" "the read door is open"

chmod 0700 "$T/vaultdir"; chmod g-s "$T/vaultdir"   # numeric chmod does NOT clear setgid on a dir
OUT="$(HOME_ROOT="$T/home2" SUDO='' PATH="$T/fakebin:$PATH" \
       "$SCRIPT" --check --dir "$T/vaultdir" 2>&1)"
has "F7 0700 is the target, and is reported as shut" "$OUT" "read door is shut"

chmod 2700 "$T/vaultdir"
OUT="$(HOME_ROOT="$T/home2" SUDO='' PATH="$T/fakebin:$PATH" \
       "$SCRIPT" --check --dir "$T/vaultdir" 2>&1)"
has "F8 2700 is NOT shut -- a preserved setgid bit must not read as the target" "$OUT" "read door is open"

section "H. the objects inside, not just the door (#742, #1248)"
chmod 0700 "$T/vaultdir"; chmod g-s "$T/vaultdir"
BAND="VAULT_UID_LO=$(id -u) VAULT_UID_HI=$(( $(id -u) + 1 ))"   # this test's own files ARE the self-dev band
hprobe() { env HOME_ROOT="$T/home2" SUDO='' PATH="$T/fakebin:$PATH" \
  VAULT_UID_LO="$1" VAULT_UID_HI="$2" "$SCRIPT" --check --dir "$T/vaultdir" 2>&1; }

OUT="$(hprobe 3000 3100)"
has "H1 a tree with nothing in the band is reported clean, by measurement" "$OUT" "nothing inside"

mkdir -p "$T/vaultdir/.git/objects/ad"
: > "$T/vaultdir/.git/objects/ad/7c23a9"
OUT="$(hprobe "$(id -u)" "$(( $(id -u) + 1 ))")"
has "H2 an object owned by a band account is a finding -- shutting the door reowns nothing" \
  "$OUT" "owned by a self-dev account"
has "H3 and it is COUNTED, so a reader knows the size of what is left" "$OUT" "4 object(s)"
hasnt "H4 --check reowned nothing" "$OUT" "reowned"

OUT="$(hprobe 3000 3100)"
has "H5 the same tree is clean again outside the band -- the band decides, not the path" "$OUT" "nothing inside"

grep -q 'chown -h' "$SCRIPT" && ok "H6 the reown does not follow symlinks out of the vault" \
                             || bad "H6 chown without -h would follow a symlink out of the tree"

section "G. the drain row it writes cannot fail silently"
# The guard-free row is the contract: the old `[ -x $DRAIN ] &&` form exited 0 in
# silence with no drain installed, so it must read as a FINDING, not an ok row.
DBIN="$T/drain.sh"
printf '%s\n' "*/5 * * * * root $DBIN --apply >/dev/null # realisateur:vault-spool-drain:CADENCE" > "$T/cron-guardfree"
printf '%s\n' "*/5 * * * * root [ -x $DBIN ] && $DBIN --apply >/dev/null 2>&1 # realisateur:vault-spool-drain:CADENCE" > "$T/cron-guarded"

OUT="$(HOME_ROOT="$T/home2" SUDO='' PATH="$T/fakebin:$PATH" \
       VAULT_CRON_D="$T/cron-guardfree" VAULT_DRAIN_BIN="$DBIN" \
       "$SCRIPT" --check --dir "$T/vaultdir" 2>&1)"
has "G1 the row runs the drain unconditionally, and keeps stderr for cron to mail" \
    "$OUT" "drains the spool every 5 minutes"

OUT="$(HOME_ROOT="$T/home2" SUDO='' PATH="$T/fakebin:$PATH" \
       VAULT_CRON_D="$T/cron-guarded" VAULT_DRAIN_BIN="$DBIN" \
       "$SCRIPT" --check --dir "$T/vaultdir" 2>&1)"
has "G2 the old [ -x DRAIN ] && DRAIN row is a finding, not an accepted row" \
    "$OUT" "does not drain the spool"

section "E. it is declared, so it reaches a host by a named channel"
. "$ROOT/lib/propagation-set.sh"
ch="$(prop_channel vault-group-provision.sh 2>/dev/null)" || ch=""
eq "E1 prop_channel says provision -- a human runs this once, on nobody's clock" "$ch" "provision"

echo
summary
