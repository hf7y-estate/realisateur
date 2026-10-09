#!/usr/bin/env bash
# SUBJECT: agent/nightly.sh, the repo-set, order and queue-predicate half
# (#1383, #1476). The org (`gh repo list hf7y-estate --no-archived`) is the
# set and the pass logs are the order: oldest pass first, never-passed before
# all. The queue count that gates a dispatch is open issues in an open
# milestone, not just open issues. Hermetic -- `sudo`, `docker` and `gh` are
# stubs on PATH, beside a COPY of the script.
set -uo pipefail
. "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib/harness.sh"
harness_tmp; export T
REPO="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../.." && pwd)"

echo "nightly-queue.test.sh"

mkdir -p "$T/bin" "$T/agent" "$T/srv"
cp "$REPO/agent/nightly.sh" "$T/agent/nightly.sh"
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

# The org is alpha, beta, gamma, delta. gh repo list prints this. gh api .../milestones answers each
# repo's OPEN milestones; a repo with a "fail-ms-<repo>" marker fails
# instead, the way an unreadable repo does for real. gh issue list answers
# each repo's open, non-needs-host/needs-human issues with their milestone.
#
# alpha: one issue on its one open milestone -- dispatches.
# beta:  one issue, but on a milestone that ISN'T in beta's open set (a
#        closed milestone in practice) -- this is the predicate under test:
#        an issue is not "queued" just because it exists and has *a*
#        milestone, only an OPEN one. Queue count must be 0, not 1.
# gamma: one issue on its open milestone -- dispatches.
# delta: its milestones call fails -- unreadable, not guessed at as empty.
printf 'alpha\nbeta\ngamma\ndelta\n' > "$T/org.txt"
touch "$T/fail-ms-delta"
cat > "$T/bin/gh" <<'STUB'
#!/usr/bin/env bash
args="$*"
owner=""; repo=""
# Two owners are matched -- #1602 lets a repo line or a --send target name a
# non-hf7y-estate owner, so the stub can no longer assume one.
if [[ "$args" =~ repos/([A-Za-z0-9._-]+)/([A-Za-z0-9._-]+)/milestones ]]; then
  owner="${BASH_REMATCH[1]}"; repo="${BASH_REMATCH[2]}"
elif [[ "$args" =~ --repo[[:space:]]([A-Za-z0-9._-]+)/([A-Za-z0-9._-]+) ]]; then
  owner="${BASH_REMATCH[1]}"; repo="${BASH_REMATCH[2]}"
fi
case "$1" in
  repo)
    [ "$2" = list ] && { [ -f "$T/fail-repo-list" ] && exit 1; cat "$T/org.txt"; }
    ;;
  api)
    case "$args" in
      *milestones*)
        [ -f "$T/fail-ms-$repo" ] && exit 1
        case "$owner/$repo" in
          hf7y-estate/alpha) printf '[1]\n' ;;
          hf7y-estate/beta)  printf '[1]\n' ;;
          hf7y-estate/gamma) printf '[5]\n' ;;
          hf7y-estate/delta) printf '[9]\n' ;;
          media-arts-collective/gamma) printf '[3]\n' ;;
        esac
        ;;
    esac
    ;;
  issue)
    [ "$2" = list ] || exit 0
    case "$owner/$repo" in
      hf7y-estate/alpha) [ "$(cat "$T/left-alpha" 2>/dev/null)" = 0 ] && printf '[]\n' || printf '[{"milestone":{"number":1}}]\n' ;;
      hf7y-estate/beta)  printf '[{"milestone":{"number":99}}]\n' ;;   # 99 is not open
      hf7y-estate/gamma) printf '[{"milestone":{"number":5}}]\n' ;;
      hf7y-estate/delta) printf '[{"milestone":{"number":9}}]\n' ;;
      media-arts-collective/gamma) printf '[{"milestone":{"number":3}}]\n' ;;
    esac
    ;;
  pr) : ;;  # the trailing PR recap; not under test here
esac
STUB
cat > "$T/agent/merge-carry.sh" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
# Default: silent and clean, like a real --apply with nothing to change.
# fail-etiquette-<repo> makes it crash instead, for section Q below.
cat > "$T/bin/etiquette.sh" <<'STUB'
#!/usr/bin/env bash
repo="${1#*/}"
if [ -f "$T/fail-etiquette-$repo" ]; then
  echo "etiquette.sh: unreadable label config" >&2
  exit 1
