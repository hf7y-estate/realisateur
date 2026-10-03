#!/usr/bin/env bash
# SUBJECT: agent/run-agent.sh, the forced-pass brake (#1382). A pass sent an
# issue number (not left to choose one from the queue) records one line per
# attempt under $AGENT_STATE/<repo>.<issue>.attempts.tsv; once the brake
# (MAX_ATTEMPTS, default 3) is reached on an issue still open, the issue gets
# `needs-human` and a comment saying so. Hermetic -- `sudo`, `docker` and
# `gh` are stubs on PATH, beside a COPY of the script; no real container runs.
set -uo pipefail
. "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib/harness.sh"
harness_tmp
REPO="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../.." && pwd)"

echo "run-agent-forced.test.sh"

mkdir -p "$T/bin" "$T/agent" "$T/srv"
cp "$REPO/agent/run-agent.sh" "$T/agent/run-agent.sh"
chmod +x "$T/agent/run-agent.sh"

cat > "$T/agent/merge-carry.sh" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB

# `sudo -n <cmd>`: the token read is answered with a fixture string; anything
# else (docker, the App minter it never finds) runs its PATH stub or fails,
# the same shape nightly-queue.test.sh and nightly-image.test.sh already use.
cat > "$T/bin/sudo" <<'STUB'
#!/usr/bin/env bash
shift                                   # drop -n
[ "$1" = cat ] && { printf 'not-a-real-token\n'; exit 0; }
exec "$@"
STUB

# `docker run`: no real container. It reads -v ROOT:/work, REPO=, BRIEF= off
# the real argv (so BRIEF's embedded newlines survive, same as the live
# script hands them to `-e`), fakes a clone by seeding a one-commit repo at
# ROOT/REPO, writes BRIEF to $T/last-brief.txt for inspection, prints one
# stream-json `result` line so the real turns/cost parsing in run-agent.sh has
# something to parse, and exits with $T/docker-rc (default 0).
cat > "$T/bin/docker" <<'STUB'
#!/usr/bin/env bash
[ "$1" = run ] || exit 0
shift
args=("$@")
n=${#args[@]}
mountroot="" repo=""
for ((i = 0; i < n; i++)); do
  if [ "${args[i]}" = "-v" ]; then
    case "${args[i+1]}" in *:/work) mountroot="${args[i+1]%:/work}" ;; esac
  fi
  case "${args[i]}" in
    REPO=*)  repo="${args[i]#REPO=}" ;;
    BRIEF=*) printf '%s' "${args[i]#BRIEF=}" > "$T/last-brief.txt" ;;
  esac
done
checkout="$mountroot/$repo"
mkdir -p "$checkout"
git -C "$checkout" init -q -b work >/dev/null 2>&1
git -C "$checkout" -c user.email=a@b -c user.name=a commit --allow-empty -q -m seed >/dev/null 2>&1
turns="$(cat "$T/fake-turns" 2>/dev/null || echo 5)"
cost="$(cat "$T/fake-cost" 2>/dev/null || echo 0.5)"
printf '{"type":"result","subtype":"success","num_turns":%s,"total_cost_usd":%s}\n' "$turns" "$cost"
exit "$(cat "$T/docker-rc" 2>/dev/null || echo 0)"
STUB

# `gh`: PRs are always empty (outcome stays no-change, which is not what this
# suite is grading); `issue view` answers from $T/issue-state.txt /
# issue-labels.json (default OPEN / []); `issue edit --add-label` and `issue
# comment` are recorded, and edit also flips issue-labels.json so a second
# brake check sees the label already applied -- the idempotency this suite
# checks for.
cat > "$T/bin/gh" <<'STUB'
#!/usr/bin/env bash
case "$1" in
  pr) [ "$2" = list ] && exit 0 ;;
  issue)
    case "$2" in
      view)
        state="$(cat "$T/issue-state.txt" 2>/dev/null || echo OPEN)"
        labels="$(cat "$T/issue-labels.json" 2>/dev/null || echo '[]')"
        printf '{"state":"%s","labels":%s}\n' "$state" "$labels"
        ;;
      edit)
        printf '%s\n' "$*" >> "$T/edit-calls.txt"
        printf '[{"name":"needs-human"}]\n' > "$T/issue-labels.json"
        ;;
      comment)
        printf '%s\n' "$*" >> "$T/comment-calls.txt"
        ;;
    esac
    ;;
