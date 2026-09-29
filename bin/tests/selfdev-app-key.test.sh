#!/usr/bin/env bash
# selfdev-app-key.test.sh -- witness for bin/lib/selfdev-app-key.sh (the
# resolution every reader shares) and for bin/selfdev-app-key.sh's refusals.
#
set -uo pipefail
# shellcheck source=bin/tests/lib/harness.sh
. "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib/harness.sh"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LIB="$ROOT/lib/selfdev-app-key.sh"
SCRIPT="$ROOT/selfdev-app-key.sh"
[ -r "$LIB" ]    || { echo "FAIL: $LIB missing"; exit 1; }
[ -x "$SCRIPT" ] || { echo "FAIL: $SCRIPT not executable"; exit 1; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT

echo "selfdev-app-key.test.sh"

echo "-- A. the default is host-wide, not a home directory"
OUT="$(bash -c '. "$1"; selfdev_app_conf' _ "$LIB")"
eq  "A1 default conf is /etc/selfdev/gh-app.conf" "$OUT" "/etc/selfdev/gh-app.conf"
grep -q 'ecosystem\|\$HOME/\.config/selfdev' "$LIB" \
  && bad "A2 the lib still names a per-account path as a default" \
  || ok  "A2 no per-account path is a default anywhere in the lib"

echo "-- B. \$SELFDEV_APP_CONF wins, per invocation"
OUT="$(SELFDEV_APP_CONF="$T/other.conf" bash -c '. "$1"; selfdev_app_conf' _ "$LIB")"
eq  "B1 the env override is returned verbatim" "$OUT" "$T/other.conf"

echo "-- C. loading: file values, and env beating them"
cat > "$T/c.conf" <<EOF
SELFDEV_APP_ID=111
SELFDEV_APP_KEY=$T/from-file.pem
SELFDEV_GH_OWNER=fileowner
EOF
OUT="$(SELFDEV_APP_CONF="$T/c.conf" bash -c '. "$1"; selfdev_app_load; echo "$SELFDEV_APP_ID $SELFDEV_APP_KEY $SELFDEV_GH_OWNER"' _ "$LIB")"
eq  "C1 the conf's values are loaded" "$OUT" "111 $T/from-file.pem fileowner"
OUT="$(SELFDEV_APP_CONF="$T/c.conf" SELFDEV_APP_ID=999 bash -c '. "$1"; selfdev_app_load; echo "$SELFDEV_APP_ID"' _ "$LIB")"
eq  "C2 an env value already set is NOT clobbered by the file" "$OUT" "999"
# The bug this pins: sourcing a conf AFTER capturing the environment silently
# runs a scheduler job as the App named in the file, with the right
# permissions on the wrong repos. selfdev-gh-app.sh's own header names it.
SELFDEV_APP_CONF="$T/nope.conf" bash -c '. "$1"; selfdev_app_load' _ "$LIB"
eq  "C3 no conf and no env is rc 1, not a silent default" "$?" "1"
cat > "$T/partial.conf" <<'EOF'
SELFDEV_GH_OWNER=owner-only
EOF
SELFDEV_APP_CONF="$T/partial.conf" bash -c '. "$1"; selfdev_app_load' _ "$LIB"
eq  "C4 a conf with no APP_ID is rc 2 (present but incomplete)" "$?" "2"

echo "-- D. readable is a READ, not a stat"
: > "$T/readable.pem"
bash -c '. "$1"; selfdev_app_readable "$2"' _ "$LIB" "$T/readable.pem"
eq  "D1 a readable file passes" "$?" "0"
chmod 000 "$T/readable.pem"
if [ "$(id -u)" -eq 0 ]; then
  ok "D2 skipped: running as root, which can read mode 000"
else
  bash -c '. "$1"; selfdev_app_readable "$2"' _ "$LIB" "$T/readable.pem"
  eq  "D2 a present-but-unreadable file FAILS (the group-not-yet-in-effect case)" "$?" "1"
fi
chmod 600 "$T/readable.pem"

echo "-- E. the script refuses rather than half-acting"
OUT="$("$SCRIPT" --apply --uid-min 999999 --uid-max 999999 2>&1)"; RC=$?
if [ "$(id -u)" -eq 0 ]; then
  ok "E1 skipped: running as root"
else
  eq  "E1 --apply without root exits 2" "$RC" "2"
  has "E1b and says so" "$OUT" "needs root"
fi
OUT="$("$SCRIPT" --check --uid-min 999999 --uid-max 999999 2>&1)"; RC=$?
has "E2 --check names the host-wide dir it is checking" "$OUT" "/etc/selfdev"
case "$RC" in 0|1) ok "E3 --check exits 0 (at target) or 1 (findings), never 5" ;; *) bad "E3 --check exited $RC" ;; esac
grep -q 'rm -rf' "$SCRIPT" && bad "E4 the script contains an rm -rf" || ok "E4 no rm -rf anywhere in the script"
# --retire-copies is the only deleting path, and its refusal is the safety
# property: removing private copies while the host-wide key is unreadable
# leaves an account with no credential at all.
has "E5 retire refuses without a host-wide key" "$(sed -n '/--retire-copies)/,/^esac/p' "$SCRIPT")" "refusing: there is no host-wide key"
has "E6 retire refuses while any account cannot read it" "$(sed -n '/--retire-copies)/,/^esac/p' "$SCRIPT")" "cannot read"

echo "-- F. the argument contract"
"$SCRIPT" --not-a-real-flag >/dev/null 2>&1; eq "F1 unknown flag exits 2" "$?" "2"
"$SCRIPT" --help >/dev/null 2>&1;            eq "F2 --help exits 0" "$?" "0"

echo "-- G. every reader resolves through the lib, not its own spelling"
f="$ROOT/selfdev-gh-app.sh"
n="$(basename "$f")"
code="$(grep -v '^[[:space:]]*#' "$f")"
case "$code" in
  *'$HOME/.config/selfdev/gh-app.conf'*|*'$HOME/.config/selfdev/app.pem'*)
    bad "G: $n still defaults to a per-account credential path" ;;
  *) ok "G: $n no longer defaults to a per-account credential path" ;;
esac

echo "-- H. --apply exits on its post-apply state, not its pre-apply reading (#1284)"
if [ "$(id -u)" -eq 0 ]; then
  H="$(mktemp -d)"; trap 'rm -rf "$H"' RETURN 2>/dev/null || true
  mkdir -p "$H/etc/selfdev"
  : > "$H/src.pem"
  : > "$H/etc/selfdev/app.pem"; chmod 600 "$H/etc/selfdev/app.pem"
  HGRP="selfdevtest_h_$$"
  HOUT="$(SELFDEV_APP_DIR="$H/etc/selfdev" SELFDEV_APP_GROUP="$HGRP" \
    "$SCRIPT" --apply --uid-min 999999 --uid-max 999999 \
    --app-id 123 --owner testowner --from "$H/src.pem" 2>&1)"
  HRC=$?
  groupdel "$HGRP" >/dev/null 2>&1
  rm -rf "$H"
  has "H1 apply still reports the pre-apply BAD it then fixed" "$HOUT" "BAD"
  has "H2 apply fixed it (witness passed)" "$HOUT" "witness: every account read"
  eq  "H3 exit is 0 -- a bad reading apply already fixed is not a failed apply" "$HRC" "0"
else
  ok "H: skipped, not root"
fi

echo
summary
