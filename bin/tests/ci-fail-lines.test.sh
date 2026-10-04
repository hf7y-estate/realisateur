#!/usr/bin/env bash
# SUBJECT: bin/ci-fail-lines.sh (#1140). HERMETIC -- a fake `gh` answers every
# call from fixtures; nothing here reaches the network. The point of the
# subject is that a job the API calls "failure" with zero matching lines is
# BLIND, not a quiet pass -- that is what sections D and E measure.
set -uo pipefail
. "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib/harness.sh"
harness_tmp
REPO="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../.." && pwd)"
SUBJ="$REPO/bin/ci-fail-lines.sh"

echo "ci-fail-lines.test.sh"

# The stub answers `repo view`, the jobs listing and each job's log from
# fixtures; FAKE_JOBS_RC / FAKE_LOG_RC let a test make either read fail.
cat > "$T/gh" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  'repo view --json nameWithOwner -q .nameWithOwner')
    printf '%s\n' "${FAKE_REPO:-owner/repo}"; exit 0 ;;
  *"actions/runs/"*"/jobs --paginate"*)
    [ "${FAKE_JOBS_RC:-0}" -eq 0 ] || exit "$FAKE_JOBS_RC"
    printf '%s' "${FAKE_JOBS:-}"; exit 0 ;;
  *"actions/jobs/"*"/logs"*)
    id="${2#*/actions/jobs/}"; id="${id%/logs}"
    [ "${FAKE_LOG_RC:-0}" -eq 0 ] || exit "$FAKE_LOG_RC"
    case "$id" in
      1) printf '%s' "${FAKE_LOG_1:-}" ;;
      2) printf '%s' "${FAKE_LOG_2:-}" ;;
    esac
    exit 0 ;;
esac
exit 1
STUB
chmod +x "$T/gh"

run() {  # run <argv...> -- OUT/RC, with every FAKE_* fixture exported
  OUT="$(CI_FAIL_LINES_GH="$T/gh" \
    FAKE_REPO="${FAKE_REPO:-}" FAKE_JOBS="${FAKE_JOBS:-}" FAKE_JOBS_RC="${FAKE_JOBS_RC:-0}" \
    FAKE_LOG_1="${FAKE_LOG_1:-}" FAKE_LOG_2="${FAKE_LOG_2:-}" FAKE_LOG_RC="${FAKE_LOG_RC:-0}" \
    bash "$SUBJ" "$@" 2>&1)"; RC=$?
}

section "A. the argument contract"
run; rc "A1 no run id exits 2" 2 "$RC"
run --nonsense; rc "A2 an unknown flag exits 2" 2 "$RC"
run 123 456; rc "A3 two run ids exits 2" 2 "$RC"
run abc; rc "A4 a non-numeric run id exits 2" 2 "$RC"
run --help; rc "A5 --help exits 0" 0 "$RC"
has "A6 --help documents the BLIND exit" "$OUT" "6  BLIND"

section "B. no failed jobs is clean"
FAKE_JOBS=''
run 1; rc "B1 exits 0" 0 "$RC"
has "B2 says so" "$OUT" "no failed jobs"

section "C. a failed job with failure lines in its log"
FAKE_JOBS=$'1\tsuites\n'
FAKE_LOG_1=$'line 1\nline 2\n##[error] something broke\nFAILED: bin/tests/carry-drift.test.sh\ntrailer\n'
run 1; rc "C1 exits 0" 0 "$RC"
has "C2 the job name is labelled" "$OUT" "suites (job 1)"
has "C3 the ##[error] line is printed" "$OUT" "##[error] something broke"
has "C4 the FAILED: line is printed" "$OUT" "FAILED: bin/tests/carry-drift.test.sh"
hasnt "C5 the unrelated trailer line is NOT printed" "$OUT" "trailer"

section "D. a failed job with ZERO matching lines is BLIND, not clean (#1140)"
FAKE_JOBS=$'1\tsuites\n'
FAKE_LOG_1=$'all tests passed\nok\nok\n'
run 1; rc "D1 exits 6, never 0" 6 "$RC"
has "D2 the job is named BLIND" "$OUT" "BLIND  suites (job 1)"
has "D3 and says why: failed yet zero matching lines" "$OUT" "zero ##[error]/FAILED: lines -- not clean"

section "E. a job log that cannot be read is BLIND too"
FAKE_JOBS=$'1\tsuites\n'
FAKE_LOG_RC=1
run 1; rc "E1 exits 6" 6 "$RC"
has "E2 says the log could not be read" "$OUT" "could not be read"
FAKE_LOG_RC=0

section "F. the job list itself unreadable is BLIND, not zero failures"
FAKE_JOBS_RC=1
run 1; rc "F1 exits 6, not the 0 of section B" 6 "$RC"
has "F2 names the run and repo" "$OUT" "job list for run 1"
FAKE_JOBS_RC=0

section "G. two failed jobs: one clean report does not hide the other's BLIND"
FAKE_JOBS=$'1\tsuites\n2\tshellcheck\n'
FAKE_LOG_1=$'##[error] boom\n'
FAKE_LOG_2=$'all green somehow\n'
run 1; rc "G1 exits 6 -- one BLIND job taints the run" 6 "$RC"
has "G2 the clean job's line still printed" "$OUT" "##[error] boom"
has "G3 the other job's BLIND still printed" "$OUT" "BLIND  shellcheck (job 2)"

section "H. --repo skips the repo-view read entirely"
FAKE_REPO='should-not-be-used/repo'
FAKE_JOBS=''
run --repo real/repo 1; rc "H1 exits 0" 0 "$RC"
has "H2 the given repo is used" "$OUT" "real/repo"
hasnt "H3 not the one repo view would have answered" "$OUT" "should-not-be-used"

summary
