#!/usr/bin/env bash
# wire-agent-dispatch.sh -- point /srv/agent's dispatch files at this clone, so a
# merged PR reaches the 01:00 nightly instead of a copy nothing refreshes.
# TRAPS (the rest of this header is in the vault):
# `/srv/agent` is not a git repository (#1332). Its files were placed by hand
# and versioned afterwards, so `main` and the host agree by coincidence rather
# than by any path, and stop agreeing on the next merge. The clone this runs from is
# already pulled every 20 minutes by the `realisateur:estate-watch:WATCH` cron
# row, so a symlink is the whole propagation mechanism -- no second pull, no
# copy step, no deploy tree.
#
# WHY SYMLINKS AND NOT `cp`: a copy has to be re-copied, which is the thing
# that never happens. `nightly.sh` resolves its siblings with
# `dirname "${BASH_SOURCE[0]}"`, which is the SYMLINK's directory, so the logs,
# `.nightly.lock` and `work/` stay in /srv/agent where they belong.
#
# BEHIND IS NOT DRIFT, and conflating them makes this verb useless the first
# time it is needed: the host copy differing from `main` is the NORMAL state
# after a merge. `git hash-object` the host's bytes and ask whether that blob
# was ever this path's content -- if it was, the host is simply behind and the
# clone is authoritative. If it never was, somebody edited the host, and THAT
# is refused with the diff named rather than overwritten.
set -uo pipefail

CLI_NAME="wire-agent-dispatch"
usage() { echo "usage: $0 [--check|--apply]" >&2; }

MODE=--check
while [ $# -gt 0 ]; do
  case "$1" in
    --check|--apply|--state) MODE="$1" ;;
    *)                       usage; exit 2 ;;
  esac
  shift
done

SRC="${AGENT_SRC:-$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../agent}"
DST="${AGENT_DIR:-/srv/agent}"
FILES=(nightly.sh run-agent.sh merge-carry.sh repos Dockerfile)

# --state prints `<file><TAB><state>`, one line per file, and changes nothing.
# It exists so estate-status-collect.py publishes THIS classification instead
# of writing a second copy of the rule in python.
state_of() {  # <file> -> linked|copy|behind|drifted|absent|not-in-clone
  local f="$1" host="$DST/$1" src="$SRC/$1"
  [ -f "$src" ] || { echo not-in-clone; return; }
  if [ -L "$host" ] && [ "$(readlink -f "$host")" = "$(readlink -f "$src")" ]; then
    echo linked; return
  fi
  [ -e "$host" ] || { echo absent; return; }
  cmp -s "$host" "$src" && { echo copy; return; }
  was_this_path "$host" "$f" && echo behind || echo drifted
}

# Were the host's exact bytes ever the content of agent/<f> in this clone? A
# path's history is a handful of commits, so this is cheap. No git, or a src
# that is not in a work tree: FAIL CLOSED to drifted, which refuses.
was_this_path() {
  local h c srcdir; srcdir="$(dirname "$(readlink -f "$SRC")")"
  command -v git >/dev/null || return 1
  h="$(git -C "$srcdir" hash-object "$1" 2>/dev/null)" || return 1
  [ -n "$h" ] || return 1
  for c in $(git -C "$srcdir" log --format=%H -- "agent/$2" 2>/dev/null); do
    [ "$(git -C "$srcdir" rev-parse "$c:agent/$2" 2>/dev/null)" = "$h" ] && return 0
  done
  return 1
}

PASS=0; GAPS=0; BAD=0
ok()  { printf '  OK      %s\n' "$*"; PASS=$((PASS+1)); }
gap() { printf '  LINK    %s\n' "$*"; GAPS=$((GAPS+1)); }
bad() { printf '  BAD     %s\n' "$*"; BAD=$((BAD+1)); }

if [ "$MODE" = --state ]; then
  for f in "${FILES[@]}"; do printf '%s\t%s\n' "$f" "$(state_of "$f")"; done
  exit 0
fi

echo "== $CLI_NAME ($MODE) -- $DST -> $SRC =="

[ -d "$SRC" ] || { echo "$CLI_NAME: no agent/ beside this script at $SRC -- wrong checkout" >&2; exit 2; }
[ -d "$DST" ] || { echo "$CLI_NAME: $DST does not exist -- this host does not dispatch" >&2; exit 2; }

# A pass holds this for the whole night. Replacing run-agent.sh underneath a
# running nightly is the one way this can break something that works.
if [ -e "$DST/.nightly.lock" ] && ! flock -n "$DST/.nightly.lock" true 2>/dev/null; then
  echo "$CLI_NAME: a nightly holds $DST/.nightly.lock -- it is dispatching right now. Try after it finishes." >&2
  exit 1
fi

stamp="$(date -u +%Y%m%dT%H%M%SZ)"
for f in "${FILES[@]}"; do
  want="$(readlink -f "$SRC/$f")"
  case "$(state_of "$f")" in
    linked)       ok  "$f -> the clone"; continue ;;
    not-in-clone) bad "$f: not in the clone at $SRC/$f"; continue ;;
    drifted)      bad "$f: bytes that were NEVER this path's content -- somebody edited the host. diff '$DST/$f' '$want'"; continue ;;
    absent)       gap "$f: absent on the host" ;;
    copy)         gap "$f: a plain copy, identical today and refreshed by nothing" ;;
    behind)       gap "$f: an EARLIER version of this same file -- the host is behind \`main\`" ;;
  esac

  [ "$MODE" = --apply ] || continue
  # SAY ONLY WHAT HAPPENED. This claimed "was backed up to .pre-wire/<f>.<stamp>"
  # unconditionally, so linking merge-carry.sh -- a file that was ABSENT on the
  # host -- reported a backup that does not exist. A stated backup is something
  # someone will later go looking for.
  kept=""
  if [ -e "$DST/$f" ]; then
    mkdir -p "$DST/.pre-wire" || { bad "$f: could not make $DST/.pre-wire"; continue; }
    cp -p "$DST/$f" "$DST/.pre-wire/$f.$stamp" || { bad "$f: could not back up, not touching it"; continue; }
    kept=" (was backed up to .pre-wire/$f.$stamp)"
  fi
  ln -sfn "$want" "$DST/$f" && ok "$f -> the clone${kept}" \
    || bad "$f: could not link"
done

echo
if [ "$MODE" = --check ]; then
  printf 'check only, nothing changed: %d linked, %d to link, %d bad\n' "$PASS" "$GAPS" "$BAD"
  [ "$GAPS" -eq 0 ] && [ "$BAD" -eq 0 ] && echo "nothing to do." || echo "Next: $0 --apply"
else
  printf 'wired %s: %d linked, %d bad\n' "$DST" "$PASS" "$BAD"
fi
[ "$BAD" -eq 0 ] || exit 5
[ "$MODE" = --apply ] || [ "$GAPS" -eq 0 ] || exit 4
exit 0
