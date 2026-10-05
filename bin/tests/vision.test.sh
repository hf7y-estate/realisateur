#!/usr/bin/env bash
# vision.test.sh -- `record` writes his words verbatim and only under --apply;
# a queue that could not look is BLIND, never empty.
#
# HERMETIC. Stubs `gh` on PATH; touches nothing outside $T.
#
set -uo pipefail
# shellcheck source=bin/tests/lib/harness.sh
. "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib/harness.sh"

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$ROOT/bin/vision.sh"
[ -x "$SCRIPT" ] || { echo "FAIL: $SCRIPT not executable"; exit 1; }

echo "vision.test.sh"
harness_tmp

mkdir -p "$T/bin"
cat > "$T/bin/gh" <<'EOF2'
#!/usr/bin/env bash
echo "$*" >> "$T_CALLS"
[ -n "${STUB_FAIL:-}" ] && exit 1
case "$*" in
  *'-X PATCH'*) echo 'written: https://example/milestone/1' ;;
  *'issues?milestone'*) echo '  #7  2026-08-01  3 comment(s)  an old one' ;;
  *milestones/1*) echo '{"title":"v1-stabilization","open_issues":23,"closed_issues":60,"description":"Keep the running fleet up."}' ;;
esac
EOF2
chmod +x "$T/bin/gh"
export T_CALLS="$T/calls"
run() { : > "$T_CALLS"; PATH="$T/bin:$PATH" VISION_TODAY=2026-10-05 bash "$SCRIPT" "$@"; }

section "A. record prints, and writes only under --apply"

out="$(run record senechal 1 --quote 'dexter comes back by itself' --closes-when '`ssh dexter true` after a power cut' 2>&1)"; n=$?
rc 'A1 dry run exits 0' 0 "$n"
has 'A2 his words, verbatim' "$out" '> dexter comes back by itself'
has 'A3 attributed and dated' "$out" 'Zach, 2026-10-05'
has 'A4 the close is a line the queue can find' "$out" 'CLOSES WHEN: `ssh dexter true`'
has 'A5 the old title is kept' "$out" 'Was: "v1-stabilization"'
has 'A6 the old description is kept' "$out" 'Keep the running fleet up.'
hasnt 'A7 nothing was written' "$(cat "$T_CALLS")" 'PATCH'

out="$(run record senechal 1 --quote 'q' --title 'dexter comes back by itself' --apply 2>&1)"; n=$?
rc 'A8 apply exits 0' 0 "$n"
has 'A9 apply PATCHes the milestone' "$(cat "$T_CALLS")" '-X PATCH repos/hf7y-estate/senechal/milestones/1'
has 'A10 with the new title' "$(cat "$T_CALLS")" 'title=dexter comes back by itself'

out="$(run record senechal 1 2>&1)"; n=$?
rc 'A11 no quote is a usage error' 2 "$n"

section "B. card asks the one question"

out="$(run card senechal 1 2>&1)"; n=$?
rc 'B1 exits 0' 0 "$n"
has 'B2 counts' "$out" 'open 23  closed 60'
has 'B3 the question' "$out" 'What is true when this is done?'

section "C. could not look is BLIND"

out="$(STUB_FAIL=1 run queue 2>&1)"; n=$?
rc 'C1 queue exits 6' 6 "$n"
has 'C2 and says so' "$out" 'BLIND'
out="$(STUB_FAIL=1 run card senechal 1 2>&1)"; n=$?
rc 'C3 card exits 6' 6 "$n"

summary
