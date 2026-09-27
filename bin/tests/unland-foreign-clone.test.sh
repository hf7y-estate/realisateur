#!/usr/bin/env bash
set -uo pipefail
. "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib/harness.sh"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT/unland-foreign-clone.sh"
[ -x "$SCRIPT" ] || { echo "FAIL: $SCRIPT not executable"; exit 1; }

harness_tmp

echo "unland-foreign-clone.test.sh"

mkpasswd() {  # two self-dev accounts in the band, the owning account, and two out-of-band names that must never be touched
  cat > "$T/passwd" <<'EOF'
root:x:0:0::/root:/bin/bash
zach:x:1000:1000::/home/zach:/bin/bash
ecosim:x:3011:3011::/home/ecosim:/bin/bash
realisateur:x:3010:3010::/home/realisateur:/bin/bash
senechal:x:3014:3014::/home/senechal:/bin/bash
wtul:x:3006:3006::/home/wtul:/bin/bash
nobody:x:65534:65534::/nonexistent:/usr/sbin/nologin
EOF
}
mkclone() {  # a committed, pushed clone -- the state a bootstrap copy is in
  local d="$1"
  mkdir -p "$d"
  git -C "$d" init -q
  git -C "$d" -c user.email=t@t -c user.name=t commit -q --allow-empty -m seed
  git -C "$d" branch -q -M main
  git clone -q --bare "$d" "$d.remote" 2>/dev/null
  git -C "$d" remote add origin "$d.remote"
  git -C "$d" push -q origin main 2>/dev/null
  git -C "$d" branch -q --set-upstream-to=origin/main main 2>/dev/null
}
NO_GH="$T/no-such-gh"   # a path that never exists: `command -v` fails clean, so every section below except M runs with the deploy-key check silently absent, same as a host with no gh
run() { SELFDEV_PASSWD="$T/passwd" SELFDEV_HOME_ROOT="$T/home" UNLAND_GH="$NO_GH" "$SCRIPT" realisateur "$@" 2>&1; }

section "A. the argument contract"
"$SCRIPT" --not-a-real-flag >/dev/null 2>&1; eq "A1 unknown flag exits 2" "$?" "2"
"$SCRIPT" --help >/dev/null 2>&1;            eq "A2 --help exits 0" "$?" "0"
OUT="$("$SCRIPT" --help 2>&1)"
has "A3 --help documents the BLIND exit" "$OUT" "BLIND"
has "A4 --help documents the refused-without-root exit" "$OUT" "refused"
has "A5 --help says --check is the default and removes nothing" "$OUT" "--check (default)"
"$SCRIPT" --check >/dev/null 2>&1;           eq "A6 no project exits 2 -- it removes nothing by default" "$?" "2"
"$SCRIPT" .. --check >/dev/null 2>&1;        eq "A7 a project that is not a plain name exits 2 -- it becomes a path component of an rm -rf" "$?" "2"
"$SCRIPT" senechal realisateur >/dev/null 2>&1; eq "A8 two projects exit 2 rather than silently sweeping one" "$?" "2"

section "B. an empty uid band is BLIND, not a silent pass"
: > "$T/empty-passwd"
OUT="$(SELFDEV_PASSWD="$T/empty-passwd" SELFDEV_HOME_ROOT="$T/home" "$SCRIPT" realisateur --check 2>&1)"; RC=$?
eq  "B1 no account in the band exits 6" "$RC" "6"
has "B2 and says BLIND" "$OUT" "BLIND"
has "B3 and says nothing was measured" "$OUT" "nothing was measured"

section "C. the default is a dry run that names every clone and removes none"
mkpasswd
mkclone "$T/home/ecosim/Documents/Projects/realisateur"
mkclone "$T/home/wtul/Documents/Projects/realisateur"
mkclone "$T/home/realisateur/Documents/Projects/realisateur"
mkclone "$T/home/zach/Documents/Projects/realisateur"   # uid 1000: a real checkout, out of band
OUT="$(run --check)"; RC=$?
has "C1 ecosim's clone is named" "$OUT" "would remove $T/home/ecosim/Documents/Projects/realisateur"
has "C2 wtul's clone is named"   "$OUT" "would remove $T/home/wtul/Documents/Projects/realisateur"
eq  "C3 findings exit 1" "$RC" "1"
[ -d "$T/home/ecosim/Documents/Projects/realisateur" ] \
  && ok "C4 --check removed nothing" || bad "C4 --check removed nothing"

section "D. the account that OWNS realisateur keeps its checkout"
has  "D1 it is reported KEPT, by name" "$OUT" "realisateur: KEPT -- this account owns realisateur"
hasnt "D2 and is never a removal target" "$OUT" "would remove $T/home/realisateur/"

