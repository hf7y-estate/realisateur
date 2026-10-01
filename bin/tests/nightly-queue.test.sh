#!/usr/bin/env bash
# SUBJECT: agent/nightly.sh, the repo-set and queue-predicate half (#1383).
# `agent/repos` used to BE the candidate set; now it only orders the repos it
# names, and the org (`gh repo list hf7y-estate --no-archived`) is the set --
# a repo the org has and the file doesn't still runs, last. The queue count
# that gates a dispatch is also narrowed: open issues in an open milestone,
# not just open issues. Hermetic -- `sudo`, `docker` and `gh` are stubs on
# PATH, beside a COPY of the script.
set -uo pipefail
. "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib/harness.sh"
harness_tmp
REPO="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../.." && pwd)"

echo "nightly-queue.test.sh"

mkdir -p "$T/bin" "$T/agent" "$T/srv"
cp "$REPO/agent/nightly.sh" "$T/agent/nightly.sh"
# alpha and beta are the hand list; gamma and delta are in the org but not
# here, and must still run -- last.
printf 'alpha\nbeta\n' > "$T/repos"

cat > "$T/bin/sudo" <<'STUB'
#!/usr/bin/env bash
shift                                   # drop -n
[ "$1" = cat ] && { printf 'not-a-real-token\n'; exit 0; }
exec "$@"
STUB
cat > "$T/bin/docker" <<STUB
#!/usr/bin/env bash
case "\$1" in
  pull)  printf 'Status: pulled %s\n' "\$2"; exit 0 ;;
  image) printf 'ghcr.io/hf7y-estate/agent@sha256:fixture\n' ;;
esac
STUB

# The org is alpha, beta, gamma, delta -- gamma and delta are not in
# $T/repos. gh repo list prints this. gh api .../milestones answers each
# repo's OPEN milestones; a repo with a "fail-ms-<repo>" marker fails
# instead, the way an unreadable repo does for real. gh issue list answers
# each repo's open, non-needs-host/needs-human issues with their milestone.
#
# alpha: one issue on its one open milestone -- dispatches.
# beta:  one issue, but on a milestone that ISN'T in beta's open set (a
#        closed milestone in practice) -- this is the predicate under test:
#        an issue is not "queued" just because it exists and has *a*
#        milestone, only an OPEN one. Queue count must be 0, not 1.
# gamma: absent from $T/repos; one issue on its open milestone -- dispatches,
#        and LAST, proving the org is the candidate set, not the file.
# delta: absent from $T/repos; its milestones call fails -- unreadable, not
#        guessed at as empty.
printf 'alpha\nbeta\ngamma\ndelta\n' > "$T/org.txt"
touch "$T/fail-ms-delta"
cat > "$T/bin/gh" <<'STUB'
#!/usr/bin/env bash
args="$*"
repo=""
[[ "$args" =~ hf7y-estate/([a-zA-Z0-9_-]+) ]] && repo="${BASH_REMATCH[1]}"
case "$1" in
  repo)
    [ "$2" = list ] && { [ -f "$T/fail-repo-list" ] && exit 1; cat "$T/org.txt"; }
    ;;
  api)
    case "$args" in
      *milestones*)
        [ -f "$T/fail-ms-$repo" ] && exit 1
        case "$repo" in
          alpha) printf '[1]\n' ;;
          beta)  printf '[1]\n' ;;
          gamma) printf '[5]\n' ;;
          delta) printf '[9]\n' ;;
        esac
        ;;
    esac
    ;;
  issue)
    [ "$2" = list ] || exit 0
    case "$repo" in
      alpha) printf '[{"milestone":{"number":1}}]\n' ;;
      beta)  printf '[{"milestone":{"number":99}}]\n' ;;   # 99 is not open
      gamma) printf '[{"milestone":{"number":5}}]\n' ;;
      delta) printf '[{"milestone":{"number":9}}]\n' ;;
    esac
    ;;
  pr) : ;;  # the trailing PR recap; not under test here
esac
STUB
cat > "$T/agent/merge-carry.sh" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
cat > "$T/agent/run-agent.sh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$1" >> "$T/dispatched"
STUB
chmod +x "$T/bin/sudo" "$T/bin/docker" "$T/bin/gh" "$T/agent"/*.sh

run() {
  rm -f "$T/dispatched" "$T/srv/nightly."*.log
  PATH="$T/bin:$PATH" T="$T" AGENT_DIR="$T/srv" REPO_LIST="$T/repos" \
    AGENT_IMAGE="ghcr.io/hf7y-estate/agent:latest" bash "$T/agent/nightly.sh" 2>&1
}
dispatched() { cat "$T/dispatched" 2>/dev/null; }

section "A. the org, not the file, is the candidate set"
rm -f "$T/fail-repo-list"
out="$(run)"; rc "exits 0" 0 "$?"
has "...says a repo absent from the file is appended, and names it" "$out" \
  "org repos not in $T/repos, appended last: delta gamma"
eq "...alpha dispatched" "$(dispatched | sed -n 1p)" "alpha"
eq "...gamma dispatched too, absent from the file or not" "$(dispatched | sed -n 2p)" "gamma"
eq "...only those two ran (beta and delta did not)" "$(dispatched | wc -l | tr -d ' ')" "2"

section "B. the queue is issues on an OPEN milestone, not just issues"
has "...beta's issue sits on a milestone that isn't open, so its queue reads empty" \
  "$out" "--- beta: queue empty, skipping"
hasnt "...beta was never dispatched into" "$(dispatched)" "beta"

section "C. an unreadable queue is said, not guessed at as empty"
has "...delta's milestones call failed, and that is named, not swallowed" "$out" \
  "--- delta: COULD NOT READ THE QUEUE -- skipping, not guessing"
hasnt "...delta was never dispatched into" "$(dispatched)" "delta"

section "D. a repo listed by hand but gone from the org is skipped and named"
printf 'alpha\nbeta\nzzz-retired\n' > "$T/repos"
out="$(run)"
has "...says which, and why" "$out" "zzz-retired: in $T/repos but not in the hf7y-estate org -- skipping"
hasnt "...never tried to queue-check it" "$out" "zzz-retired: queue empty"
printf 'alpha\nbeta\n' > "$T/repos"

section "E. the org listing itself failing falls back to the file, not to nothing"
touch "$T/fail-repo-list"
out="$(run)"; rc "exits 0" 0 "$?"
has "...says the org couldn't be read" "$out" "COULD NOT LIST hf7y-estate -- running $T/repos's order only, nothing appended"
eq "...and still ran the file's own repos" "$(dispatched | sed -n 1p)" "alpha"
hasnt "...but appended nothing it couldn't see" "$(dispatched)" "gamma"
rm -f "$T/fail-repo-list"

summary
