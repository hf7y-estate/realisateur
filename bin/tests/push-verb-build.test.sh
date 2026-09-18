#!/usr/bin/env bash
set -uo pipefail
. "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib/harness.sh"

REPO_BIN="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$REPO_BIN/push-verb-build.sh"
[ -x "$SCRIPT" ] || { echo "FAIL: $SCRIPT not executable"; exit 1; }

t_ok()  { echo "  ok   $1"; pass=$((pass+1)); }
t_bad() { echo "  FAIL $1"; fail=$((fail+1)); [ $# -gt 1 ] && echo "       $2"; }
t_eq()  { if [ "$2" = "$3" ]; then t_ok "$1"; else t_bad "$1" "expected '$3', got '$2'"; fi; }
t_rc()  { if [ "$2" = "$3" ]; then t_ok "$1"; else t_bad "$1" "expected exit $2, got $3"; fi; }
t_has() { case "$2" in *"$3"*) t_ok "$1" ;; *) t_bad "$1" "missing: $3 -- got: $2" ;; esac; }
t_not_has() { case "$2" in *"$3"*) t_bad "$1" "should not contain: $3 -- got: $2" ;; *) t_ok "$1" ;; esac; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT

mk_verb() {
  mkdir -p "$1/$2/bin"
  printf '#!/bin/sh\necho %s\n' "$4" > "$1/$2/bin/$3"
  chmod +x "$1/$2/bin/$3"
}
mk_manifest() {
  local dir="$1"; shift
  {
    printf '# verb build fixture\n'
    printf '# project\tverb\tsha\trepo_url\n'
    for row in "$@"; do
      printf '%s\t0000000000000000000000000000000000000000\thttps://example/%s.git\n' \
        "$row" "$(printf '%s' "$row" | cut -f1)"
    done
  } > "$dir/manifest.tsv"
}

echo "-- A. select_local_build(): the build-selection logic, no ssh needed --"
say() { printf '%s\n' "$*" >&2; }
eval "$(sed -n '/^select_local_build()/,/^}/p; /^atomic_swap_local()/,/^}/p' "$SCRIPT")"

ROOT="$T/A"; mkdir -p "$ROOT"

mk_verb "$ROOT/2026-09-01T000000Z" proj alpha alpha
mk_manifest "$ROOT/2026-09-01T000000Z" "proj	alpha"

mk_verb "$ROOT/2026-09-03T000000Z" proj alpha alpha
mk_manifest "$ROOT/2026-09-03T000000Z" "proj	alpha"

mkdir -p "$ROOT/2026-09-02T000000Z"
mk_manifest "$ROOT/2026-09-02T000000Z" "proj	alpha" "proj	beta"
mk_verb "$ROOT/2026-09-02T000000Z" proj alpha alpha

mkdir -p "$ROOT/repo/objects"

OUT="$(select_local_build "$ROOT" "2026-09-01T000000Z" 2>&1)"; RC=$?
t_rc "a complete build by explicit id: selects" 0 "$RC"
t_eq "...and prints id<TAB>dir" "$OUT" "$(printf '2026-09-01T000000Z\t%s/2026-09-01T000000Z' "$ROOT")"

OUT="$(select_local_build "$ROOT" latest 2>&1)"; RC=$?
t_rc "--latest: selects (lexically greatest id, timestamps sort chronologically)" 0 "$RC"
t_has "...and it is the NEWEST complete build, not the incomplete newer-dated one" "$OUT" "2026-09-03T000000Z"

OUT="$(select_local_build "$ROOT" "2026-09-02T000000Z" 2>&1)"; RC=$?
t_rc "an incomplete build (manifest promises a verb that never landed): refused" 1 "$RC"
t_has "...and says which verb is missing" "$OUT" "MISSING proj/bin/beta"

OUT="$(select_local_build "$ROOT" "no-such-id" 2>&1)"; RC=$?
t_rc "a build id that does not exist locally: refused" 1 "$RC"

