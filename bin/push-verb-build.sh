#!/usr/bin/env bash
set -uo pipefail

CLI_NAME='push-verb-build.sh'
CLI_SUMMARY='mandark side: push a cut-or-fetched build tree onto a host and atomically swap its `current` -- the host runs nothing of ours to do it'
CLI_USAGE='  push-verb-build.sh --cut     --host H [--apply]   cut a fresh build here, push it, swap
  push-verb-build.sh --fetch   --host H [--apply]   fetch+verify the latest approved build here, push it, swap
  push-verb-build.sh --build ID --host H [--apply]  push an already-materialized local build by id
  push-verb-build.sh --latest  --host H [--apply]   push the newest already-materialized local build
  push-verb-build.sh --rollback ID --host H [--apply]
                                                     no transfer: H already holds ID -- swap to it directly
  push-verb-build.sh --list --build-root DIR        local builds available to push (no host needed)
  push-verb-build.sh --cut     --here [--apply]     cut and adopt on THIS machine, no ssh
  push-verb-build.sh --build ID --here [--apply]    adopt a local build by id

--check (default) previews with no writes anywhere, local or remote.
--build-root, --remote-root, --ssh, --rsync and --ssh-timeout are all
overridable so bin/tests/push-verb-build.test.sh can run with no real ssh,
no real host and no network -- same posture as install-verb-build.sh.'
CLI_FLAGS='--cut --fetch --build --latest --rollback --list --host --here --build-root --remote-root --ssh --rsync --ssh-timeout --check --apply'
CLI_POSITIONAL=any
CLI_EXITS='  0  pushed and the swap verified on re-read (or, under --check, could be)
  1  refused: an incomplete local build, a push/swap step failed, or the swap did not verify on re-read
  2  usage error
  6  BLIND: could not reach the host, or (for --fetch) could not reach the release channel. Not "nothing to do".'
. "$(dirname "${BASH_SOURCE[0]}")/lib/cli-guard.sh"
cli_guard "$@"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

BUILD_ROOT="${PUSH_BUILD_ROOT:-${VERB_BUILD_ROOT:-${XDG_DATA_HOME:-$HOME/.local/share}/verb-builds}}"
REMOTE_ROOT="${PUSH_REMOTE_ROOT:-/usr/local/share/verb-builds}"
SSH_BIN="${PUSH_SSH_BIN:-ssh}"
RSYNC_BIN="${PUSH_RSYNC_BIN:-rsync}"
SSH_TIMEOUT="${PUSH_SSH_TIMEOUT:-20}"

MODE="--check"
DO_CUT=0; DO_FETCH=0; DO_LIST=0
BUILD_ID=""; WANT_LATEST=0; ROLLBACK_ID=""
HOST=""
ADOPT_HERE=0   # NOT `HERE`: $HERE above is this script's dir, which sibling() needs

while [ $# -gt 0 ]; do
  case "$1" in
    --cut)          DO_CUT=1 ;;
    --fetch)        DO_FETCH=1 ;;
    --build)        BUILD_ID="${2:?--build needs an id}"; shift ;;
    --latest)       WANT_LATEST=1 ;;
    --rollback)     ROLLBACK_ID="${2:?--rollback needs an id}"; shift ;;
    --list)         DO_LIST=1 ;;
    --host)         HOST="${2:?--host needs a target}"; shift ;;
    --here)         ADOPT_HERE=1 ;;
    --build-root)   BUILD_ROOT="${2:?--build-root needs a value}"; shift ;;
    --remote-root)  REMOTE_ROOT="${2:?--remote-root needs a value}"; shift ;;
    --ssh)          SSH_BIN="${2:?--ssh needs a binary}"; shift ;;
    --rsync)        RSYNC_BIN="${2:?--rsync needs a binary}"; shift ;;
    --ssh-timeout)  SSH_TIMEOUT="${2:?--ssh-timeout needs a value}"; shift ;;
    --check)        MODE="--check" ;;
    --apply)        MODE="--apply" ;;
    *) printf '%s: unknown argument: %s\n' "$CLI_NAME" "$1" >&2; exit 2 ;;
  esac
  shift
done

say() { printf '%s\n' "$*" >&2; }
die() { printf '%s: %s\n' "$CLI_NAME" "$*" >&2; exit 1; }
via_suffix() { [ "${1:-}" = "sudo -n" ] && printf ' (via sudo -n)'; :; }

