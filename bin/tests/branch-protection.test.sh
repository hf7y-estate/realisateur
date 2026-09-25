#!/usr/bin/env bash
# branch-protection.test.sh -- which checks actually gate `main`, read from the
# API rather than asserted in a comment. An agent decides whether it may merge
# its own PR from this, and a comment saying it goes false silently.
#
# RUNNER: .github/workflows/tests.yml (suites)
# Exit: 0 asserted, or could not look and SAID so. 1 the contract moved.
set -uo pipefail
. "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib/harness.sh"

REPO="${BRANCH_PROTECTION_REPO:-hf7y/realisateur}"
BRANCH="${BRANCH_PROTECTION_BRANCH:-main}"

# THE CONTRACT, and the only place this repo's expected protection is written.
# REQUIRED gates a merge; ADVISORY runs, reports, and does not.
#
# An EMPTY REQUIRED is a deliberate state, not a gap. With no required check,
# "all required checks passed" is vacuously true, so `--auto` merges on arming
# rather than on green and a red suite lands anyway. Verify a change by running
# the suite, never by reading the gate.
#
# enforce_admins is asserted separately, in section B: it answers a different
# question, and it is the half with an incident behind it.
REQUIRED=()
ADVISORY=("prose / prose" "shellcheck" "suites" "comment-claims" "deploy-drift")

section "A. the required check set on $REPO@$BRANCH"

body="$(gh api "repos/$REPO/branches/$BRANCH/protection" 2>&1)"; rc=$?
if [ "$rc" -ne 0 ]; then
  case "$body" in
    *"Branch not protected"*)
      bad "$BRANCH is protected" \
          "the API says it is NOT. Anyone can push over ${REQUIRED[*]}.
        Remedy: re-enable protection on $REPO@$BRANCH (required checks
        ${REQUIRED[*]}, enforce_admins on), or change this witness if that was deliberate."
      summary; exit $?
      ;;
    *)
      # Reading protection needs admin. A CI GITHUB_TOKEN does not have it, so
      # this is the expected path there -- named, never counted as a pass.
      echo "  BLIND cannot read protection on $REPO ($(printf '%s' "$body" | tr '\n' ' ' | cut -c1-100))"
      echo "        Nothing in section A was exercised. Re-run where \`gh\` is authenticated as an admin."
      summary; exit $?
      ;;
  esac
fi

got_ctx="$(printf '%s' "$body" | jq -r '.required_status_checks.contexts[]' 2>/dev/null | sort)"
want_ctx="$(printf '%s\n' "${REQUIRED[@]}" | sort)"
eq "the required contexts are exactly the ones this repo develops" "$got_ctx" "$want_ctx"
[ "$got_ctx" = "$want_ctx" ] || printf '        %s\n' \
  "Remedy: either restore the contexts above on $REPO@$BRANCH, or update REQUIRED/ADVISORY here and say why in the PR."

eq "enforce_admins is on, so a direct push to $BRANCH is refused for everyone" \
   "$(printf '%s' "$body" | jq -r '.enforce_admins.enabled')" "true"

for job in "${ADVISORY[@]}"; do
  case "$got_ctx" in
    *"$job"*) bad "$job is advisory, not required" \
        "it is a required check now. It runs on every PR either way; making it
        required means a red $job BLOCKS merges. Remedy: drop it from the required
        contexts, or move it to REQUIRED here." ;;
    *) ok "$job stays advisory -- red does not block a merge" ;;
  esac
done

summary