section "E. out-of-band accounts are not in the roster at all"
hasnt "E1 zach (uid 1000) is untouched" "$OUT" "/home/zach/"
hasnt "E2 root (uid 0) is untouched"    "$OUT" "root:"

section "F. a clone holding work is KEPT, not destroyed"
echo 'an idea nobody pushed' > "$T/home/wtul/Documents/Projects/realisateur/x.idea"
OUT="$(run --check)"
has "F1 untracked residue keeps wtul's clone back" "$OUT" "wtul: KEPT"
has "F2 and says what the residue is" "$OUT" "uncommitted or untracked files"
rm -f "$T/home/wtul/Documents/Projects/realisateur/x.idea"

section "G. --apply is refused without root, and refusing removes nothing"
if [ "$(id -u)" -eq 0 ]; then
  ok "G1 skipped: already root, so the refusal branch cannot be reached"
else
  OUT="$(run --apply)"; RC=$?
  eq  "G1 --apply without root exits 5" "$RC" "5"
  has "G1b and says so" "$OUT" "needs root"
  [ -d "$T/home/ecosim/Documents/Projects/realisateur" ] \
    && ok "G2 a refused --apply removed nothing" || bad "G2 a refused --apply removed nothing"
fi

section "H. --apply really removes them -- the destructive path, exercised"
# fakeroot is enough -- id -u is the only root fact the script reads, and an untested rm -rf is the one path that must not ship on inspection alone.
if command -v fakeroot >/dev/null 2>&1; then
  OUT="$(SELFDEV_PASSWD="$T/passwd" SELFDEV_HOME_ROOT="$T/home" UNLAND_GH="$NO_GH" fakeroot "$SCRIPT" realisateur --apply 2>&1)"; RC=$?
  eq "H1 a clean sweep exits 0" "$RC" "0"
  [ -d "$T/home/ecosim/Documents/Projects/realisateur" ] \
    && bad "H2 ecosim's clone is gone" || ok "H2 ecosim's clone is gone"
  [ -d "$T/home/wtul/Documents/Projects/realisateur" ] \
    && bad "H3 wtul's clone is gone" || ok "H3 wtul's clone is gone"
  [ -d "$T/home/realisateur/Documents/Projects/realisateur" ] \
    && ok "H4 the OWNING account's checkout survived the sweep" \
    || bad "H4 the OWNING account's checkout survived the sweep"
  [ -d "$T/home/zach/Documents/Projects/realisateur" ] \
    && ok "H5 zach's uid-1000 checkout survived -- the band is the whole roster" \
    || bad "H5 zach's uid-1000 checkout survived"
else
  ok "H1 skipped: no fakeroot, so the removal path cannot be driven here"
fi

section "I. the project is an ARGUMENT: the same tool takes senechal's copies (hf7y-estate/scheduler#307)"
mkclone "$T/home/wtul/Documents/Projects/senechal"
mkclone "$T/home/ecosim/Documents/Projects/senechal"
mkclone "$T/home/senechal/Documents/Projects/senechal"
OUT_S="$(SELFDEV_PASSWD="$T/passwd" SELFDEV_HOME_ROOT="$T/home" UNLAND_GH="$NO_GH" "$SCRIPT" senechal --check 2>&1)"
has  "I1 wtul's senechal clone is named"   "$OUT_S" "would remove $T/home/wtul/Documents/Projects/senechal"
has  "I2 ecosim's senechal clone is named" "$OUT_S" "would remove $T/home/ecosim/Documents/Projects/senechal"
has  "I3 the account that OWNS senechal keeps its checkout" "$OUT_S" "senechal: KEPT -- this account owns senechal"
hasnt "I4 and is never a removal target" "$OUT_S" "would remove $T/home/senechal/"
hasnt "I5 a realisateur clone is not swept by a senechal run" "$OUT_S" "Projects/realisateur"

section "J. the witness proves BOTH halves"
OUT="$(run --check)"
has "J1 it counts the clones left" "$OUT" "clones left:"
has "J2 and that a verb still resolves" "$OUT" "command -v ausculte"
has "J3 it lists as root, so the 0700 home of the clone that must SURVIVE is not counted as removed" "$OUT" "sudo find"

section "K. it is declared, so it reaches a host by a named channel"
. "$ROOT/lib/propagation-set.sh"
ch="$(prop_channel unland-foreign-clone.sh 2>/dev/null)" || ch=""
eq "K1 prop_channel says provision -- an operator runs this once, on nobody's clock" "$ch" "provision"
printf '%s\n' "$(prop_host_tools)" | grep -qx unland-foreign-clone.sh \
  && ok "K2 it rides to the host libexec, the only copy monkey will have once the clones are gone" \
  || bad "K2 it rides to the host libexec" "absent from prop_host_tools"

