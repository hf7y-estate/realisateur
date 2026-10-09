#!/usr/bin/env bash
# SUBJECT: agent/nightly.sh, the image half. Hermetic -- `sudo`, `docker` and
# `gh` are stubs on PATH, and the steps it calls are stubs beside a COPY of
# the script, so this suite pulls nothing, dispatches nothing, and cannot pass
# because dexter happens to hold the right image.
set -uo pipefail
. "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib/harness.sh"
harness_tmp
REPO="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../.." && pwd)"

echo "nightly-image.test.sh"

mkdir -p "$T/bin" "$T/agent" "$T/srv"
cp "$REPO/agent/nightly.sh" "$T/agent/nightly.sh"

# `sudo -n <cmd>` runs the stub of <cmd>; the token read is the one real thing
# it has to answer, and it answers with a string no remote would accept.
cat > "$T/bin/sudo" <<'STUB'
#!/usr/bin/env bash
shift                                   # drop -n
[ "$1" = cat ] && { printf 'not-a-real-token\n'; exit 0; }
exec "$@"
STUB
# pull exits $T/pull_rc; `image inspect` prints $T/digest or exits 1 if absent.
cat > "$T/bin/docker" <<'STUB'
#!/usr/bin/env bash
case "$1" in
  pull)  printf 'Status: pulled %s\n' "$2"; exit "$(cat "$T/pull_rc" 2>/dev/null || echo 0)" ;;
  image) [ -f "$T/digest" ] || exit 1; cat "$T/digest" ;;
esac
STUB
# Answers the three calls nightly.sh makes before it dispatches: the org
# listing (just "dog"), the open
# milestones for "dog" (one, #1), and the queue read itself (one issue on
# that milestone) -- so the loop reaches dispatch, which is the only thing
# this suite is checking. nightly-queue.test.sh covers the predicate itself.
cat > "$T/bin/gh" <<'STUB'
#!/usr/bin/env bash
case "$1" in
  repo)  [ "$2" = list ] && printf 'dog\n' ;;
  api)   case "$2" in *milestones*) printf '[1]\n' ;; esac ;;
  issue) [ "$2" = list ] && printf '[{"milestone":{"number":1}}]\n' ;;
esac
STUB
# The steps the loop calls, recording what they were handed.
cat > "$T/agent/merge-carry.sh" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
cat > "$T/agent/run-agent.sh" <<'STUB'
#!/usr/bin/env bash
printf '%s image=%s\n' "$1" "${AGENT_IMAGE:-UNSET}" >> "$T/dispatched"
STUB
chmod +x "$T/bin/sudo" "$T/bin/docker" "$T/bin/gh" "$T/agent"/*.sh

run() {  # run([AGENT_IMAGE]) -- one nightly pass against the stubs
  rm -f "$T/dispatched" "$T/srv/nightly."*.log
  # shellcheck disable=SC2097,SC2098  # T="$T" passes the harness dir the stubs read; same value, child env
  PATH="$T/bin:$PATH" T="$T" AGENT_DIR="$T/srv" \
    AGENT_IMAGE="${1:-}" bash "$T/agent/nightly.sh" 2>&1
}
dispatched() { cat "$T/dispatched" 2>/dev/null; }

section "A. a failed pull dispatches nothing"
echo 1 > "$T/pull_rc"
out="$(run)"; rc "exits nonzero" 1 "$?"
has "...names the image it could not pull" "$out" "PULL FAILED: ghcr.io/hf7y-estate/agent:latest"
eq  "...and no repo was dispatched" "$(dispatched)" ""
hasnt "...and it never reached the loop" "$out" "runnable, dispatching"

section "B. a pulled image is dispatched into, by digest in the log"
echo 0 > "$T/pull_rc"
printf 'ghcr.io/hf7y-estate/agent@sha256:abc123\n' > "$T/digest"
out="$(run)"; rc "exits 0" 0 "$?"
has "...the log names the image it ran" "$out" "=== image: ghcr.io/hf7y-estate/agent@sha256:abc123 ==="
eq  "...and the pass got that image, not agent:local" "$(dispatched)" "dog image=ghcr.io/hf7y-estate/agent:latest"

section "C. an unreadable digest is said, not swallowed -- the pull still stands"
rm -f "$T/digest"
out="$(run)"; rc "exits 0" 0 "$?"
has "...says the digest could not be read" "$out" "digest unreadable"
has "...and still dispatched" "$(dispatched)" "dog image="

section "D. AGENT_IMAGE from the environment is what gets pulled and run"
printf 'ghcr.io/hf7y-estate/agent@sha256:def456\n' > "$T/digest"
out="$(run ghcr.io/hf7y-estate/agent:41c0ffe)"; rc "exits 0" 0 "$?"
has "...pulled the override" "$out" "pulled ghcr.io/hf7y-estate/agent:41c0ffe"
eq  "...and handed it to the pass" "$(dispatched)" "dog image=ghcr.io/hf7y-estate/agent:41c0ffe"

summary
