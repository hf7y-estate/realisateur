#!/usr/bin/env bash
# selfdev-app-key.sh -- place the ONE self-dev GitHub App credential where
# every account on this host reads it, and retire the per-account copies.
#
# RUN ON THE SELF-DEV HOST, AS ROOT:
#
#   selfdev-app-key.sh                     --check (default): report, write nothing
#   selfdev-app-key.sh --apply --from <pem> --app-id <id>
#   selfdev-app-key.sh --apply             (re-run; sources from the host copy)
#   selfdev-app-key.sh --retire-copies     remove ~/.config/selfdev/ per account
#
# WHY, in one line: the same App key was on disk under four names across two
# hosts, and the script that converges an account looked for a fifth. See
# bin/lib/selfdev-app-key.sh's header for the full account and the layout.
#
# IDEMPOTENT: --apply on a host already at the target changes nothing and says
# so. REVERSIBLE: --retire-copies is the only step that deletes, it is a
# separate flag, and it refuses unless the host-wide key is in place AND
# readable by the account it is about to strip. Restoring one copy is
# `install -m 600 -o <a> -g <a> /etc/selfdev/app.pem ~<a>/.config/selfdev/app.pem`.
#
# THE ORDER MATTERS AND IS ENFORCED: place host-wide, prove each account can
# read it, and only then remove the copies. The other way round is a fleet-wide
# outage with no credential to fall back to.
set -uo pipefail

CLI_NAME='selfdev-app-key.sh'
CLI_SUMMARY='place the one self-dev GitHub App credential host-wide (/etc/selfdev), and retire the per-account copies'
CLI_USAGE='  selfdev-app-key.sh                          --check (default): report, write nothing
  selfdev-app-key.sh --apply --from <pem> --app-id <id>
                                              place the key host-wide, create the group,
                                              add every uid 3000-3099 account to it
  selfdev-app-key.sh --apply                  re-run once placed (idempotent)
  selfdev-app-key.sh --retire-copies          remove each account'"'"'s ~/.config/selfdev/
                                              copy, ONLY once host-wide is proven readable'
CLI_FLAGS='--check --apply --retire-copies --from --app-id --owner --uid-min --uid-max'
# `any`, not `none`: cli-guard validates argv BEFORE this script's own parser
# runs, so with `none` the VALUE of every --from/--app-id/--uid-min is rejected
# as a stray positional. Caught by bin/tests/selfdev-app-key.test.sh case E2,
# which could not even reach --check. Stray positionals are still refused --
# by the parser below, which is the thing that knows which flags take values.
CLI_POSITIONAL=any
CLI_EXITS='  0  the host is at the target (or --check found it so)
  1  findings: something is missing or wrong -- read the rows
  5  refused: a step could not be completed safely (say, retiring copies while
     an account cannot read the host-wide key)'
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/lib/cli-guard.sh"
cli_guard "$@"
. "$HERE/lib/selfdev-app-key.sh"

. "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib/estate-set.sh"
MODE=--check; FROM=""; APP_ID=""; OWNER="${SELFDEV_GH_OWNER:-$GH_ESTATE_OWNER}"
UMIN="${CRED_UID_MIN:-3000}"; UMAX="${CRED_UID_MAX:-3099}"
while [ $# -gt 0 ]; do
  case "$1" in
    --check|--apply|--retire-copies) MODE="$1" ;;
    --from)    shift; FROM="${1:-}" ;;
    --app-id)  shift; APP_ID="${1:-}" ;;
    --owner)   shift; OWNER="${1:-}" ;;
    --uid-min) shift; UMIN="${1:-}" ;;
    --uid-max) shift; UMAX="${1:-}" ;;
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

CONF="$SELFDEV_APP_CONF_DEFAULT"; PEM="$SELFDEV_APP_PEM_DEFAULT"
echo "== selfdev-app-key ($MODE) -- $(hostname -s), dir $SELFDEV_APP_DIR, group $SELFDEV_APP_GROUP =="

accounts() { awk -F: -v lo="$UMIN" -v hi="$UMAX" '$3>=lo && $3<=hi {print $1}' /etc/passwd; }

[ "$MODE" = --check ] || [ "$(id -u)" -eq 0 ] || die "$MODE needs root (sudo $CLI_NAME $MODE)" 2