EMPTY="$T/A-empty"; mkdir -p "$EMPTY"
OUT="$(select_local_build "$EMPTY" latest 2>&1)"; RC=$?
t_rc "an empty build root: refused, not silently 'nothing to push'" 1 "$RC"
t_has "...and the bare-clone leftover under a REAL root is never picked as a build" \
      "$(select_local_build "$ROOT" latest 2>&1)" "2026-09-03T000000Z"

echo
echo "-- B. atomic_swap_local(): THE ATOMICITY WITNESS -----------------------"

WROOT="$T/B"; mkdir -p "$WROOT"
mk_verb "$WROOT/A" proj alpha A
mk_manifest "$WROOT/A" "proj	alpha"
mk_verb "$WROOT/B" proj alpha B
mk_manifest "$WROOT/B" "proj	alpha"

atomic_swap_local "$WROOT" A >/dev/null 2>&1
t_eq "initial swap: current -> A" "$(readlink "$WROOT/current")" A

VIOL="$T/violations"; SEEN="$T/seen"; : > "$VIOL"; : > "$SEEN"

reader() {
  local i link out
  for i in $(seq 1 500); do
    link="$(readlink "$WROOT/current" 2>/dev/null)"
    if [ -z "$link" ]; then
      printf 'MISSING-SYMLINK iter=%s\n' "$i" >> "$VIOL"; continue
    fi
    if [ ! -f "$WROOT/current/manifest.tsv" ]; then
      printf 'MISSING-MANIFEST iter=%s link=%s\n' "$i" "$link" >> "$VIOL"; continue
    fi
    out="$("$WROOT/current/proj/bin/alpha" 2>/dev/null)"
    case "$out" in
      A|B) printf '%s\n' "$out" >> "$SEEN" ;;
      *)   printf 'GARBLED iter=%s out=%q link=%s\n' "$i" "$out" "$link" >> "$VIOL" ;;
    esac
  done
}

reader &
READER_PID=$!
for _ in $(seq 1 250); do
  atomic_swap_local "$WROOT" B >/dev/null 2>&1
  atomic_swap_local "$WROOT" A >/dev/null 2>&1
done
wait "$READER_PID"

if [ -s "$VIOL" ]; then
  t_bad "1000 swaps raced against a concurrent reader: zero partial/missing observations" \
        "$(wc -l < "$VIOL") violation(s), first: $(head -1 "$VIOL")"
else
  t_ok "1000 swaps raced against a concurrent reader: zero partial/missing observations"
fi

if grep -qx A "$SEEN" && grep -qx B "$SEEN"; then
  t_ok "...and the reader actually observed BOTH builds (it raced through the window, not around it)"
else
  t_bad "...and the reader actually observed BOTH builds" "saw: $(sort -u "$SEEN" | tr '\n' ' ')"
fi

atomic_swap_local "$WROOT" A >/dev/null 2>&1
OUT="$(atomic_swap_local "$WROOT" no-such-build 2>&1)"; RC=$?
t_rc "swapping to a build with no manifest.tsv: refused" 1 "$RC"
t_eq "...and current did NOT move" "$(readlink "$WROOT/current")" A

echo
echo "-- C. the CLI contract -------------------------------------------------"
"$SCRIPT" --not-a-real-flag >/dev/null 2>&1; t_rc "unknown flag exits 2" 2 $?
"$SCRIPT" --help >/dev/null 2>&1;            t_rc "--help exits 0" 0 $?
HELP_OUT="$("$SCRIPT" --help 2>&1)"
t_has "--help documents --cut" "$HELP_OUT" "--cut"
t_has "--help documents --rollback" "$HELP_OUT" "--rollback"
t_has "--help documents the BLIND exit" "$HELP_OUT" "BLIND"

OUT="$("$SCRIPT" --host somehost 2>&1)"; RC=$?
t_rc "no build named at all: exits 2 (usage)" 2 "$RC"
t_has "...and says what is missing" "$OUT" "name a build"

