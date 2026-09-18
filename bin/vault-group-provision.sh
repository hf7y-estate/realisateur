#!/usr/bin/env bash
set -uo pipefail

CLI_NAME='vault-group-provision.sh'
CLI_SUMMARY='own the vault group, the deposit spool, the vault directory'"'"'s mode and every self-dev account'"'"'s membership -- the arrangement bin/consigne'"'"'s deposit depends on (#597), and the close of the vault'"'"'s read door (#742)'
CLI_USAGE='  vault-group-provision.sh            --check (default): report, write nothing
  vault-group-provision.sh --apply    create/fix the group, the spool, the dir modes, and membership
  (idempotent -- an --apply on a host already at the target changes nothing and says so)'
CLI_FLAGS='--check --apply --group --dir --spool'
CLI_POSITIONAL=any
CLI_EXITS='  0  the host is at the target (or --check found it so)
  1  findings: something is missing or wrong -- read the rows
  5  refused: --apply without root
  6  BLIND: the roster matched no account at all -- nothing was checked, and
     a 0-account pass is NOT a clean result'
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/lib/cli-guard.sh"
cli_guard "$@"

MODE=--check
GROUP="${VAULT_GROUP:-vault}"
DIR="${VAULT_DIR:-/srv/ecosystem1-vault}"
SPOOL="${CONSIGNE_SPOOL:-/srv/vault-spool}"
DIR_MODE_OPEN='2770'  # while deposits still go direct: group only, never world
DIR_MODE_SHUT='0700'  # the target: no self-dev account reads the vault (#742)
CRON_D="${VAULT_CRON_D:-/etc/cron.d/vault-spool-drain}"
DRAIN="${VAULT_DRAIN_BIN:-/usr/local/libexec/selfdev/vault-spool-drain.sh}"
HOME_ROOT="${HOME_ROOT:-/home}"
UID_LO="${VAULT_UID_LO:-3000}"; UID_HI="${VAULT_UID_HI:-3100}"  # the self-dev band, same as bin/monkey-status-collect.py's containment(); the two names are fixture seams, unset in production
SUDO="${SUDO-sudo}"
while [ $# -gt 0 ]; do
  case "$1" in
    --check|--apply) MODE="$1" ;;
    --group) shift; GROUP="${1:-}" ;;
    --dir)   shift; DIR="${1:-}" ;;
    --spool) shift; SPOOL="${1:-}" ;;
    *) cli_die "unexpected argument: $1" ;;
  esac
  shift
done

PASS=0; GAPS=0; BAD=0
ok()  { printf '  OK      %s\n' "$*"; PASS=$((PASS+1)); }
gap() { printf '  MISSING %s\n' "$*"; GAPS=$((GAPS+1)); }
bad() { printf '  BAD     %s\n' "$*"; BAD=$((BAD+1)); }
act() { printf '  DO      %s\n' "$*"; }
die() { printf '\n%s: %s\n' "$CLI_NAME" "$*" >&2; exit "${2:-5}"; }

echo "== vault-group-provision ($MODE) -- $(hostname -s), group $GROUP, dir $DIR, spool $SPOOL =="

[ "$MODE" = --check ] || [ "$(id -u)" -eq 0 ] || die "$MODE needs root (sudo $CLI_NAME $MODE)" 5

