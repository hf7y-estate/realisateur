#!/usr/bin/env bash
set -uo pipefail

CLI_NAME='unland-foreign-clone.sh'
CLI_SUMMARY='remove the clone of <project> that bin/land-selfdev.sh minted into self-dev accounts that do not own it, keeping the checkout of the one that does, and revoke the deploy key that clone was reading with (#852)'
CLI_USAGE='  unland-foreign-clone.sh <project>            --check (default): list what would go, remove nothing
  unland-foreign-clone.sh <project> --apply    remove them, then print the witness to paste back
  unland-foreign-clone.sh <project> --apply --host <hostname>
                                                drive <hostname> over ssh (realisateur#895): the
                                                deploy-key API calls still run LOCALLY, wherever the
                                                operator'"'"'s gh is authenticated -- only the
                                                filesystem probe/removal is shipped to the target.

  --remote-fs-only is what --host ships to the target; not meant to be typed
  by a human directly (it never touches gh, and prints machine-readable rows).'
CLI_FLAGS='--check --apply --host --remote-fs-only'
CLI_POSITIONAL='<project>'
CLI_EXITS='  0  nothing left to remove
  1  findings: clones or keys are present (--check), or one was kept back or
     could not be revoked (--apply)
  5  refused: --apply without root (local mode), or --remote-fs-only --apply
     without root on the target
  6  BLIND: the self-dev uid band matched no account at all -- nothing was
     looked at, and a 0-account pass is NOT a clean result; also raised when
     --host cannot reach the target at all'
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/lib/cli-guard.sh"
cli_guard "$@"

MODE=--check
PROJECT=
TARGET_HOST=""
REMOTE_FS_ONLY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --check|--apply) MODE="$1" ;;
    --host) shift; TARGET_HOST="${1:-}" ;;
    --remote-fs-only) REMOTE_FS_ONLY=1 ;;
    [a-z][a-z0-9-]*) [ -n "$PROJECT" ] && cli_die "one project at a time: already given '$PROJECT'"; PROJECT="$1" ;;
    *) cli_die "unexpected argument: $1" ;;
  esac
  shift
done  # $PROJECT is MATCHED, not merely non-empty: it becomes a path component of the rm -rf below, and `..` would name every account's whole Documents/Projects
[ -n "$PROJECT" ] || cli_die "which project's foreign clones? (e.g. senechal)"

UID_LO=3000; UID_HI=3100                                          # the self-dev band; every reader of it derives, never a typed list
HOME_ROOT="${SELFDEV_HOME_ROOT:-/home}"                           # fixture seams:
PASSWD_SRC="${SELFDEV_PASSWD:-}"                                  # unset in production
HOST_S="${SELFDEV_HOSTNAME:-$(hostname -s 2>/dev/null || echo unknown)}"
. "$HERE/lib/estate-set.sh"
KEY_OWNER="${SELFDEV_GH_OWNER:-$GH_ESTATE_OWNER}"
GH="${UNLAND_GH:-gh}"

PASS=0; GAPS=0; BAD=0
ok()  { printf '  OK      %s\n' "$*"; PASS=$((PASS+1)); }
gap() { printf '  WOULD   %s\n' "$*"; GAPS=$((GAPS+1)); }
bad() { printf '  BAD     %s\n' "$*"; BAD=$((BAD+1)); }
act() { printf '  DO      %s\n' "$*"; }
die() { printf '\n%s: %s\n' "$CLI_NAME" "$*" >&2; exit "${2:-5}"; }

accounts() {  # the uid band IS the roster -- never a typed list
  { [ -n "$PASSWD_SRC" ] && cat "$PASSWD_SRC" || getent passwd; } 2>/dev/null \
    | awk -F: -v lo="$UID_LO" -v hi="$UID_HI" '$3+0>=lo && $3+0<hi {print $1}' | sort
}

