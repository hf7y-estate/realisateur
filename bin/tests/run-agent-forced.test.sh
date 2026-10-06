#!/usr/bin/env bash
# run-agent-forced.test.sh -- agent/run-agent.sh's forced-pass brakes (#1382):
# the brief names the one issue sent, each forced pass appends a ledger line,
# and an issue that outlives its attempt budget gets `needs-human`. Hermetic:
# `docker`, `sudo` and `gh` are stubs on PATH; `docker run` never runs the real
# image, it fakes the one thing the harness reads back out of it (the
# stream-json result line) and leaves a real git checkout behind so the
# branch/log reporting below it has something to look at.
#
# NOT HERMETIC ON TWO PATHS run-agent.sh hardcodes rather than taking from
# AGENT_STATE/AGENT_DIR: the per-pass log (/srv/agent/<repo>.<stamp>.log) and
# the work root (/srv/agent/work/<repo>). Both are cleaned up below, scoped to
# a repo name this suite alone uses, on the same assumption run-agent.sh
# itself runs under -- a throwaway container, not a shared host.
set -uo pipefail
. "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib/harness.sh"
harness_tmp; export T
REPO_ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../.." && pwd)"
RUN_AGENT="$REPO_ROOT/agent/run-agent.sh"

TESTREPO="zz-run-agent-test-$$"
WORK="/srv/agent/work/$TESTREPO"
cleanup_real() { rm -rf "$WORK"; rm -f /srv/agent/"$TESTREPO".*.log; }
trap 'cleanup_real' EXIT
cleanup_real   # in case a prior interrupted run left residue under this pid (unlikely, but cheap)

mkdir -p "$T/agent" "$T/bin" "$T/state"
cp "$RUN_AGENT" "$T/agent/run-agent.sh"
cp "$REPO_ROOT/agent/salvage.sh" "$T/agent/salvage.sh"
cat > "$T/agent/merge-carry.sh" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
# The fallback minter path run-agent.sh resolves to when
# /usr/local/libexec/selfdev/selfdev-gh-app.sh does not exist (true on this
# host): dirname(dirname($T/agent/run-agent.sh))/bin/selfdev-gh-app.sh.
cat > "$T/bin/selfdev-gh-app.sh" <<'STUB'
#!/usr/bin/env bash
[ "${1:-}" = --token ] && { echo "test-minted-token"; exit 0; }
exit 1
STUB
# `-n` dropped, then exec straight through -- the real `env`, `cat`, `rm`,
# and this suite's own `docker` stub all behave like the host's.
cat > "$T/bin/sudo" <<'STUB'
#!/usr/bin/env bash
shift
exec "$@"
STUB
# Answers `docker run` only -- nothing else in run-agent.sh calls docker.
# Parses just enough of the fixed flag shape run-agent.sh emits to find the
# /work mount and the REPO env var, then fakes a container pass: a real git
# checkout left at the mount (so the branch/log reporting below has
# something to read) and one stream-json `result` line on stdout, with
# turns/cost from this invocation's own DOCKER_TURNS/DOCKER_COST.
cat > "$T/bin/docker" <<'STUB'
#!/usr/bin/env bash
[ "${1:-}" = run ] || exit 0
shift
root=""
while [ $# -gt 0 ]; do
  case "$1" in
    -v) case "$2" in *:/work) root="${2%:/work}" ;; esac; shift 2 ;;
    -e) kv="$2"; k="${kv%%=*}"; v="${kv#*=}"
        [ "$k" = REPO ] && repo="$v"
        [ "$k" = BRIEF ] && printf '%s' "$v" > "$T/last-brief"
        shift 2 ;;
    --rm) shift ;;
    --cpus|--memory) shift 2 ;;
    bash) break ;;
    *) shift ;;
  esac
done
checkout="$root/$repo"
rm -rf "$checkout"; mkdir -p "$checkout"
git -C "$checkout" init -q -b main
git -C "$checkout" config user.email t@t; git -C "$checkout" config user.name t
echo seed > "$checkout/seed.txt"
git -C "$checkout" add -A; git -C "$checkout" commit -q -m seed
printf '{"type":"result","subtype":"success","num_turns":%s,"total_cost_usd":%s}\n' \
  "${DOCKER_TURNS:-5}" "${DOCKER_COST:-0.01}"