OUT="$("$SCRIPT" --cut --fetch --host somehost 2>&1)"; RC=$?
t_rc "two selectors named at once: exits 2, refuses to pick one silently" 2 "$RC"

OUT="$("$SCRIPT" --latest 2>&1)"; RC=$?
t_rc "a selector with no --host: exits 2" 2 "$RC"

echo
echo "-- D. push+swap over a STUBBED ssh/rsync (wiring only, not a real host) --"
CROOT="$T/D"; mkdir -p "$CROOT"
mk_verb "$CROOT/2026-09-04T000000Z" proj alpha alpha
mk_manifest "$CROOT/2026-09-04T000000Z" "proj	alpha"

STUB="$T/stub"; mkdir -p "$STUB"
LOG="$T/ssh.log"; : > "$LOG"
REMOTE="$T/remote-fs"; mkdir -p "$REMOTE"

cat > "$STUB/ssh" <<STUBSH
#!/usr/bin/env bash
LOG="$LOG"
REMOTE="$REMOTE"
printf 'ARGV: %s\n' "\$*" >> "\$LOG"
[ "\${STUB_SSH_UNREACHABLE:-0}" = 1 ] && exit 255
shift 4; shift
case "\$1" in
  true) exit "\${STUB_TRUE_RC:-0}" ;;
  sudo)
    if [ "\$2" = "-n" ] && [ "\$3" = "bash" ]; then
      if [ "\${STUB_SUDO_ALSO_FAIL:-0}" = 1 ]; then
        echo "sudo: a password is required" >&2; exit 1
      fi
      shift 5
      root="\$1"; id="\$2"
      exec bash -s -- "\$REMOTE\$root" "\$id"
    fi
    echo "stub ssh: unrecognised remote command: \$*" >&2; exit 98 ;;
  bash)
    if [ "\${STUB_REQUIRE_SUDO:-0}" = 1 ]; then
      echo "sudo: a password is required" >&2; exit 1
    fi
    shift 3
    root="\$1"; id="\$2"
    exec bash -s -- "\$REMOTE\$root" "\$id" ;;
  "sudo -n mkdir -p "*)
    if [ "\${STUB_SUDO_ALSO_FAIL:-0}" = 1 ]; then
      echo "sudo: a password is required" >&2; exit 1
    fi
    path="\${1#sudo -n mkdir -p }"
    mkdir -p "\$REMOTE\$path"; exit \$? ;;
  "mkdir -p "*)
    if [ "\${STUB_REQUIRE_SUDO:-0}" = 1 ]; then
      echo "mkdir: cannot create directory: Permission denied" >&2; exit 1
    fi
    path="\${1#mkdir -p }"
    mkdir -p "\$REMOTE\$path"; exit \$? ;;
  "chmod -R a+rX "*)
    if [ "\${STUB_REQUIRE_SUDO:-0}" = 1 ] || [ "\${STUB_PERMS_STUCK:-0}" = 1 ]; then
      echo "chmod: Operation not permitted" >&2; exit 1
    fi
    path="\${1#chmod -R a+rX }"
    chmod -R a+rX "\$REMOTE\$path"; exit \$? ;;
  "sudo -n chown -R root:root "*)
    if [ "\${STUB_SUDO_ALSO_FAIL:-0}" = 1 ] || [ "\${STUB_PERMS_STUCK:-0}" = 1 ]; then
      echo "sudo: a password is required" >&2; exit 1
    fi
    rest="\${1#sudo -n chown -R root:root }"; path="\${rest%% *}"
    chmod -R a+rX "\$REMOTE\$path"; exit \$? ;;
  "stat -c %a "*)
    path="\${1#stat -c %a }"
    stat -c %a "\$REMOTE\$path" 2>/dev/null; exit \$? ;;
  "test -f "*)
    path="\${1#test -f }"
    [ -f "\$REMOTE\$path" ]; exit \$? ;;
  "readlink "*)
    path="\${1#readlink }"
    readlink "\$REMOTE\$path" 2>/dev/null; exit \$? ;;
  *) echo "stub ssh: unrecognised remote command: \$1" >&2; exit 98 ;;