accounts() {  # same roster selfdev-permissions-provision.sh derives -- every HOME_ROOT/* with a .claude dir, not a typed list
  local d u
  for d in "$HOME_ROOT"/*/; do
    u="$(basename "$d")"
    [ "$u" = "zach" ] && continue
    $SUDO test -d "$d/.claude" 2>/dev/null || continue
    printf '%s\n' "$u"
  done
}

if [ "$MODE" = --apply ] && ! getent group "$GROUP" >/dev/null 2>&1; then
  groupadd "$GROUP" && act "created group $GROUP"
fi
if getent group "$GROUP" >/dev/null 2>&1; then
  ok "group $GROUP exists ($(getent group "$GROUP" | cut -d: -f4))"
else
  gap "group $GROUP does not exist"
fi

if [ ! -d "$DIR" ]; then
  if [ "$MODE" = --apply ]; then
    install -d -m "$DIR_MODE_OPEN" -o root -g "$GROUP" "$DIR" && act "created $DIR ($DIR_MODE_OPEN root:$GROUP) -- tightened below once a spool-capable consigne is installed"
  else
    gap "$DIR does not exist"
  fi
fi
# The spool deposits go through once the vault is closed. 1730 (#742): create
# by name, never enumerate, never delete another's.
SPOOL_MODE=1730   # sticky + rwx-wx---: create by name, never enumerate, never delete another's
if [ ! -d "$SPOOL" ]; then
  if [ "$MODE" = --apply ]; then
    install -d -m "$SPOOL_MODE" -o root -g "$GROUP" "$SPOOL" && act "created $SPOOL ($SPOOL_MODE root:$GROUP)"
  else
    gap "$SPOOL does not exist -- there is nowhere for a deposit to go once the vault is closed"
  fi
fi
if [ -d "$SPOOL" ]; then
  sm="$(stat -c '%04a %G' "$SPOOL" 2>/dev/null)"
  if [ "$sm" = "$SPOOL_MODE $GROUP" ]; then
    ok "$SPOOL is $sm"
  elif [ "$MODE" = --apply ]; then
    chgrp "$GROUP" "$SPOOL" && chmod "$SPOOL_MODE" "$SPOOL" && act "$SPOOL was '$sm' -- set to $SPOOL_MODE $GROUP"
  else
    bad "$SPOOL is '$sm', expected '$SPOOL_MODE $GROUP'"
  fi
fi

# No `[ -x $DRAIN ] &&` guard and no `2>&1`: with the drain absent that test was
# false, so the row exited 0 in silence and "no drain" read exactly like "empty
# spool". Absence must reach stderr; the drain's summary still goes to stdout.
CRON_ROW="*/5 * * * * root $DRAIN --apply >/dev/null # realisateur:vault-spool-drain:CADENCE"
if [ "$(cat "$CRON_D" 2>/dev/null)" = "$CRON_ROW" ]; then
  ok "$CRON_D drains the spool every 5 minutes"
elif [ "$MODE" = --apply ]; then
  printf '%s\n' "$CRON_ROW" > "$CRON_D" && chmod 644 "$CRON_D" && act "wrote $CRON_D"
else
  gap "$CRON_D does not drain the spool -- requests would queue and never deposit"
fi

# The vault directory. TARGET 0700 (#742); the old 2775 was readable to EVERY
# account on the host. An older `consigne` cannot spool, so it is ASKED first.
consigne_spools() {
  local c; c="$(command -v consigne 2>/dev/null)" || return 1
  [ -n "$c" ] || return 1
  grep -q 'CONSIGNE_SPOOL' "$(readlink -f "$c")" 2>/dev/null
}
if [ -d "$DIR" ]; then
  # %04a: a numeric chmod leaves a directory's setgid bit, so 2775 lands at
  # 2700 and 3 digits read that as the target.
  m="$(stat -c '%04a' "$DIR" 2>/dev/null)"
  g="$(stat -c '%G' "$DIR" 2>/dev/null)"
  if [ "$m" = "$DIR_MODE_SHUT" ]; then
    ok "$DIR is $m -- the read door is shut (#742)"
  elif ! consigne_spools; then
    bad "$DIR is '$m $g' and the installed \`consigne\` cannot spool, so tightening it
          would break every deposit on this host. Install the verb build carrying
          #742's consigne first, then re-run --apply."
    if [ "$m $g" != "$DIR_MODE_OPEN $GROUP" ] && [ "$MODE" = --apply ]; then
      chgrp "$GROUP" "$DIR" && chmod "$DIR_MODE_OPEN" "$DIR" && act "$DIR was '$m $g' -- held at $DIR_MODE_OPEN $GROUP until the spool-capable consigne lands"
    fi
  elif [ "$MODE" = --apply ]; then
    # The second chmod is not redundant (coreutils 9.4).
    chmod "$DIR_MODE_SHUT" "$DIR" && chmod ug-s "$DIR" \
      && act "$DIR was '$m $g' -- set to $DIR_MODE_SHUT; the read door is now SHUT (#742)"
  else
    bad "$DIR is '$m $g', expected '$DIR_MODE_SHUT' -- the read door is open"
  fi

  # THE OBJECTS, NOT JUST THE DOOR (#742, #1248). Shutting the door stops NEW
  # account-owned files; it reowns nothing already inside. chezz and crt still
  # owned 27 objects between them from two deposits made direct, before the
  # spool -- and monkey-status-collect.py's containment() read that, correctly,
  # as "not contained" on hf7y.com/monkey every single day. This script is that
  # finding's only actor, so the reown belongs here and not in a one-off chown:
  # a mode this script owns and an ownership nothing owns is how the row came
  # back. Same uid band that probe uses. Everything the drain writes from here
  # is root's, so the target is simply whoever owns $DIR.
  own="$(stat -c '%u:%g' "$DIR" 2>/dev/null)"
  stray="$(find "$DIR" -mindepth 1 -uid "+$((UID_LO - 1))" -uid "-$UID_HI" -print 2>/dev/null)"
  if [ -z "$own" ]; then
    bad "cannot read $DIR's own ownership -- not reowning anything on a guess"
  elif [ -z "$stray" ]; then
    ok "nothing inside $DIR is owned by a self-dev account"
  elif [ "$MODE" = --apply ]; then
    n="$(printf '%s\n' "$stray" | grep -c .)"
    if printf '%s\n' "$stray" | xargs -r -d '\n' chown -h "$own"; then
      act "$n object(s) in $DIR reowned to $own -- containment() has nothing left to report here"
    else
      bad "could not reown $n object(s) in $DIR"
    fi
  else
    gap "$(printf '%s\n' "$stray" | grep -c .) object(s) in $DIR are owned by a self-dev account, not $own"
  fi
fi

roster="$(accounts)"
if [ -z "$roster" ]; then
  echo "BLIND: no self-dev account found under $HOME_ROOT -- nothing was checked." >&2
  echo "$CLI_NAME: nothing was measured. This is NOT a clean result." >&2
  exit 6
fi
missing=""
for a in $roster; do
  ingrp=no; id -nG "$a" 2>/dev/null | tr ' ' '\n' | grep -qx "$GROUP" && ingrp=yes
  if [ "$ingrp" = no ] && [ "$MODE" = --apply ]; then
    usermod -aG "$GROUP" "$a" && { act "$a added to group $GROUP"; ingrp=yes; }
  fi
  printf '  ..      %-16s group=%s\n' "$a" "$ingrp"
  [ "$ingrp" = yes ] || missing="$missing $a"
done
[ -z "$missing" ] && ok "every self-dev account is in group $GROUP" \
                  || gap "not in group $GROUP:$missing"

echo
printf '%s (%s): %d ok, %d missing, %d bad\n' "$CLI_NAME" "$MODE" "$PASS" "$GAPS" "$BAD"
if [ "$MODE" = --check ]; then
  [ "$GAPS" -eq 0 ] && [ "$BAD" -eq 0 ] && exit 0
  echo "Next: sudo $CLI_NAME --apply"
  exit 1
fi
[ "$GAPS" -eq 0 ] && [ "$BAD" -eq 0 ] && exit 0
exit 1