exit "${DOCKER_RC:-0}"
STUB
# `issue view --json state` answers from $T/issue-state (default OPEN);
# `--json labels` answers from $T/has-label (default false); edit/comment are
# recorded, not acted on. pr list prints nothing -- no PRs this pass opened.
cat > "$T/bin/gh" <<'STUB'
#!/usr/bin/env bash
case "$1 $2" in
  "pr list") exit 0 ;;
  "issue view")
    json=""
    args=("$@")
    for ((i=0;i<${#args[@]};i++)); do [ "${args[i]}" = --json ] && json="${args[i+1]}"; done
    case "$json" in
      state)  cat "$T/issue-state" 2>/dev/null || echo OPEN ;;
      labels) cat "$T/has-label" 2>/dev/null || echo false ;;
    esac
    exit 0 ;;
  "issue edit"|"issue comment") printf '%s\n' "$*" >> "$T/gh.calls" ;;
esac
exit 0
STUB
chmod +x "$T/bin"/*.sh "$T/bin/sudo" "$T/bin/docker" "$T/bin/gh" "$T/agent/merge-carry.sh"

export PATH="$T/bin:$PATH" AGENT_STATE="$T/state"
run() {  # run(issue, [max_attempts]) -- one forced pass against the stubs
  rm -f "$T/last-brief" "$T/gh.calls"
  bash "$T/agent/run-agent.sh" "$TESTREPO" 10 "$@" 2>&1
}
ledger() { cat "$T/state/forced.log" 2>/dev/null; }

section "A. a forced pass's brief names the one issue sent"
echo OPEN > "$T/issue-state"
out="$(run 4001)"; rc "exits 0" 0 "$?"
has "...the brief says SENT NOT CHOSEN" "$(cat "$T/last-brief")" "YOUR ISSUE IS #4001"

section "B. an unforced pass's brief names no issue"
rm -f "$T/state/forced.log"
out="$(run)"; rc "exits 0" 0 "$?"
hasnt "...no issue line" "$(cat "$T/last-brief")" "YOUR ISSUE IS"
eq "...and nothing was charged to the ledger" "$(ledger)" ""

section "C. a forced pass appends one ledger line: repo, issue, turns, cost, outcome"
rm -f "$T/state/forced.log"
DOCKER_TURNS=7 DOCKER_COST=0.4321 run 4002 >/dev/null
line="$(ledger)"
has "...repo" "$line" "	$TESTREPO	"
has "...issue" "$line" "	4002	"
has "...turns" "$line" "	7	"
has "...cost" "$line" "	0.4321	"
has "...outcome (issue still OPEN)" "$line" "	open"
eq "...exactly one line" "$(ledger | wc -l | tr -d ' ')" "1"

section "D. a closed issue is recorded closed, and the brake is never evaluated"
rm -f "$T/state/forced.log" "$T/gh.calls"
echo CLOSED > "$T/issue-state"
DOCKER_TURNS=3 DOCKER_COST=0.1 run 4003 >/dev/null
has "...outcome closed" "$(ledger)" "	closed"
eq "...no needs-human on a closed issue" "$(cat "$T/gh.calls" 2>/dev/null)" ""

section "E. three forced passes on one open issue trip the default brake (N=3)"
rm -f "$T/state/forced.log" "$T/gh.calls"
echo OPEN > "$T/issue-state"
echo false > "$T/has-label"
out1="$(run 4004)"; out2="$(run 4004)"
eq "...after 2 passes, no needs-human yet" "$(cat "$T/gh.calls" 2>/dev/null)" ""
out3="$(run 4004)"
eq "...3 lines charged to #4004" "$(awk -F'\t' -v n=4004 '$3==n' "$T/state/forced.log" | wc -l | tr -d ' ')" "3"
has "...the 3rd labels needs-human" "$(cat "$T/gh.calls")" "issue edit 4004"
has "...and comments why" "$(cat "$T/gh.calls")" "issue comment 4004"
has "...the pass itself says so" "$out3" "needs-human applied after 3 forced passes"

section "F. an issue already labelled needs-human is not re-commented"
rm -f "$T/state/forced.log" "$T/gh.calls"
echo true > "$T/has-label"
run 4004 >/dev/null; run 4004 >/dev/null; out="$(run 4004)"
eq "...no edit/comment call was made" "$(cat "$T/gh.calls" 2>/dev/null)" ""
has "...the pass says it's already labelled" "$out" "already needs-human"

section "G. max_attempts is the caller's: N=1 trips on the first pass"
rm -f "$T/state/forced.log" "$T/gh.calls"
echo false > "$T/has-label"
out="$(run 4005 1)"
has "...labels after just 1 pass" "$(cat "$T/gh.calls")" "issue edit 4005"
has "...says 1, not the default 3" "$out" "needs-human applied after 1 forced passes"

section "H. a non-numeric max_attempts is refused, not silently defaulted"
out="$(bash "$T/agent/run-agent.sh" "$TESTREPO" 10 4006 abc 2>&1)"; rc "exits 2" 2 "$?"
has "...names the bad value" "$out" "max_attempts must be a number, got 'abc'"

summary