select_local_build() {
  local root="$1" want="$2" id="" dir="" d cand missing=0 total f project verb
  [ -d "$root" ] || { say "select_local_build: no local build root at $root"; return 1; }
  if [ "$want" = latest ]; then
    for d in "$root"/*/; do
      d="${d%/}"; cand="$(basename "$d")"
      [ "$cand" = repo ] && continue
      [ "$cand" = current ] && continue   # the adopted-build LINK, and it sorts above every dated id
      [ -L "$d" ] && continue             # $root/*/ matches a symlink-to-dir
      [ -f "$d/manifest.tsv" ] || continue
      if [ -z "$id" ] || [[ "$cand" > "$id" ]]; then id="$cand"; dir="$d"; fi
    done
    [ -n "$id" ] || { say "select_local_build: no materialized build under $root (nothing there has a manifest.tsv)"; return 1; }
  else
    id="$want"; dir="$root/$id"
    if [ "$id" = current ] || [ -L "$dir" ]; then
      say "select_local_build: '$id' is the adopted-build link, not a build -- name the dated id it points at ($(readlink "$dir" 2>/dev/null || echo unreadable))"
      return 1
    fi
    [ -f "$dir/manifest.tsv" ] || { say "select_local_build: no local build '$id' at $dir (manifest.tsv missing)"; return 1; }
  fi
  while IFS=$'\t' read -r project verb _ _; do
    [ -n "${verb:-}" ] || continue
    f="$dir/$project/bin/$verb"
    if   [ ! -f "$f" ]; then say "  MISSING $project/bin/$verb"; missing=$((missing+1))
    elif [ ! -x "$f" ]; then say "  BAD     $project/bin/$verb is not executable"; missing=$((missing+1))
    fi
  done < <(grep -v '^#' "$dir/manifest.tsv")
  total="$(grep -cv '^#' "$dir/manifest.tsv" || true)"
  [ "${total:-0}" -gt 0 ] || { say "select_local_build: $dir/manifest.tsv has no rows -- refusing to push an empty verb set"; return 1; }
  [ "$missing" -eq 0 ] || { say "select_local_build: $missing verb(s) missing/not-executable in $dir -- refusing to push an incomplete build"; return 1; }
  printf '%s\t%s\n' "$id" "$dir"
}

atomic_swap_local() {
  local root="$1" id="$2"
  [ -f "$root/$id/manifest.tsv" ] || { echo "atomic_swap_local: $root/$id has no manifest.tsv -- refusing to point current at it" >&2; return 1; }
  ln -sfn "$id" "$root/current.tmp" || { echo "atomic_swap_local: cannot write $root/current.tmp" >&2; return 1; }
  mv -Tf "$root/current.tmp" "$root/current" || { echo "atomic_swap_local: cannot move current into place" >&2; return 1; }
}

push_tree() {
  local sshbin="$1" rsyncbin="$2" local_dir="$3" host="$4" remote_root="$5" id="$6"
  PUSH_VIA=plain
  if ! "$sshbin" -o BatchMode=yes -o ConnectTimeout="$SSH_TIMEOUT" "$host" \
      "mkdir -p $(printf '%q' "$remote_root")"; then
    PUSH_VIA="sudo -n"
    "$sshbin" -o BatchMode=yes -o ConnectTimeout="$SSH_TIMEOUT" "$host" \
        "sudo -n mkdir -p $(printf '%q' "$remote_root")" || {
      say "push_tree: could not create $remote_root on $host"; return 1; }
  fi
  if ! "$rsyncbin" -a --delete -e "$sshbin -o BatchMode=yes -o ConnectTimeout=$SSH_TIMEOUT" \
      "$local_dir/" "$host:$remote_root/$id/"; then
    PUSH_VIA="sudo -n"
    "$rsyncbin" -a --delete --rsync-path='sudo -n rsync' -e "$sshbin -o BatchMode=yes -o ConnectTimeout=$SSH_TIMEOUT" \
        "$local_dir/" "$host:$remote_root/$id/" || {
      say "push_tree: rsync to $host:$remote_root/$id failed"; return 1; }
  fi
  normalize_remote_perms "$sshbin" "$host" "$remote_root/$id" || true
}