esac
STUB
chmod +x "$T/bin/sudo" "$T/bin/docker" "$T/bin/gh" "$T/agent"/*.sh

run() {  # run(issue, [max_attempts]) -- one forced pass against the stubs
  MAX_ATTEMPTS="${2:-}" PATH="$T/bin:$PATH" T="$T" AGENT_DIR="$T/srv" \
    bash "$T/agent/run-agent.sh" dog 150 "$1" 2>&1
}
attempts() { cat "$T/srv/state/dog.42.attempts.tsv" 2>/dev/null; }

echo 7 > "$T/fake-turns"; echo 1.23 > "$T/fake-cost"

section "A. an issue argument reaches the brief, unchanged shape"
rm -f "$T/last-brief.txt"
out="$(run 42)"; rc "...exits 0" 0 "$?"
has "...the brief names the issue" "$(cat "$T/last-brief.txt")" "YOUR ISSUE IS #42"

section "B. one attempt, one recorded line -- repo, issue, turns, cost, outcome"
eq "...exactly one line after the first forced pass" "$(attempts | wc -l | tr -d ' ')" "1"
has "...it names the repo and issue" "$(attempts)" $'\tdog\t42\t'
has "...and the turns/cost this pass used" "$(attempts)" $'\t7\t1.23\t'
hasnt "...default brake (3) not reached -- no label, no comment" "$out" "needs-human"
eq "...no gh issue edit call yet" "$(cat "$T/edit-calls.txt" 2>/dev/null)" ""

section "C. a second forced pass on the same issue appends, does not replace"
out="$(run 42)"
eq "...two lines now" "$(attempts | wc -l | tr -d ' ')" "2"
hasnt "...still under the brake" "$out" "labeled needs-human"

section "D. the third attempt trips the default brake (3) on an OPEN issue"
out="$(run 42)"
eq "...three lines" "$(attempts | wc -l | tr -d ' ')" "3"
has "...says so" "$out" "3 attempts without closing -- labeled needs-human"
has "...gh issue edit added needs-human" "$(cat "$T/edit-calls.txt")" "--add-label needs-human"
has "...gh issue comment explains why" "$(cat "$T/comment-calls.txt")" "forced passes on this issue did not close it"

section "E. a fourth attempt does not re-label or re-comment -- already applied"
edits_before="$(wc -l < "$T/edit-calls.txt" | tr -d ' ')"
comments_before="$(wc -l < "$T/comment-calls.txt" | tr -d ' ')"
out="$(run 42)"
eq "...edit calls unchanged" "$(wc -l < "$T/edit-calls.txt" | tr -d ' ')" "$edits_before"
eq "...comment calls unchanged" "$(wc -l < "$T/comment-calls.txt" | tr -d ' ')" "$comments_before"
has "...says there was nothing to do" "$out" "already=true -- nothing to do"

section "F. MAX_ATTEMPTS from the caller -- one attempt trips a brake of 1"
rm -f "$T/edit-calls.txt" "$T/comment-calls.txt" "$T/issue-labels.json" "$T/srv/state/dog.99.attempts.tsv"
printf 'OPEN\n' > "$T/issue-state.txt"
out="$(run 99 1)"
has "...trips on the first attempt when the caller says 1" "$out" "1 attempts without closing -- labeled needs-human"

section "G. a CLOSED issue is left alone even past the brake"
printf 'CLOSED\n' > "$T/issue-state.txt"
rm -f "$T/edit-calls.txt" "$T/issue-labels.json"
out="$(run 99 1)"
has "...says the state, not a guess" "$out" "brake reached but state=CLOSED"
eq "...no edit call -- a closed issue needs no human" "$(cat "$T/edit-calls.txt" 2>/dev/null)" ""

section "H. an unforced pass (no issue) records nothing"
out="$(MAX_ATTEMPTS= PATH="$T/bin:$PATH" T="$T" AGENT_DIR="$T/srv" bash "$T/agent/run-agent.sh" dog 150 2>&1)"
rc "...exits 0" 0 "$?"
eq "...no attempts file for an unforced pass" "$([ -e "$T/srv/state/dog..attempts.tsv" ] && echo yes || echo no)" "no"
hasnt "...never mentions a brake" "$out" "attempt"

summary