# TRAP: as root, git refuses another account's repo (safe.directory) and then
#   fails exactly as it does on a corrupt tree -- without the -c below every
#   clone reads "not a readable git tree" and this removes nothing.
residue() {  # a bootstrap copy can hold work that exists nowhere else -- `scheduler -i realisateur` wrote .idea files into whatever account it ran under until hf7y/scheduler retired that path on 2026-08-29, and on 2026-08-30 a cleanup sweep held all three surviving clones back with local commits of its own
  local d="$1" out
  out="$(git -c safe.directory='*' -C "$d" status --porcelain 2>/dev/null)" \
    || { printf 'not a readable git tree'; return 0; }
  [ -n "$out" ] && { printf 'uncommitted or untracked files (%s)' "$(printf '%s\n' "$out" | grep -c .)"; return 0; }
  out="$(git -c safe.directory='*' -C "$d" log --branches --not --remotes --oneline 2>/dev/null)"
  [ -n "$out" ] && printf 'unpushed commits (%s)' "$(printf '%s\n' "$out" | grep -c .)"
  return 0
}

if [ "$REMOTE_FS_ONLY" -eq 1 ]; then  # what --host ships to the target and runs there, over ssh, as root; no gh call here (realisateur#895) -- prints UNLANDFS<TAB>acct<TAB>OWN|NORMAL<TAB>has_clone(0/1)<TAB>residue-or-'-'<TAB>rm_result-or-'-'
  [ "$MODE" = --check ] || [ "$(id -u)" -eq 0 ] || die "$MODE --remote-fs-only needs root on this host" 5

  roster="$(accounts)"
  if [ -z "$roster" ]; then
    echo "BLIND: no account in uid $UID_LO-$((UID_HI-1)) on $(hostname -s 2>/dev/null || echo unknown) -- nothing was looked at." >&2
    exit 6
  fi

  for a in $roster; do
    case "$a" in ''|*/*|.|..) continue ;; esac  # it becomes a path component below; a roster that can hold anything else is a delete-anything primitive

    if [ "$a" = "$PROJECT" ]; then  # THE OWNING ACCOUNT -- never a removal target, on this host or any other
      printf 'UNLANDFS\t%s\tOWN\t-\t-\t-\n' "$a"
      continue
    fi

    d="$HOME_ROOT/$a/Documents/Projects/$PROJECT"
    has_clone=1; [ -d "$d" ] || has_clone=0
    res="-"
    if [ "$has_clone" -eq 1 ]; then
      r="$(residue "$d")"
      [ -n "$r" ] && res="$r"
    fi

    rmres="-"
    if [ "$MODE" = --apply ] && [ "$has_clone" -eq 1 ] && [ "$res" = "-" ]; then
      if rm -rf "$d"; then rmres="ok"; else rmres="failed"; fi
    fi

    printf 'UNLANDFS\t%s\tNORMAL\t%s\t%s\t%s\n' "$a" "$has_clone" "$res" "$rmres"
  done
  exit 0
fi

if [ -n "$TARGET_HOST" ]; then  # driven from here over ssh; deploy-key half stays local (gh is authenticated here), only the fs probe/removal ships (bin/lib/selfdev-ssh-transport.sh, realisateur#895/#1083)
  . "$HERE/lib/selfdev-ssh-transport.sh"
  echo "== unland-foreign-clone $PROJECT ($MODE) on $TARGET_HOST, driven over ssh -- deploy-key checks stay local =="

  KEYS=""   # a clone's credential outlives the clone unless something also revokes it (#852); listed ONCE here, not per account
  if command -v "$GH" >/dev/null 2>&1; then
    KEYS="$("$GH" repo deploy-key list --repo "$KEY_OWNER/$PROJECT" --json id,title \
             --jq '.[] | (.id|tostring) + "\t" + .title' 2>/dev/null)" || KEYS=""
  fi
  deploy_key_id() {  # <title> -> the key id on stdout, 1 if no key has that title
    [ -n "$KEYS" ] || return 1
    printf '%s\n' "$KEYS" | awk -F'\t' -v t="$1" '$2==t {print $1; found=1} END{exit !found}'
  }

  SHIP_PATHS=(bin/unland-foreign-clone.sh bin/lib/cli-guard.sh bin/lib/estate-set.sh)
  FSOUT="$(selfdev_ssh_ship_run "$TARGET_HOST" 1 "$HERE/.." SHIP_PATHS \
    bin/unland-foreign-clone.sh "$PROJECT" "$MODE" --remote-fs-only)"
  rc=$?
  if [ "$rc" -eq 255 ] || [ "$rc" -eq 6 ]; then
    echo "$CLI_NAME: FATAL could not reach $TARGET_HOST, or nothing ran there (ssh rc=$rc)" >&2
    exit 6
  fi

  found_any=0
  while IFS=$'\t' read -r tag a role has_clone res rmres; do
    [ "$tag" = UNLANDFS ] || continue
    found_any=1
    title="$TARGET_HOST-$a-$PROJECT"
    kid="$(deploy_key_id "$title")" || kid=""

    if [ "$role" = OWN ]; then
      ok "$a: KEPT -- this account owns $PROJECT, so its dev checkout on $TARGET_HOST is left alone"
      continue
    fi

    d="$HOME_ROOT/$a/Documents/Projects/$PROJECT"  # message text only -- the real path lives on $TARGET_HOST

    if [ "$has_clone" -eq 1 ] && [ "$res" != "-" ]; then
      bad "$a: KEPT -- $d on $TARGET_HOST has $res; salvage it, then re-run"
      continue
    fi

    if [ "$has_clone" -eq 0 ] && [ -z "$kid" ]; then
      ok "$a: no clone at $d on $TARGET_HOST, no deploy key '$title'"
      continue
    fi

    if [ "$MODE" = --apply ]; then
      if [ "$has_clone" -eq 1 ]; then
        case "$rmres" in
          ok) act "$a: removed $d on $TARGET_HOST" ;;
          *)  bad "$a: could not remove $d on $TARGET_HOST" ;;
        esac
      fi
      if [ -n "$kid" ]; then
        if "$GH" repo deploy-key delete "$kid" --repo "$KEY_OWNER/$PROJECT" >/dev/null 2>&1; then
          act "$a: revoked deploy key '$title' (id $kid) on $KEY_OWNER/$PROJECT"
        else
          bad "$a: could not revoke deploy key '$title' (id $kid) on $KEY_OWNER/$PROJECT"
        fi
      fi
    else
      [ "$has_clone" -eq 1 ] && gap "$a: would remove $d on $TARGET_HOST"
      [ -n "$kid" ] && gap "$a: would revoke deploy key '$title' (id $kid) on $KEY_OWNER/$PROJECT"
    fi
  done <<<"$FSOUT"

  if [ "$found_any" -eq 0 ]; then
    echo "BLIND: $TARGET_HOST answered, but no account in uid $UID_LO-$((UID_HI-1)) was found." >&2
    exit 6
  fi

  echo
  printf '%s (%s) on %s: %d ok, %d to remove, %d kept back\n' "$CLI_NAME" "$MODE" "$TARGET_HOST" "$PASS" "$GAPS" "$BAD"

  cat <<WITNESS

== WITNESS -- run this after --apply and paste the output ==
  ssh $TARGET_HOST sudo find $HOME_ROOT -maxdepth 4 -type d -path '*/Documents/Projects/$PROJECT'
  echo "clones left: \$(ssh $TARGET_HOST sudo find $HOME_ROOT -maxdepth 4 -type d -path '*/Documents/Projects/$PROJECT' | grep -c .) (expect 1 -- $PROJECT's own)"
  ssh $TARGET_HOST 'command -v ausculte; ausculte --help >/dev/null 2>&1; echo "ausculte rc=$?"'