normalize_remote_perms() {
  local sshbin="$1" host="$2" dir="$3" q
  q="$(printf '%q' "$dir")"
  "$sshbin" -o BatchMode=yes -o ConnectTimeout="$SSH_TIMEOUT" "$host" \
      "chmod -R a+rX $q" 2>/dev/null && return 0
  "$sshbin" -o BatchMode=yes -o ConnectTimeout="$SSH_TIMEOUT" "$host" \
      "sudo -n chown -R root:root $q && sudo -n chmod -R a+rX $q" 2>/dev/null
}

verify_remote_readable() {
  local sshbin="$1" host="$2" dir="$3" mode
  mode="$("$sshbin" -o BatchMode=yes -o ConnectTimeout="$SSH_TIMEOUT" "$host" \
      "stat -c %a $(printf '%q' "$dir")" 2>/dev/null)"
  case "${mode: -1}" in 5|7) return 0 ;; *) return 1 ;; esac
}

remote_atomic_swap() {
  local sshbin="$1" host="$2" remote_root="$3" id="$4" script
  script="set -uo pipefail
$(declare -f atomic_swap_local)
atomic_swap_local \"\$1\" \"\$2\""
  SWAP_VIA=plain
  if "$sshbin" -o BatchMode=yes -o ConnectTimeout="$SSH_TIMEOUT" "$host" bash -s -- "$remote_root" "$id" <<<"$script"; then
    return 0
  fi
  SWAP_VIA="sudo -n"
  "$sshbin" -o BatchMode=yes -o ConnectTimeout="$SSH_TIMEOUT" "$host" sudo -n bash -s -- "$remote_root" "$id" <<<"$script"
}

verify_remote_build() {
  local sshbin="$1" host="$2" remote_root="$3" id="$4"
  "$sshbin" -o BatchMode=yes -o ConnectTimeout="$SSH_TIMEOUT" "$host" \
      "test -f $(printf '%q' "$remote_root/$id/manifest.tsv")" 2>/dev/null
}

verify_remote_current() {
  local sshbin="$1" host="$2" remote_root="$3" id="$4" got
  got="$("$sshbin" -o BatchMode=yes -o ConnectTimeout="$SSH_TIMEOUT" "$host" \
      "readlink $(printf '%q' "$remote_root/current")" 2>/dev/null)"
  [ "$got" = "$id" ]
}

probe_host() {
  local sshbin="$1" host="$2"
  "$sshbin" -o BatchMode=yes -o ConnectTimeout="$SSH_TIMEOUT" "$host" true 2>/dev/null
}

sibling() { local n="$1" p; p="$HERE/$n"; [ -x "$p" ] && printf '%s' "$p" || return 1; }

do_cut() {
  local cutter tmp id
  cutter="$(sibling cut-verb-build.sh)" || { say "$CLI_NAME: cut-verb-build.sh is not beside this script -- cannot cut a build here"; return 1; }
  mkdir -p "$BUILD_ROOT" || { say "$CLI_NAME: cannot create $BUILD_ROOT"; return 1; }
  tmp="$(mktemp -d "$BUILD_ROOT/.cut-XXXXXX")" || { say "$CLI_NAME: cannot create a scratch dir under $BUILD_ROOT"; return 1; }
  if ! "$cutter" --assemble "$tmp" >&2; then
    rm -rf "$tmp"; say "$CLI_NAME: cut-verb-build.sh refused -- see rows above"; return 1
  fi
  if [ ! -f "$tmp/BUILD_ID" ]; then
    rm -rf "$tmp"; say "$CLI_NAME: cut-verb-build.sh produced no BUILD_ID -- refusing"; return 1
  fi
  id="$(cat "$tmp/BUILD_ID")"
  if [ -e "$BUILD_ROOT/$id" ]; then
    rm -rf "$tmp"
  else
    mv "$tmp" "$BUILD_ROOT/$id"
  fi
}

do_fetch() {
  local installer rc
  installer="$(sibling install-verb-build.sh)" || { say "$CLI_NAME: install-verb-build.sh is not beside this script -- cannot fetch a build here"; return 1; }
  mkdir -p "$BUILD_ROOT" || { say "$CLI_NAME: cannot create $BUILD_ROOT"; return 1; }
  "$installer" --build-root "$BUILD_ROOT" --latest >&2
  rc=$?
  case "$rc" in
    0) : ;;
    6) say "$CLI_NAME: BLIND -- could not reach the release channel to fetch a build"; return 6 ;;
    *) say "$CLI_NAME: install-verb-build.sh --latest refused (exit $rc) -- see rows above"; return 1 ;;
  esac
}