section "L. a foreign clone's deploy key is revoked alongside it, or on its own if the clone is already gone (#852)"
cat > "$T/passwdL" <<'EOF'
root:x:0:0::/root:/bin/bash
realisateur:x:3010:3010::/home/realisateur:/bin/bash
ecosim:x:3011:3011::/home/ecosim:/bin/bash
ghost:x:3012:3012::/home/ghost:/bin/bash
wtul:x:3013:3013::/home/wtul:/bin/bash
EOF
mkclone "$T/homeL/ecosim/Documents/Projects/realisateur"
mkclone "$T/homeL/realisateur/Documents/Projects/realisateur"
cat > "$T/gh-stub" <<'EOF'  # ghost gets no clone below, only a deploy key -- the orphan #852 describes; wtul gets neither
#!/usr/bin/env bash
case "$*" in
  "repo deploy-key list --repo hf7y-estate/realisateur --json id,title --jq"*)
    printf '111\tmonkey-ecosim-realisateur\n222\tmonkey-ghost-realisateur\n' ;;
  "repo deploy-key delete 111 --repo hf7y-estate/realisateur") exit 0 ;;  # ecosim's: succeeds
  "repo deploy-key delete 222 --repo hf7y-estate/realisateur") exit 1 ;;  # ghost's: GitHub refuses, e.g. a stale token
  *) exit 1 ;;
esac
EOF
chmod +x "$T/gh-stub"
runL() {  # runL <mode> -- OUT/RC, against $T/homeL and the stub above
  SELFDEV_PASSWD="$T/passwdL" SELFDEV_HOME_ROOT="$T/homeL" SELFDEV_HOSTNAME=monkey \
    UNLAND_GH="$T/gh-stub" "$SCRIPT" realisateur "$1" 2>&1
}

OUT="$(runL --check)"; RC=$?
has "L1 ecosim's clone is still named" "$OUT" "would remove $T/homeL/ecosim/Documents/Projects/realisateur"
has "L2 and ecosim's deploy key is named alongside it" "$OUT" "would revoke deploy key 'monkey-ecosim-realisateur' (id 111) on hf7y-estate/realisateur"
has "L3 ghost has no clone but its orphaned key is still a finding" "$OUT" "would revoke deploy key 'monkey-ghost-realisateur' (id 222) on hf7y-estate/realisateur"
hasnt "L4 ghost is not reported as having a clone" "$OUT" "would remove $T/homeL/ghost/"
has "L5 wtul has neither a clone nor a key, and reads OK" "$OUT" "wtul: no clone"
eq "L6 findings exit 1" "$RC" "1"

if command -v fakeroot >/dev/null 2>&1; then
  OUT="$(SELFDEV_PASSWD="$T/passwdL" SELFDEV_HOME_ROOT="$T/homeL" SELFDEV_HOSTNAME=monkey \
          UNLAND_GH="$T/gh-stub" fakeroot "$SCRIPT" realisateur --apply 2>&1)"; RC=$?
  [ -d "$T/homeL/ecosim/Documents/Projects/realisateur" ] \
    && bad "L7 ecosim's clone is gone" || ok "L7 ecosim's clone is gone"
  has "L8 and ecosim's deploy key was revoked" "$OUT" "revoked deploy key 'monkey-ecosim-realisateur' (id 111) on hf7y-estate/realisateur"
  has "L9 ghost's orphaned key was attempted and GitHub's refusal is reported, not swallowed" "$OUT" "could not revoke deploy key 'monkey-ghost-realisateur' (id 222) on hf7y-estate/realisateur"
  eq "L10 a key GitHub refused to revoke is a finding" "$RC" "1"
else
  ok "L7 skipped: no fakeroot, so the apply path cannot be driven here"
fi

section "M. --host <hostname> drives the filesystem half over ssh; gh stays local (realisateur#895)"
mkdir -p "$T/stub"
cat > "$T/stub/ssh" <<'FAKE'
#!/usr/bin/env bash
a=(); while [ $# -gt 0 ]; do case "$1" in -o) shift 2 ;; *) a+=("$1"); shift ;; esac; done
printf 'FAKESSH host=%s\n' "${a[0]}" >&2
eval "${a[1]}"
FAKE
chmod +x "$T/stub/ssh"

cat > "$T/stub/sudo" <<'STUBSH'
#!/usr/bin/env bash
args=("$@"); i=0
while [ $i -lt ${#args[@]} ]; do
  case "${args[$i]}" in
    -u) i=$((i+2)); continue ;;
    -n|-H) i=$((i+1)); continue ;;
    *) break ;;
  esac