fi
exit 0
STUB
cat > "$T/agent/run-agent.sh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$1${3:+#$3}" >> "$T/dispatched"
[ -f "$T/refuse" ] && exit 3   # run-agent.sh's own code for "no bot token"
# each pass closes one queued issue, the way a real one would
[ -f "$T/left-$1" ] && printf '%s\n' "$(( $(cat "$T/left-$1") - 1 ))" > "$T/left-$1"
exit 0
STUB
chmod +x "$T/bin/sudo" "$T/bin/docker" "$T/bin/gh" "$T/bin/etiquette.sh" "$T/agent"/*.sh

run() {
  rm -f "$T/dispatched" "$T/srv/nightly."*.log
  PATH="$T/bin:$PATH" AGENT_DIR="$T/srv" \
    AGENT_IMAGE="ghcr.io/hf7y-estate/agent:latest" bash "$T/agent/nightly.sh" 2>&1
}
dispatched() { cat "$T/dispatched" 2>/dev/null; }

section "A. the org is the candidate set, in name order when nothing has ever run"
rm -f "$T/fail-repo-list"
out="$(run)"; rc "exits 0" 0 "$?"
has "...says the order it chose" "$out" "oldest pass first: alpha beta delta gamma"
eq "...alpha and gamma ran, in that order (beta and delta did not)" "$(dispatched | tr '\n' ' ')" "alpha gamma "

section "A2. the repo passed longest ago goes first, so no tail starves (#1476)"
: > "$T/srv/alpha.20261009T000000Z.log"; : > "$T/srv/gamma.20261005T000000Z.log"
out="$(NIGHT_PASSES=1 run)"
eq "...the one pass goes to gamma, not back to the top of the alphabet" "$(dispatched | tr '\n' ' ')" "gamma "
: > "$T/srv/gamma.20261009T000001Z.log"
out="$(NIGHT_PASSES=1 run)"
eq "...and once gamma has a newer log, alpha's turn comes round" "$(dispatched | tr '\n' ' ')" "alpha "
rm -f "$T/srv/alpha."*.log "$T/srv/gamma."*.log

section "B. the queue is issues on an OPEN milestone, not just issues"
has "...beta's issue sits on a milestone that isn't open, so its queue reads empty" \
  "$out" "--- beta: queue empty, skipping"
hasnt "...beta was never dispatched into" "$(dispatched)" "beta"

section "C. an unreadable queue is said, not guessed at as empty"
has "...delta's milestones call failed, and that is named, not swallowed" "$out" \
  "--- delta: COULD NOT READ THE QUEUE -- skipping, not guessing"
hasnt "...delta was never dispatched into" "$(dispatched)" "delta"

section "E. an unreadable org dispatches nothing, and fails so cron says so"
touch "$T/fail-repo-list"
out="$(run)"; rc "exits 1" 1 "$?"
has "...says the org couldn't be read" "$out" "COULD NOT LIST hf7y-estate -- dispatching nothing"
eq "...and ran nothing" "$(dispatched | wc -l | tr -d ' ')" "0"
out="$(ONLY="gamma" run)"; rc "...a sent run never asks the org, so it still runs" 0 "$?"
eq "...gamma dispatched" "$(dispatched | tr '\n' ' ')" "gamma "
rm -f "$T/fail-repo-list"

section "F. PASSES drains a repo's queue, and stops when it is empty"
printf '2\n' > "$T/left-alpha"                      # alpha's queue holds two issues
out="$(PASSES=5 NIGHT_PASSES=9 run)"; rc "exits 0" 0 "$?"
eq "...alpha ran two passes: one per queued issue" \
  "$(dispatched | grep -c '^alpha$')" "2"
has "...and says which pass each was" "$out" "pass 2/5"
eq "...and did not run to 5 once nothing was left" "$(printf '%s\n' "$out" | grep -c '^--- alpha: .* pass 3/5')" "0"
eq "...gamma kept its queue and ran all five" "$(dispatched | grep -c '^gamma$')" "5"
rm -f "$T/left-alpha"

section "G. the night has one budget across every repo (#1379)"
out="$(NIGHT_PASSES=1 run)"
eq "...one pass spent, on the first repo with a queue" "$(dispatched | tr '\n' ' ')" "alpha "
has "...and the rest are said to wait" "$out" "night budget of 1 pass(es) spent -- gamma and everything after it waits"
out="$(run)"
eq "...unset, the budget (13) covers both runnable repos" \
  "$(dispatched | wc -l | tr -d ' ')" "2"

section "H. --send starts ONE supervised unit and nothing else (#1379)"
cat > "$T/bin/systemd-run" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" > "$T/systemd-run.args"
STUB
chmod +x "$T/bin/systemd-run"
out="$(PATH="$T/bin:$PATH" AGENT_DIR="$T/srv" bash "$T/agent/nightly.sh" --send 3 alpha gamma 2>&1)"; rc "exits 0" 0 "$?"
has "...says what it sent" "$out" "sending: alpha gamma -- up to 3 pass(es) each"
has "...as a named unit" "$(cat "$T/systemd-run.args")" "--unit=agent-sent-"
has "...carrying the pass count" "$(cat "$T/systemd-run.args")" "--setenv=PASSES=3"
has "...and the repos" "$(cat "$T/systemd-run.args")" "--setenv=ONLY=alpha gamma"
hasnt "...and no turn limit unless one was given" "$(cat "$T/systemd-run.args")" "TURNS"
TURNS=77 PATH="$T/bin:$PATH" AGENT_DIR="$T/srv" bash "$T/agent/nightly.sh" --send 1 alpha >/dev/null 2>&1
has "...TURNS rides along when the sender sets it" "$(cat "$T/systemd-run.args")" "--setenv=TURNS=77"
eq "...and dispatched nothing itself" "$(dispatched | wc -l | tr -d ' ')" "2"
PATH="$T/bin:$PATH" bash "$T/agent/nightly.sh" --send x alpha >/dev/null 2>&1; rc "...a pass count that is not a number exits 2" 2 "$?"
PATH="$T/bin:$PATH" bash "$T/agent/nightly.sh" --send 3 >/dev/null 2>&1; rc "...no repo named exits 2" 2 "$?"

section "I. ONLY narrows a run to the repos it was sent with"
out="$(ONLY="gamma" PASSES=1 run)"
eq "...only gamma ran" "$(dispatched | tr '\n' ' ')" "gamma "
has "...and the log says it was a sent run" "$out" "sent run: only gamma"

section "J. repo#n sends one pass at that issue, in the order given"
out="$(ONLY="alpha#7 beta#3 alpha#9" PASSES=4 run)"
eq "...each link ran once, in order, queue or no queue" "$(dispatched | tr '\n' ' ')" "alpha#7 beta#3 alpha#9 "
has "...and the log names the issue" "$out" "pass 1/4 issue #7"

section "K. a sent run starts while a night holds the lock; a second night does not"
( exec 9>"$T/srv/.nightly.lock"; flock 9; sleep 5 ) &
holder=$!; sleep 0.5
out="$(ONLY="gamma" run)"
eq "...the sent run dispatched anyway" "$(dispatched | tr '\n' ' ')" "gamma "
out="$(run)"
has "...and an unsent run still yields to the night" "$out" "another nightly holds the lock"
kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null

section "L. a pass that refuses for want of a bot token stops the night and tells a person"
mkdir -p "$T/bin/lib"
printf 'zaxon_send() { printf "%%s\\n" "$1" >> "$T/sent"; }\n' > "$T/bin/lib/zaxon.sh"
: > "$T/refuse"; rm -f "$T/sent"
out="$(run)"; rc "exits 0" 0 "$?"
has "...says so in the night's log" "$out" "NO BOT TOKEN: alpha refused, dispatching nothing more"
eq "...tried one repo and no more" "$(dispatched | tr '\n' ' ')" "alpha "
eq "...and sent ONE message" "$(wc -l < "$T/sent" | tr -d ' ')" "1"
rm -f "$T/refuse"

section "M. a repo locked by another chain is deferred, not waited on (#1476)"
( exec 9>"$T/srv/.pass.alpha.lock"; flock 9; sleep 30 ) &
holder=$!; sleep 0.5
rm -f "$T/dispatched" "$T/srv/nightly."*.log
out="$(timeout 10 env PATH="$T/bin:$PATH" AGENT_DIR="$T/srv" \
  AGENT_IMAGE="ghcr.io/hf7y-estate/agent:latest" bash "$T/agent/nightly.sh" 2>&1)"
rc "...does not hang waiting on the lock -- exits well inside the pass's own 30s hold" 0 "$?"
has "...says alpha is locked and is not waiting on it" "$out" "alpha: locked by another chain, not waiting -- deferring"
has "...gamma still ran while alpha's lock was held" "$(dispatched)" "gamma"
has "...alpha is said to still be locked on its one retry" "$out" "alpha: still locked on retry -- skipping for the rest of the night"
hasnt "...and alpha itself never ran" "$(dispatched)" "alpha"
kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null

section "O. a same-named repo under a different owner does not share hf7y-estate's lock or log (#1602)"
( exec 9>"$T/srv/.pass.gamma.lock"; flock 9; sleep 5 ) &
holder=$!; sleep 0.5
out="$(ONLY="media-arts-collective/gamma gamma" run)"
eq "...media-arts-collective/gamma ran anyway, on a lock of its own" \
  "$(dispatched | tr '\n' ' ')" "media-arts-collective/gamma "
has "...hf7y-estate's own gamma was the one deferred by the shared lock" "$out" \
  "gamma: locked by another chain, not waiting -- deferring"
kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null

section "P. a sent target may name its own owner together with an issue number (#1602)"
out="$(ONLY="media-arts-collective/gamma#42" PASSES=1 run)"
eq "...dispatched with its owner, repo and issue intact" \
  "$(dispatched | tr '\n' ' ')" "media-arts-collective/gamma#42 "
has "...and the log names the issue" "$out" "pass 1/1 issue #42"
has "...and says it was a sent run of just that target" "$out" \
  "sent run: only media-arts-collective/gamma#42"

section "Q. etiquette.sh crashing between merge-carry and dispatch says so, not nothing (#1649)"
touch "$T/fail-etiquette-alpha"
out="$(ONLY="alpha" PASSES=1 run)"; rc "...exits 0 -- a labelling failure does not stop the night" 0 "$?"
has "...names the exit code and etiquette.sh's own stderr" "$out" \
  "--- alpha: etiquette.sh exited 1 -- etiquette.sh: unreadable label config"
has "...and the repo is still dispatched -- a crash here is reported, not fatal" "$out" \
  "--- alpha: 1 runnable, dispatching"
eq "...alpha ran anyway" "$(dispatched | tr '\n' ' ')" "alpha "
rm -f "$T/fail-etiquette-alpha"

summary
