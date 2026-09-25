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

# THE CONTRACT, in one place. MOVED 2026-09-03 (Zach): deploy-drift and
# comment-claims are now REQUIRED. The old reading called them advisory because
# "a third party could wedge every PR here" -- but deploy-drift's subject is
# hf7y/verbs, which is this estate's own repo, not a third party, and its red
# means the deployed workflow diverged from the source (#645, which cost a
# night of silent no-op cuts). Zach: "whatever breaks, we should fix it anyway."
# So a red one blocks a merge until the drift is fixed, which is the work
# either way.
# RIPPED OUT 2026-09-24, Zach: "CI was definitely a bad idea and should be
# ripped out." Every check on every repo is ADVISORY now: the workflows still
# run and still report, they just do not gate a merge. Measured before the
# change: `prose / prose` was required on 21 of 55 repos -- the most-required
# check in the estate, and passing it only proved the repo got no wordier.
#
# enforce_admins STAYS on, and section B still asserts it. That one has an
# incident behind it: a subagent pushed main directly on 2026-07-25.
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