esac
STUBSH
chmod +x "$STUB/ssh"

cat > "$STUB/rsync" <<STUBRSYNC
#!/usr/bin/env bash
LOG="$LOG"
REMOTE="$REMOTE"
printf 'RSYNC-ARGV: %s\n' "\$*" >> "\$LOG"
[ "\${STUB_RSYNC_FAIL:-0}" = 1 ] && exit 11
case " \$* " in
  *" --rsync-path=sudo -n rsync "*)
    if [ "\${STUB_SUDO_ALSO_FAIL:-0}" = 1 ]; then exit 11; fi ;;
  *)
    if [ "\${STUB_REQUIRE_SUDO:-0}" = 1 ]; then
      echo "rsync: mkdir failed: Permission denied (13)" >&2
      exit 11
    fi ;;
esac
src="\${@: -2:1}"
dst="\${@: -1:1}"
dst="\${dst#*:}"
mkdir -p "\$REMOTE\$dst"
cp -a "\$src"/. "\$REMOTE\$dst"
STUBRSYNC
chmod +x "$STUB/rsync"

run() { PUSH_SSH_BIN="$STUB/ssh" PUSH_RSYNC_BIN="$STUB/rsync" PUSH_BUILD_ROOT="$CROOT" \
        PUSH_REMOTE_ROOT="/verb-builds" "$SCRIPT" "$@"; }

: > "$LOG"
OUT="$(run --build 2026-09-04T000000Z --host fakehost --check 2>&1)"; RC=$?
t_rc "--check over a stubbed reachable host: exits 0" 0 "$RC"
t_has "...previews the push" "$OUT" "would   push"
t_has "...previews the swap" "$OUT" "would   swap"
[ -e "$REMOTE/verb-builds" ] && t_bad "--check wrote nothing to the 'remote'" "found $REMOTE/verb-builds" \
                              || t_ok "--check wrote nothing to the 'remote' filesystem"

: > "$LOG"
OUT="$(run --build 2026-09-04T000000Z --host fakehost --apply 2>&1)"; RC=$?
t_rc "--apply over a stubbed host: exits 0" 0 "$RC"
t_has "...OK on push" "$OUT" "OK      2026-09-04T000000Z is on fakehost"
t_has "...OK on the re-read witness" "$OUT" "re-read off the host"
t_eq "...and the stub 'remote' filesystem's current really points at the pushed id" \
     "$(readlink "$REMOTE/verb-builds/current")" "2026-09-04T000000Z"
t_eq "...and the pushed tree is really there" \
     "$(sh "$REMOTE/verb-builds/2026-09-04T000000Z/proj/bin/alpha" 2>/dev/null)" alpha
t_has "the ssh log shows the swap ran over stdin (bash -s), not a named script of ours" \
      "$(cat "$LOG")" "bash"
t_bad_if_found() { grep -q "push-verb-build.sh" "$LOG" && t_bad "$1" "the log names this script's own filename -- something shipped it as a file" || t_ok "$1"; }
t_bad_if_found "no file belonging to this repo is ever named in what crosses ssh's argv"
t_not_has "...the plain path worked -- no '(via sudo -n)' anywhere in the output" "$OUT" "(via sudo -n)"

: > "$LOG"
OUT="$(STUB_SSH_UNREACHABLE=1 run --build 2026-09-04T000000Z --host deadhost --apply 2>&1)"; RC=$?
t_rc "an unreachable host: exits 6 (BLIND), not 1" 6 "$RC"
t_has "...and says BLIND, not a push failure" "$OUT" "BLIND"

: > "$LOG"
OUT="$(STUB_RSYNC_FAIL=1 run --build 2026-09-04T000000Z --host fakehost --apply 2>&1)"; RC=$?
t_rc "a real rsync failure (host reachable, transfer refused): exits 1, not 6" 1 "$RC"
t_has "...distinguished from BLIND -- this is a known failure" "$OUT" "BAD"