Root over ssh, and find rather than a glob, for the same reason the local
witness uses them: $PROJECT's own home is 0700 on $TARGET_HOST too.
WITNESS

  if [ "$MODE" = --check ]; then
    [ "$GAPS" -eq 0 ] && [ "$BAD" -eq 0 ] && exit 0
    echo "Next: $CLI_NAME $PROJECT --apply --host $TARGET_HOST"
    exit 1
  fi
  [ "$BAD" -eq 0 ] && exit 0
  exit 1
fi

KEYS=""   # local execution, unchanged by realisateur#895 -- a clone's credential outlives the clone unless something also revokes it (#852); listed ONCE here, not per account -- 30+ accounts is 30+ API calls otherwise, and a failed list stays silent so a key check that cannot run never blocks the clone removal that is this tool's primary contract
if command -v "$GH" >/dev/null 2>&1; then
  KEYS="$("$GH" repo deploy-key list --repo "$KEY_OWNER/$PROJECT" --json id,title \
           --jq '.[] | (.id|tostring) + "\t" + .title' 2>/dev/null)" || KEYS=""  # wire-selfdev-git.sh titles a deploy key "<host>-<account>-<project>", read-only, one per foreign clone it grants
fi
deploy_key_id() {  # <title> -> the key id on stdout, 1 if no key has that title
  [ -n "$KEYS" ] || return 1
  printf '%s\n' "$KEYS" | awk -F'\t' -v t="$1" '$2==t {print $1; found=1} END{exit !found}'
}