done
exec "${args[@]:$i}"
STUBSH
chmod +x "$T/stub/sudo"

cat > "$T/passwdM" <<'EOF'
root:x:0:0::/root:/bin/bash
realisateur:x:3010:3010::/home/realisateur:/bin/bash
ecosim:x:3011:3011::/home/ecosim:/bin/bash
EOF
mkclone "$T/homeM/ecosim/Documents/Projects/realisateur"
mkclone "$T/homeM/realisateur/Documents/Projects/realisateur"

cat > "$T/gh-stubM" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  "repo deploy-key list --repo hf7y-estate/realisateur --json id,title --jq"*)
    printf '333\tmonkey-ecosim-realisateur\n' ;;
  "repo deploy-key delete 333 --repo hf7y-estate/realisateur") exit 0 ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$T/gh-stubM"

runM() {  # runM <mode>
  SELFDEV_PASSWD="$T/passwdM" SELFDEV_HOME_ROOT="$T/homeM" UNLAND_GH="$T/gh-stubM" \
    SELFDEV_SSH_BIN="$T/stub/ssh" PATH="$T/stub:$PATH" \
    "$SCRIPT" realisateur "$1" --host monkey 2>&1
}

OUT="$(runM --check)"; RC=$?
has "M1 says it is driven over ssh"                 "$OUT" "on monkey, driven over ssh"
has "M2 the ssh transport really fired"              "$OUT" "FAKESSH host=monkey"
has "M3 ecosim's foreign clone is named"              "$OUT" "would remove $T/homeM/ecosim/Documents/Projects/realisateur on monkey"
has "M4 ecosim's deploy key is found via LOCAL gh"    "$OUT" "would revoke deploy key 'monkey-ecosim-realisateur' (id 333) on hf7y-estate/realisateur"
has "M5 the owning account's checkout is kept"        "$OUT" "realisateur: KEPT -- this account owns realisateur"
eq  "M6 findings exit 1"                              "$RC" "1"
[ -d "$T/homeM/ecosim/Documents/Projects/realisateur" ] \
  && ok "M7 --check removed nothing on the (fake) target" \
  || bad "M7 --check removed nothing on the (fake) target"

if command -v fakeroot >/dev/null 2>&1; then
  OUT="$(SELFDEV_PASSWD="$T/passwdM" SELFDEV_HOME_ROOT="$T/homeM" UNLAND_GH="$T/gh-stubM" \
          SELFDEV_SSH_BIN="$T/stub/ssh" PATH="$T/stub:$PATH" \
          fakeroot "$SCRIPT" realisateur --apply --host monkey 2>&1)"; RC=$?
  eq  "M8 a clean --apply over --host exits 0"          "$RC" "0"
  [ -d "$T/homeM/ecosim/Documents/Projects/realisateur" ] \
    && bad "M9 ecosim's clone is gone from the (fake) target" \
    || ok "M9 ecosim's clone is gone from the (fake) target"
  [ -d "$T/homeM/realisateur/Documents/Projects/realisateur" ] \
    && ok "M10 the owning account's checkout survived" \
    || bad "M10 the owning account's checkout survived"
  has "M11 says the removal happened on the target"     "$OUT" "removed $T/homeM/ecosim/Documents/Projects/realisateur on monkey"
  has "M12 and the deploy key was revoked, via LOCAL gh" "$OUT" "revoked deploy key 'monkey-ecosim-realisateur' (id 333) on hf7y-estate/realisateur"
else
  ok "M8 skipped: no fakeroot, so the apply-over-host path cannot be driven here"
fi

section "N. --host: an unreachable target is FATAL (exit 6), not a raw ssh code"
cat > "$T/stub/ssh-dead" <<'FAKE'
#!/usr/bin/env bash
exit 255
FAKE
chmod +x "$T/stub/ssh-dead"
OUT="$(SELFDEV_PASSWD="$T/passwdM" SELFDEV_HOME_ROOT="$T/homeM" UNLAND_GH="$T/gh-stubM" \
        SELFDEV_SSH_BIN="$T/stub/ssh-dead" PATH="$T/stub:$PATH" \
        "$SCRIPT" realisateur --check --host ghost 2>&1)"; RC=$?
eq  "N1 an unreachable host exits 6, not ssh's own 255" "$RC" "6"
has "N2 the message names the host and says FATAL"      "$OUT" "FATAL could not reach ghost"

echo
summary