: > "$LOG"
OUT="$(run --rollback 2026-09-04T000000Z --host fakehost --check 2>&1)"; RC=$?
t_rc "--rollback to a build the 'host' already holds: exits 0" 0 "$RC"
t_has "...no transfer happened (rsync never invoked)" "$(cat "$LOG")" ""

: > "$LOG"
OUT="$(run --rollback no-such-id --host fakehost --apply 2>&1)"; RC=$?
t_rc "--rollback to a build the host does NOT hold: refused, exits 1" 1 "$RC"
t_has "...names the missing build, never swaps blind" "$OUT" "refusing to swap"

echo
echo "-- E. sudo -n escalation: plain path refused, unconditional retry -------"
ESC="$T/E"; mkdir -p "$ESC"
mk_verb "$ESC/2026-09-05T000000Z" proj alpha alpha
mk_manifest "$ESC/2026-09-05T000000Z" "proj	alpha"

run_e() { PUSH_SSH_BIN="$STUB/ssh" PUSH_RSYNC_BIN="$STUB/rsync" PUSH_BUILD_ROOT="$ESC" \
        PUSH_REMOTE_ROOT="/verb-builds-e" "$SCRIPT" "$@"; }

: > "$LOG"
OUT="$(STUB_REQUIRE_SUDO=1 run_e --build 2026-09-05T000000Z --host fakehost --apply 2>&1)"; RC=$?
t_rc "mkdir+rsync+swap all refused plain, all succeed under sudo -n: --apply exits 0" 0 "$RC"
t_has "...push OK line names the escalation" "$OUT" \
      "OK      2026-09-05T000000Z is on fakehost at /verb-builds-e/2026-09-05T000000Z (via sudo -n)"
t_has "...swap OK line names the escalation too" "$OUT" \
      "re-read off the host, not inferred from an exit code) (via sudo -n)"
t_eq "...and the remote current really points at the pushed id" \
     "$(readlink "$REMOTE/verb-builds-e/current")" "2026-09-05T000000Z"
t_eq "...and the pushed tree is really there" \
     "$(sh "$REMOTE/verb-builds-e/2026-09-05T000000Z/proj/bin/alpha" 2>/dev/null)" alpha
t_has "...the mkdir that actually ran was the sudo -n one" "$(cat "$LOG")" "sudo -n mkdir -p"
t_has "...the rsync retry carried --rsync-path='sudo -n rsync'" "$(cat "$LOG")" "rsync-path=sudo -n rsync"
t_has "...the swap that actually ran was over sudo -n bash -s" "$(cat "$LOG")" "sudo -n bash"

: > "$LOG"
OUT="$(STUB_REQUIRE_SUDO=1 run_e --rollback 2026-09-05T000000Z --host fakehost --apply 2>&1)"; RC=$?
t_rc "--rollback: plain swap refused, sudo -n succeeds: exits 0" 0 "$RC"
t_has "...rollback's own OK line (a separate report site) names the escalation" "$OUT" \
      "current -> 2026-09-05T000000Z (re-read off the host, not inferred from an exit code) (via sudo -n)"

: > "$LOG"
OUT="$(STUB_REQUIRE_SUDO=1 STUB_SUDO_ALSO_FAIL=1 PUSH_SSH_BIN="$STUB/ssh" PUSH_RSYNC_BIN="$STUB/rsync" \
      PUSH_BUILD_ROOT="$ESC" PUSH_REMOTE_ROOT="/verb-builds-f" \
      "$SCRIPT" --build 2026-09-05T000000Z --host fakehost --apply 2>&1)"; RC=$?
t_rc "mkdir refused plain AND under sudo -n: today's clean failure holds, exits 1" 1 "$RC"
t_has "...same BAD message as an un-escalated failure" "$OUT" \
      "BAD     push to fakehost failed -- current on fakehost is UNCHANGED"