echo "== unland-foreign-clone $PROJECT ($MODE) -- $(hostname -s), uid $UID_LO-$((UID_HI-1)) under $HOME_ROOT =="

[ "$MODE" = --check ] || [ "$(id -u)" -eq 0 ] || die "$MODE needs root (sudo $CLI_NAME $PROJECT $MODE)" 5

roster="$(accounts)"
if [ -z "$roster" ]; then
  echo "BLIND: no account in uid $UID_LO-$((UID_HI-1)) -- nothing was looked at." >&2
  echo "$CLI_NAME: nothing was measured. This is NOT a clean result." >&2
  exit 6
fi

for a in $roster; do
  case "$a" in ''|*/*|.|..) bad "refusing an implausible account name: '$a'"; continue ;; esac  # it becomes a path component below; a roster that can hold anything else is a delete-anything primitive

  d="$HOME_ROOT/$a/Documents/Projects/$PROJECT"
  title="$HOST_S-$a-$PROJECT"
  kid="$(deploy_key_id "$title")" || kid=""

  if [ "$a" = "$PROJECT" ]; then  # THE OWNING ACCOUNT, and the account name equalling the directory name is the only thing that tells its dev checkout (schedule/<project>.conf's PROJECT_REPO_PATH) from a copy land-selfdev.sh minted
    ok "$a: KEPT -- this account owns $PROJECT, so $d is its own dev checkout"
    continue
  fi

  has_clone=1; [ -d "$d" ] || has_clone=0

  if [ "$has_clone" -eq 1 ]; then
    r="$(residue "$d")"
    if [ -n "$r" ]; then
      bad "$a: KEPT -- $d has $r; salvage it, then re-run"
      continue
    fi
  fi

  if [ "$has_clone" -eq 0 ] && [ -z "$kid" ]; then  # a bare key outliving its clone is still a finding (#852), not an "ok"
    ok "$a: no clone at $d, no deploy key '$title'"
    continue
  fi

  if [ "$MODE" = --apply ]; then
    if [ "$has_clone" -eq 1 ]; then
      if rm -rf "$d"; then act "$a: removed $d"; else bad "$a: could not remove $d"; fi
    fi
    if [ -n "$kid" ]; then
      if "$GH" repo deploy-key delete "$kid" --repo "$KEY_OWNER/$PROJECT" >/dev/null 2>&1; then
        act "$a: revoked deploy key '$title' (id $kid) on $KEY_OWNER/$PROJECT"
      else
        bad "$a: could not revoke deploy key '$title' (id $kid) on $KEY_OWNER/$PROJECT"
      fi
    fi
  else
    [ "$has_clone" -eq 1 ] && gap "$a: would remove $d"
    [ -n "$kid" ] && gap "$a: would revoke deploy key '$title' (id $kid) on $KEY_OWNER/$PROJECT"
  fi
done

echo
printf '%s (%s): %d ok, %d to remove, %d kept back\n' "$CLI_NAME" "$MODE" "$PASS" "$GAPS" "$BAD"

cat <<WITNESS

== WITNESS -- run this on $(hostname -s) after --apply and paste the output ==
  sudo find $HOME_ROOT -maxdepth 4 -type d -path '*/Documents/Projects/$PROJECT'
  echo "clones left: \$(sudo find $HOME_ROOT -maxdepth 4 -type d -path '*/Documents/Projects/$PROJECT' | grep -c .) (expect 1 -- $PROJECT's own)"
  command -v ausculte; ausculte --help >/dev/null 2>&1; echo "ausculte rc=\$?"
Root, and find rather than a glob: $PROJECT's own home is 0700, so a glob the
invoking shell expands cannot see the one clone that is supposed to SURVIVE,
and the witness reads "clones left: 0" on a correct run (2026-08-31).
The last line is the half that matters: it proves the removal took the
clones and not the tooling, which reaches these accounts as verbs.
WITNESS

if [ "$MODE" = --check ]; then
  [ "$GAPS" -eq 0 ] && [ "$BAD" -eq 0 ] && exit 0
  echo "Next: sudo $CLI_NAME $PROJECT --apply"
  exit 1
fi
[ "$BAD" -eq 0 ] && exit 0
exit 1