# --- where the key can come from, if it is not here yet ----------------------
# Any account's copy will do and they are all the same bytes -- which is the
# defect, and also, exactly once, the migration path out of it.
find_source() {
  local a
  [ -n "$FROM" ] && { printf '%s' "$FROM"; return 0; }
  [ -r "$PEM" ]  && { printf '%s' "$PEM"; return 0; }
  for a in $(accounts); do
    local c="/home/$a/.config/selfdev/app.pem"
    [ -r "$c" ] && { printf '%s' "$c"; return 0; }
  done
  return 1
}

# --- probe -------------------------------------------------------------------
if [ -f "$PEM" ]; then
  m="$(stat -c '%a %U:%G' "$PEM" 2>/dev/null)"
  [ "$m" = "640 root:$SELFDEV_APP_GROUP" ] \
    && ok "$PEM is $m" \
    || bad "$PEM is '$m', expected '640 root:$SELFDEV_APP_GROUP'"
else
  gap "$PEM does not exist -- no host-wide key"
fi
if [ -r "$CONF" ]; then
  conf_id="$(sed -n 's/^SELFDEV_APP_ID=//p' "$CONF" | tail -1)"
  conf_key="$(sed -n 's/^SELFDEV_APP_KEY=//p' "$CONF" | tail -1)"
  [ "$conf_key" = "$PEM" ] && ok "$CONF names the host-wide key" \
                           || bad "$CONF names SELFDEV_APP_KEY=$conf_key, not $PEM"
  [ -n "$conf_id" ] && ok "App id $conf_id" || bad "$CONF declares no SELFDEV_APP_ID"
else
  gap "$CONF does not exist"
fi
if getent group "$SELFDEV_APP_GROUP" >/dev/null 2>&1; then
  members="$(getent group "$SELFDEV_APP_GROUP" | cut -d: -f4)"
  ok "group $SELFDEV_APP_GROUP exists (${members:-no members})"
else
  gap "group $SELFDEV_APP_GROUP does not exist"
fi

# Per-account state: is it in the group, can it READ the host-wide key, and
# does a stale private copy survive? The read is done AS the account, because
# that is the only thing that answers the question.
copies=0; unreadable=""
for a in $(accounts); do
  ingrp=no; id -nG "$a" 2>/dev/null | tr ' ' '\n' | grep -qx "$SELFDEV_APP_GROUP" && ingrp=yes
  canread=no
  [ -f "$PEM" ] && sudo -n -u "$a" head -c 1 -- "$PEM" >/dev/null 2>&1 && canread=yes
  copy=no; [ -e "/home/$a/.config/selfdev/app.pem" ] && { copy=yes; copies=$((copies+1)); }
  printf '  ..      %-16s group=%-3s can-read=%-3s private-copy=%s\n' "$a" "$ingrp" "$canread" "$copy"
  [ "$canread" = yes ] || unreadable="$unreadable $a"
done

if [ -f "$PEM" ]; then
  [ -z "$unreadable" ] && ok "every account can READ the host-wide key" \
                       || bad "cannot read the host-wide key:$unreadable"
fi
[ "$copies" -eq 0 ] && ok "no per-account copies remain" \
                    || gap "$copies account(s) still hold a private ~/.config/selfdev/app.pem -- retire with --retire-copies once the rows above are clean"

# --- act ---------------------------------------------------------------------
case "$MODE" in
--check)
  echo
  printf 'check only, nothing changed: %d ok, %d missing, %d bad\n' "$PASS" "$GAPS" "$BAD"
  [ "$BAD" -eq 0 ] && [ "$GAPS" -eq 0 ] && exit 0
  echo "Next: sudo $CLI_NAME --apply${FROM:+ --from $FROM}"
  exit 1
  ;;