if [ "$DO_LIST" -eq 1 ]; then
  [ -d "$BUILD_ROOT" ] || die "no builds at $BUILD_ROOT"
  found=0
  for d in "$BUILD_ROOT"/*/; do
    d="${d%/}"; id="$(basename "$d")"
    [ "$id" = repo ] && continue
    [ -f "$d/manifest.tsv" ] || continue
    found=1
    n="$(grep -cv '^#' "$d/manifest.tsv" 2>/dev/null || echo 0)"
    printf '  %-24s %s verb(s)\n' "$id" "$n"
  done
  [ "$found" -eq 1 ] || say "no locally materialized builds under $BUILD_ROOT (--cut or --fetch makes one)"
  exit 0
fi

sel_n=$((DO_CUT + DO_FETCH + WANT_LATEST + (${#BUILD_ID} > 0 ? 1 : 0) + (${#ROLLBACK_ID} > 0 ? 1 : 0)))
[ "$sel_n" -gt 0 ] || cli_die "name a build: --cut, --fetch, --build <id>, --latest, or --rollback <id>"
[ "$sel_n" -eq 1 ] || cli_die "--cut, --fetch, --build, --latest and --rollback are mutually exclusive -- say which build to push"
if [ "$ADOPT_HERE" -eq 1 ]; then   # this machine: --host cannot name it (no self-ssh)
  [ -z "$HOST" ] || cli_die "--here and --host are the same question answered twice -- --here IS this machine"
else
  [ -n "$HOST" ] || cli_die "--host is required (the target this pushes to and swaps on), or --here for this machine"
fi

if [ -n "$ROLLBACK_ID" ] && [ "$ADOPT_HERE" -eq 1 ]; then   # --rollback --here IS --build --here
  BUILD_ID="$ROLLBACK_ID"; ROLLBACK_ID=""
fi

if [ -n "$ROLLBACK_ID" ]; then
  echo "== push-verb-build --rollback $ROLLBACK_ID -> $HOST ($MODE) =="
  echo "   no transfer: $HOST must already hold $ROLLBACK_ID under $REMOTE_ROOT"

  if ! probe_host "$SSH_BIN" "$HOST"; then
    echo "  BLIND   could not reach $HOST at all (ssh rc=$?). Nothing was checked or changed."
    exit 6
  fi
  echo "  ok      $HOST is reachable"

  if ! verify_remote_build "$SSH_BIN" "$HOST" "$REMOTE_ROOT" "$ROLLBACK_ID"; then
    echo "  BAD     $HOST has no $REMOTE_ROOT/$ROLLBACK_ID/manifest.tsv -- refusing to swap current onto a build that is not there"
    exit 1
  fi
  echo "  ok      $HOST already holds $ROLLBACK_ID"

  if [ "$MODE" = --check ]; then
    echo "  would   swap $HOST's current -> $ROLLBACK_ID"
    echo "== nothing done (--check). Next: $0 --rollback $ROLLBACK_ID --host $HOST --apply =="
    exit 0
  fi

  if ! remote_atomic_swap "$SSH_BIN" "$HOST" "$REMOTE_ROOT" "$ROLLBACK_ID"; then
    echo "  BAD     the swap on $HOST failed or refused -- see rows above"
    exit 1
  fi
  if verify_remote_current "$SSH_BIN" "$HOST" "$REMOTE_ROOT" "$ROLLBACK_ID"; then
    echo "  OK      $HOST's current -> $ROLLBACK_ID (re-read off the host, not inferred from an exit code)$(via_suffix "$SWAP_VIA")"
    exit 0
  else
    echo "  BAD     the swap ran but $HOST's current does NOT read back as $ROLLBACK_ID"
    exit 1
  fi
fi

if [ "$DO_CUT" -eq 1 ]; then
  do_cut || exit $?
  WANT_LATEST=1
elif [ "$DO_FETCH" -eq 1 ]; then
  do_fetch || exit $?
  WANT_LATEST=1
fi

if [ "$WANT_LATEST" -eq 1 ]; then
  sel="$(select_local_build "$BUILD_ROOT" latest)" || exit 1
else
  sel="$(select_local_build "$BUILD_ROOT" "$BUILD_ID")" || exit 1
fi
BUILD_ID="${sel%%$'\t'*}"
BUILD_DIR="${sel#*$'\t'}"

if [ "$ADOPT_HERE" -eq 1 ]; then
  echo "== push-verb-build $BUILD_ID -> this machine ($MODE) =="
  echo "   from $BUILD_DIR"
  echo "   no transfer: the build is already under $BUILD_ROOT"
  was="$(readlink "$BUILD_ROOT/current" 2>/dev/null || true)"
  echo "  ok      current is ${was:-<unset>}"
  if [ "$MODE" = --check ]; then
    echo "  would   swap current -> $BUILD_ID (ln -sfn + mv -Tf, atomic)"
    echo "== nothing done (--check). Next: $0 --build $BUILD_ID --here --apply =="
    exit 0
  fi
  atomic_swap_local "$BUILD_ROOT" "$BUILD_ID" || {
    echo "  BAD     the swap refused -- current is UNCHANGED at ${was:-<unset>}"; exit 1; }
  got="$(readlink "$BUILD_ROOT/current" 2>/dev/null || true)"
  if [ "$got" = "$BUILD_ID" ]; then
    echo "  OK      current -> $BUILD_ID (re-read off the link, not asserted)"
    exit 0
  fi
  echo "  BAD     the swap ran but current reads back as ${got:-<unset>}, not $BUILD_ID"
  exit 1
fi

echo "== push-verb-build $BUILD_ID -> $HOST ($MODE) =="
echo "   from $BUILD_DIR"
echo "   to   $HOST:$REMOTE_ROOT"

if ! probe_host "$SSH_BIN" "$HOST"; then
  echo "  BLIND   could not reach $HOST at all. Nothing was pushed or changed."
  exit 6
fi
echo "  ok      $HOST is reachable"
echo "  ok      $BUILD_ID is complete locally: every verb in its manifest is present and executable"

if [ "$MODE" = --check ]; then
  n="$(grep -cv '^#' "$BUILD_DIR/manifest.tsv" || true)"
  echo "  would   push $n verb('s) worth of tree to $HOST:$REMOTE_ROOT/$BUILD_ID"
  echo "  would   swap $HOST's current -> $BUILD_ID (ln -sfn + mv -Tf, atomic)"
  echo "== nothing done (--check). Next: $0 --build $BUILD_ID --host $HOST --apply =="
  exit 0
fi

if ! push_tree "$SSH_BIN" "$RSYNC_BIN" "$BUILD_DIR" "$HOST" "$REMOTE_ROOT" "$BUILD_ID"; then
  echo "  BAD     push to $HOST failed -- current on $HOST is UNCHANGED. Rows above say which step refused."
  exit 1
fi
echo "  OK      $BUILD_ID is on $HOST at $REMOTE_ROOT/$BUILD_ID$(via_suffix "$PUSH_VIA")"

if ! remote_atomic_swap "$SSH_BIN" "$HOST" "$REMOTE_ROOT" "$BUILD_ID"; then
  echo "  BAD     the swap on $HOST failed or refused -- the pushed tree is there but current did not move"
  exit 1
fi
if verify_remote_current "$SSH_BIN" "$HOST" "$REMOTE_ROOT" "$BUILD_ID"; then
  echo "  OK      $HOST's current -> $BUILD_ID (re-read off the host, not inferred from an exit code)$(via_suffix "$SWAP_VIA")"
  if verify_remote_readable "$SSH_BIN" "$HOST" "$REMOTE_ROOT/$BUILD_ID"; then
    echo "  OK      $BUILD_ID is readable by a project account on $HOST (mode read off the host)"
  else
    echo "  BAD     current -> $BUILD_ID, but $REMOTE_ROOT/$BUILD_ID is not world-traversable on $HOST."
    echo "          Every project account dispatches out of this tree and cannot enter it, which"
    echo "          reads as a healthy swap and a dead host. Fix: sudo chown -R root:root and"
    echo "          sudo chmod -R a+rX on $REMOTE_ROOT/$BUILD_ID, then re-run."
    exit 1
  fi
  exit 0
else
  echo "  BAD     the swap ran but $HOST's current does NOT read back as $BUILD_ID"
  exit 1
fi
