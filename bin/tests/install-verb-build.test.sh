#!/usr/bin/env bash
#
# install-verb-build.test.sh -- witness for the direction of a switch.
#
# THE CASE THIS FILE EXISTS FOR (#1278 ss1): `--check` compared the installed
# id to the newest approved one for INEQUALITY, so a host holding a build the
# channel has not approved -- what push-verb-build.sh --cut --host leaves on a
# proving ground -- read as "a newer build is available", and --apply adopted
# an id eleven days older. Nothing in the tree could tell forward from
# backward, so the regression was invisible to every other suite.
#
# Offline by construction: REMOTE is a local bare repo, so nothing here
# touches the network or this host's real build root.
set -uo pipefail
# shellcheck source=bin/tests/lib/harness.sh
. "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib/harness.sh"
SCRIPT="$(cd "$(dirname "$0")/.." && pwd)/install-verb-build.sh"
[ -x "$SCRIPT" ] || { echo "FAIL: $SCRIPT not executable"; exit 1; }
harness_tmp

OLD=2026-09-07T031807Z
NEW=2026-09-18T194557Z

# A meta-repo with ONE approved build, $OLD.
META="$T/verbs"
git init -q "$META"
git -C "$META" config user.email t@example.com
git -C "$META" config user.name t
printf 'verb\tpath\nfoo\trealisateur/bin/foo\n' > "$META/manifest.tsv"
mkdir -p "$META/realisateur/bin"; : > "$META/realisateur/bin/foo"
git -C "$META" add -A && git -C "$META" commit -qm build
git -C "$META" tag "build/$OLD" && git -C "$META" tag "approved/$OLD"

# A host pinned to $NEW: newer than anything the channel has approved.
root() { # $1 = the build id `current` points at
  rm -rf "$T/root"; mkdir -p "$T/root/$1"
  ln -s "$1" "$T/root/current"
}
run() { "$SCRIPT" --build-root "$T/root" --remote "$META" "$@" 2>&1; }

section "A. a host AHEAD of the channel"
root "$NEW"
out="$(run --check)"; rc_check=$?
rc  "A1 --check exits 0: there is nothing to adopt" 0 "$rc_check"
has "A2 it says AHEAD"                    "$out" 'AHEAD of the channel'
has "A3 it names the id it will not take" "$out" "$OLD"
hasnt "A4 it does not call the older build newer" "$out" 'a newer build is available'

out="$(run --latest --apply)"; rc_apply=$?
rc  "A5 --latest --apply refuses"          1 "$rc_apply"
has "A6 it says BACKWARD"                  "$out" 'BACKWARD'
eq  "A7 current did not move"              "$(readlink "$T/root/current")" "$NEW"

section "B. a host BEHIND the channel still adopts"
git -C "$META" tag "build/$NEW"; git -C "$META" tag "approved/$NEW"
root "$OLD"
out="$(run --check)"; rc_check=$?
rc  "B1 --check exits 1"                   1 "$rc_check"
has "B2 it says a newer build is available" "$out" 'a newer build is available'

section "C. a host ON the newest approved build"
root "$NEW"
out="$(run --check)"; rc_check=$?
rc  "C1 --check exits 0"                   0 "$rc_check"
has "C2 it says up to date"                "$out" 'up to date'

summary
