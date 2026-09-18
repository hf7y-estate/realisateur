#!/usr/bin/env bash
# SUBJECT: bin/selfdev-release-tick.sh --identity. Hermetic -- fixture passwd,
# fixture homes, TICK_SUDO="" so git runs as the test user against a fixture
# HOME. It must never touch the running user's own ~/.gitconfig: that is the
# bug class this repairs (13 accounts on monkey declared `test@example.com`).
set -uo pipefail
. "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib/harness.sh"
harness_tmp
REPO="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../.." && pwd)"
TICK="$REPO/bin/selfdev-release-tick.sh"

echo "selfdev-release-tick-identity.test.sh"

mkdir -p "$T/homes/drifted" "$T/homes/correct" "$T/homes/outofband"
printf 'drifted:x:3001:3001::%s/homes/drifted:/bin/bash\n' "$T" >  "$T/passwd"
printf 'correct:x:3002:3002::%s/homes/correct:/bin/bash\n'  "$T" >> "$T/passwd"
printf 'outofband:x:1001:1001::%s/homes/outofband:/bin/bash\n' "$T" >> "$T/passwd"

# the estate's real defect, in a fixture: declares the test address, commits as itself
HOME="$T/homes/drifted" git config --global user.name  test
HOME="$T/homes/drifted" git config --global user.email test@example.com
HOME="$T/homes/correct" git config --global user.name  correct
HOME="$T/homes/correct" git config --global user.email correct@selfdev.invalid
HOME="$T/homes/outofband" git config --global user.email test@example.com

MINE="$(git config --global --get user.email 2>/dev/null)"   # the runner's own, recorded BEFORE

tick() { TICK_SUDO="" TICK_SURVEY_PASSWD="$T/passwd" TICK_UID_MIN=3000 TICK_UID_MAX=3099 \
         VERB_BUILD_ROOT="$T/builds" bash "$TICK" --identity "$@" 2>&1; }
declared() { HOME="$T/homes/$1" git config --global --get user.email 2>/dev/null; }

section "A. --identity reports drift and changes nothing"
out="$(tick)"; rc "A0 a finding exits 1" 1 $?
has "A1 the drifted account is named with both values" "$out" "drifted declares test <test@example.com>"
has "A2 ...and the repair is spelled out, not described" "$out" "--identity --apply"
has "A3 an account that already declares itself is ok, not silent" "$out" "correct declares itself"
eq  "A4 --check wrote nothing" "$(declared drifted)" "test@example.com"

section "B. --identity --apply REPAIRS, and the witness is a re-read"
out="$(tick --apply)"; rc "B0 a clean repair exits 0" 0 $?
eq  "B1 the declaration now matches what the account commits as" \
  "$(declared drifted)" "drifted@selfdev.invalid"
eq  "B2 ...and the name with it" \
  "$(HOME="$T/homes/drifted" git config --global --get user.name)" "drifted"
has "B3 the repair names what it replaced, so a log reader can see it" "$out" "REPAIRED: was test <test@example.com>"

section "C. the previous value is preserved, once"
eq "C1 the overwritten address is recoverable" \
  "$(HOME="$T/homes/drifted" git config --global --get selfdev.previousUserEmail)" "test@example.com"
tick --apply >/dev/null
eq "C2 a re-run does NOT overwrite the backup with this function's own value" \
  "$(HOME="$T/homes/drifted" git config --global --get selfdev.previousUserEmail)" "test@example.com"

section "D. blast radius"
eq "D1 an account outside the uid band is never touched" \
  "$(declared outofband)" "test@example.com"
eq "D2 and the RUNNING USER's own global identity is untouched -- a test that writes a person's \$HOME config is the bug" \
  "$(git config --global --get user.email 2>/dev/null)" "$MINE"

section "E. it runs on the clock that already runs, not on a new one"
code="$(grep -v '^\s*#' "$TICK")"
has "E1 the host-wide tick calls it beside sync_host_tools" "$code" "reconcile_identities"
case "$code" in
  *'[ "$IDENTITY" = 1 ] || [ "$TICK_LINK" = 1 ] || return 0'*)
    ok "E2 gated to the host-wide tick (TICK_LINK=1) or an explicit --identity" ;;
  *) bad "E2 gated to the host-wide tick or --identity" "a per-account tick would write other accounts' configs" ;;
esac

summary