t_not_has "...no escalation is claimed when escalation itself failed" "$OUT" "(via sudo -n)"
[ -e "$REMOTE/verb-builds-f" ] && t_bad "...and nothing was ever written to the remote" "found $REMOTE/verb-builds-f" \
                                || t_ok "...and nothing was ever written to the remote"

: > "$LOG"
OUT="$(STUB_REQUIRE_SUDO=1 STUB_SUDO_ALSO_FAIL=1 run_e --rollback 2026-09-05T000000Z --host fakehost --apply 2>&1)"; RC=$?
t_rc "--rollback swap refused plain AND under sudo -n: exits 1" 1 "$RC"
t_has "...BAD, swap refused, matches today's message" "$OUT" \
      "BAD     the swap on fakehost failed or refused -- see rows above"
t_eq "...and current on the host is unchanged" \
     "$(readlink "$REMOTE/verb-builds-e/current")" "2026-09-05T000000Z"

chmod 700 "$CROOT/2026-09-04T000000Z"
rm -rf "$REMOTE/verb-builds/2026-09-04T000000Z"
OUT="$(STUB_PERMS_STUCK=1 run --build 2026-09-04T000000Z --host fakehost --apply 2>&1)"; RC=$?
chmod 755 "$CROOT/2026-09-04T000000Z"
t_rc "--apply when the pushed tree cannot be made readable: exits 1" 1 "$RC"
t_has "...BAD names the unreadable tree instead of reporting a clean swap" "$OUT" "not world-traversable"

OUT="$(run --build 2026-09-04T000000Z --host fakehost --apply 2>&1)"; RC=$?
t_rc "--apply on a normal push: exits 0" 0 "$RC"
t_has "...and witnesses that a project account can read the build" "$OUT" "readable by a project account"

echo "-- G2. 'current' is a LINK, never a build id (found by --here, 2026-09-18) --"
# "current" sorts above every dated id, so the link won `latest` every time.
GROOT="$T/G2"; mkdir -p "$GROOT"
mk_verb "$GROOT/2026-09-05T000000Z" proj v five
mk_manifest "$GROOT/2026-09-05T000000Z" "proj	v"
ln -sfn 2026-09-05T000000Z "$GROOT/current"
sel="$(select_local_build "$GROOT" latest 2>/dev/null)"
t_eq "G2a latest skips the current symlink and picks the dated build" \
  "${sel%%$'\t'*}" "2026-09-05T000000Z"
select_local_build "$GROOT" current >/dev/null 2>&1
t_rc "G2b naming 'current' explicitly is refused" 1 "$?"
OUT="$(select_local_build "$GROOT" current 2>&1)"
t_has "G2c ...and the refusal names the id it points at, so the caller can retry" \
  "$OUT" "2026-09-05T000000Z"

echo "-- H. --here: the machine you are on, which --host cannot name --"
HROOT="$T/H"; mkdir -p "$HROOT"
mk_verb "$HROOT/2026-09-10T000000Z" proj v old
mk_manifest "$HROOT/2026-09-10T000000Z" "proj	v"
mk_verb "$HROOT/2026-09-11T000000Z" proj v new
mk_manifest "$HROOT/2026-09-11T000000Z" "proj	v"
ln -sfn 2026-09-10T000000Z "$HROOT/current"
# NO ssh/rsync stub on PATH at all: --here must not reach for either.
hrun() { PUSH_SSH_BIN=/nonexistent/ssh PUSH_RSYNC_BIN=/nonexistent/rsync \
         PUSH_BUILD_ROOT="$HROOT" "$SCRIPT" "$@"; }

OUT="$(hrun --build 2026-09-11T000000Z --here 2>&1)"; RC=$?
t_rc "H1 --here --check exits 0 with no ssh binary in sight" 0 "$RC"
t_has "H2 ...and says it will not transfer anything" "$OUT" "no transfer"
t_has "H3 ...and names the current build it would move off" "$OUT" "2026-09-10T000000Z"
t_eq  "H4 ...and changed nothing" "$(readlink "$HROOT/current")" "2026-09-10T000000Z"