--apply)
  echo
  echo "== applying =="
  src="$(find_source)" || die "no source key: pass --from <pem>, or leave one account's ~/.config/selfdev/app.pem in place to migrate from"
  act "source key: $src"

  getent group "$SELFDEV_APP_GROUP" >/dev/null 2>&1 || { groupadd "$SELFDEV_APP_GROUP" && act "created group $SELFDEV_APP_GROUP"; }
  install -d -m 755 -o root -g root "$SELFDEV_APP_DIR"
  # install(1) to a temp name then mv would break a reader mid-read; install
  # writes in place atomically enough for a file nothing holds open, and every
  # reader opens it for a single read.
  install -m 640 -o root -g "$SELFDEV_APP_GROUP" "$src" "$PEM" && act "placed $PEM (640 root:$SELFDEV_APP_GROUP)"

  # The App id: from --app-id, else whatever the source conf beside the source
  # key already declared, else any account's conf. Never invented.
  if [ -z "$APP_ID" ]; then
    for c in "$(dirname "$src")/gh-app.conf" /home/*/.config/selfdev/gh-app.conf "$CONF"; do
      [ -r "$c" ] || continue
      APP_ID="$(sed -n 's/^SELFDEV_APP_ID=//p' "$c" | tail -1)"
      [ -n "$APP_ID" ] && { act "App id $APP_ID read from $c"; break; }
    done
  fi
  [ -n "$APP_ID" ] || die "no SELFDEV_APP_ID: pass --app-id <id> (it is on the App's settings page)"

  tmp="$(mktemp)"
  { printf '# The ONE self-dev GitHub App for this host. Placed by %s.\n' "$CLI_NAME"
    printf '# One key, one location, read by every account -- see bin/lib/selfdev-app-key.sh.\n'
    printf 'SELFDEV_APP_ID=%s\n' "$APP_ID"
    printf 'SELFDEV_APP_KEY=%s\n' "$PEM"
    printf 'SELFDEV_GH_OWNER=%s\n' "$OWNER"; } > "$tmp"
  install -m 644 -o root -g root "$tmp" "$CONF" && act "wrote $CONF"
  rm -f "$tmp"

  for a in $(accounts); do
    if id -nG "$a" 2>/dev/null | tr ' ' '\n' | grep -qx "$SELFDEV_APP_GROUP"; then :; else
      usermod -aG "$SELFDEV_APP_GROUP" "$a" && act "$a added to group $SELFDEV_APP_GROUP"
    fi
  done

  # WITNESS, as each account, by READING. `usermod -aG` does not change a
  # process that is already running, so this is also what catches "the group
  # says yes and the read says EACCES".
  fail=""
  for a in $(accounts); do
    sudo -n -u "$a" head -c 1 -- "$PEM" >/dev/null 2>&1 || fail="$fail $a"
  done
  if [ -n "$fail" ]; then
    bad "after apply, these accounts still cannot read $PEM:$fail"
    die "host-wide placement is not live for every account; per-account copies were NOT touched, so nothing is worse than before" 5
  fi
  ok "witness: every account read $PEM as itself"
  # Every bad() above (line 99, 109/110, 136) is something this branch just
  # fixed unconditionally (perms, conf contents, group membership) or that
  # the witness just re-proved -- reaching here without dying means none of
  # them are still true. A count taken before the fix is not evidence after
  # it (#1284).
  BAD=0
  echo
  echo "Next, once you are satisfied: sudo $CLI_NAME --retire-copies"
  ;;

--retire-copies)
  echo
  echo "== retiring per-account copies =="
  [ -f "$PEM" ] || die "refusing: there is no host-wide key at $PEM to fall back on" 5
  [ -z "$unreadable" ] || die "refusing: these accounts cannot read $PEM yet:$unreadable
Removing their private copies would leave them with no credential at all. Run --apply first." 5
  n=0
  for a in $(accounts); do
    d="/home/$a/.config/selfdev"
    [ -d "$d" ] || continue
    # Named, not globbed away: an UNDECLARED extra file in there is a finding
    # (that is how ecosim's orphan second App key was found), so it is listed
    # rather than swept up with the rest.
    for f in "$d"/*; do
      [ -e "$f" ] || continue
      case "$(basename "$f")" in
        app.pem|gh-app.conf) rm -f "$f"; n=$((n+1)) ;;
        *) gap "$a: left $f in place -- not one of this system's two files; look at it, then remove it by hand" ;;
      esac
    done
    rmdir "$d" 2>/dev/null && act "$a: ~/.config/selfdev/ removed"
  done
  ok "removed $n per-account file(s); every account now reads $CONF"
  ;;
esac

echo
printf '%d ok, %d missing, %d bad\n' "$PASS" "$GAPS" "$BAD"
[ "$BAD" -eq 0 ]
