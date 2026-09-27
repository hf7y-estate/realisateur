#!/usr/bin/env bash
# SUBJECT: bin/dispatch-token-check.sh. Hermetic -- fixture credential file,
# stubbed `gh`. It never touches /etc/selfdev and never reaches GitHub, so it
# cannot pass because dexter's real credential happens to be healthy.
set -uo pipefail
. "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib/harness.sh"
harness_tmp
REPO="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../.." && pwd)"
SUBJ="$REPO/bin/dispatch-token-check.sh"

echo "dispatch-token-check.test.sh"

# The stub answers with whatever GH_OUT holds, so every branch is a fixture and
# none of them is a network call. It also RECORDS its argv, which is how the
# "never on a command line" claim below is measured rather than asserted.
cat > "$T/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$ARGV_LOG"
printf '%s\n' "${GH_OUT:-}"
exit "${GH_RC:-0}"
STUB
chmod +x "$T/gh"

SECRET="ghp_thisexactstringmustneverbeprinted"
run() { DISPATCH_TOKEN_FILE="$T/tok" DISPATCH_GH="$T/gh" ARGV_LOG="$T/argv" bash "$SUBJ" "$@" 2>&1; }
state() { run --state | awk -F'\t' -v k="$1" '$1==k{print $2}'; }

OK200=$'HTTP/2 200\nx-oauth-scopes: repo, workflow, read:org\n\n{"login":"hf7y"}'
NOWF=$'HTTP/2 200\nx-oauth-scopes: repo, read:org\n\n{"login":"hf7y"}'
DEAD=$'HTTP/2 401\n\n{"message":"Bad credentials"}'

section "A. the argument contract"
out="$(run --nonsense)"; rc "an unknown flag exits 2" 2 "$?"
has "...and says what it takes" "$out" "usage:"

section "B. a classic credential WITH workflow scope"
printf '%s\n' "$SECRET" > "$T/tok"; : > "$T/argv"
GH_OUT="$OK200" eq_out="$(GH_OUT="$OK200" run --state)"
eq "kind is read off the prefix"  "$(GH_OUT="$OK200" state kind)"      "classic"
eq "reachable"                    "$(GH_OUT="$OK200" state reachable)" "yes"
eq "login comes off the body"     "$(GH_OUT="$OK200" state login)"     "hf7y"
eq "workflows yes"                "$(GH_OUT="$OK200" state workflows)" "yes"

section "C. THE CREDENTIAL NEVER LEAVES -- measured, not promised"
hasnt "it is not in --state output"  "$eq_out" "$SECRET"
hasnt "nor in --check output"        "$(GH_OUT="$OK200" run --check)" "$SECRET"
hasnt "nor in gh's argv"             "$(cat "$T/argv")" "$SECRET"
hasnt "and the scope LIST is not published either -- the page is public" "$eq_out" "read:org"

section "D. the same credential WITHOUT workflow scope is the crt case"
eq "workflows no" "$(GH_OUT="$NOWF" state workflows)" "no"
has "...and says what that costs a pass" "$(GH_OUT="$NOWF" run --check)" ".github/workflows/"

section "E. a dead credential is 'no', never a quiet pass"
eq "401 is not reachable" "$(GH_OUT="$DEAD" state reachable)" "no"
GH_OUT="$DEAD" run --state >/dev/null; rc "...and exits 5" 5 "$?"
has "...and says the nightly pushes with it" "$(GH_OUT="$DEAD" run --check)" "the nightly pushes with is dead"

section "F. could-not-look is UNKNOWN, which is the defect this estate repeats"
out="$(GH_OUT="" GH_RC=1 run --state)"; r=$?
eq "no HTTP status at all is unknown, not no" "$(GH_OUT="" GH_RC=1 state reachable)" "unknown"
rc "...and exits 6 BLIND, not 0" 6 "$r"

rm -f "$T/tok"
out="$(run --state)"; rc "an unreadable credential file is 6 BLIND" 6 "$?"
has "...and names the file and the account" "$out" "no read of"

: > "$T/tok"
eq "an EMPTY file is 'no', a different answer from 'could not look'" "$(state reachable)" "no"

section "G. a shape whose permissions cannot be read back says so"
printf 'ghs_aninstallationtoken\n' > "$T/tok"
eq "an App installation token is named"  "$(GH_OUT="$OK200" state kind)"      "app-installation"
eq "...and workflows is UNKNOWN, never a guess" "$(GH_OUT="$OK200" state workflows)" "unknown"
printf 'github_pat_afinegrainedone\n' > "$T/tok"
eq "a fine-grained PAT is named too"     "$(GH_OUT="$OK200" state kind)"      "fine-grained"
eq "...and is equally unknown"           "$(GH_OUT="$OK200" state workflows)" "unknown"

summary