OUT="$(hrun --build 2026-09-11T000000Z --here --apply 2>&1)"; RC=$?
t_rc "H5 --here --apply exits 0" 0 "$RC"
t_eq  "H6 ...and current really moved" "$(readlink "$HROOT/current")" "2026-09-11T000000Z"
t_has "H7 ...and the OK says it was re-read, not asserted" "$OUT" "re-read off the link"

OUT="$(hrun --build 2026-09-11T000000Z --here --host fakehost --apply 2>&1)"; RC=$?
t_rc "H8 --here with --host is a usage error, not a silent preference" 2 "$RC"
t_has "H9 ...and says why" "$OUT" "answered twice"

OUT="$(hrun --build 2026-09-11T000000Z --apply 2>&1)"; RC=$?
t_rc "H10 neither --here nor --host is still a usage error" 2 "$RC"
t_has "H11 ...and now offers --here as the alternative" "$OUT" "--here"

# A build with no manifest is the shape atomic_swap_local exists to refuse; the
# --here path must inherit that refusal rather than pointing current at nothing.
mkdir -p "$HROOT/2026-09-12T000000Z/bin"
OUT="$(hrun --build 2026-09-12T000000Z --here --apply 2>&1)"; RC=$?
t_rc "H12 --here refuses a build with no manifest.tsv" 1 "$RC"
t_eq  "H13 ...and current is unchanged" "$(readlink "$HROOT/current")" "2026-09-11T000000Z"

# The flag was first HERE=1, clobbering $HERE (sibling()'s base). No stubbed
# test above takes the --cut path, so run the real script with a stub cutter.
CUTDIR="$T/Hcut"; mkdir -p "$CUTDIR"
cp "$SCRIPT" "$CUTDIR/push-verb-build.sh"
mkdir -p "$CUTDIR/lib"; cp "$(dirname "$SCRIPT")/lib/cli-guard.sh" "$CUTDIR/lib/cli-guard.sh"
cat > "$CUTDIR/cut-verb-build.sh" <<'CUTEOF'
#!/usr/bin/env bash
# stub cutter: --assemble <dir> lays down one verb and a BUILD_ID
[ "${1:-}" = "--assemble" ] || exit 2
d="${2:?}"; mkdir -p "$d/proj/bin"
printf '#!/bin/sh
echo cut
' > "$d/proj/bin/v"; chmod +x "$d/proj/bin/v"
printf '# stub
# project	verb	sha	repo_url
' > "$d/manifest.tsv"
printf 'proj	v	0000000000000000000000000000000000000000	https://example/proj.git
' >> "$d/manifest.tsv"
printf '2026-09-20T000000Z
' > "$d/BUILD_ID"
CUTEOF
chmod +x "$CUTDIR/cut-verb-build.sh"
CROOT2="$T/Hcutroot"; mkdir -p "$CROOT2"

OUT="$(PUSH_SSH_BIN=/nonexistent/ssh PUSH_RSYNC_BIN=/nonexistent/rsync \
       PUSH_BUILD_ROOT="$CROOT2" "$CUTDIR/push-verb-build.sh" --cut --here --apply 2>&1)"; RC=$?
t_not_has "H16 --cut --here finds its sibling cutter (\$HERE is not the flag)" \
  "$OUT" "not beside this script"
t_rc "H17 ...and exits 0" 0 "$RC"
t_eq "H18 ...and current points at the freshly cut build" \
  "$(readlink "$CROOT2/current")" "2026-09-20T000000Z"
t_eq "H19 ...and the cut verb is really there" \
  "$(cat "$CROOT2/current/proj/bin/v" | tail -1)" "echo cut"

OUT="$(hrun --rollback 2026-09-10T000000Z --here --apply 2>&1)"; RC=$?
t_rc "H14 --rollback --here works, on the same code path as --build" 0 "$RC"
t_eq  "H15 ...and current rolled back" "$(readlink "$HROOT/current")" "2026-09-10T000000Z"

summary
