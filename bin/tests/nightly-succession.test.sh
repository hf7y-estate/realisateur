#!/usr/bin/env bash
# SUBJECT: agent/nightly.sh's succession functions (#1608, #1627) --
# succeed_milestones, milestone_runnable_count, lowest_runnable_closed_milestone.
# An open milestone with zero RUNNABLE open issues (queue_count's own
# needs-host/needs-human filter, not GitHub's raw open_issues) is drained and
# closes; what opens next is a `NEXT: <number>` line in the one that just
# closed, else the lowest-numbered CLOSED milestone that still holds a
# runnable issue -- skipping one that does not, so a blocked milestone is
# never mistaken for a successor. Hermetic -- `sudo`, `docker` and `gh` are
# stubs on PATH, beside a COPY of the script; each scratch repo's milestones
# live in a JSON file the `gh` stub reads and PATCHes in place, the way the
# real API would.
set -uo pipefail
. "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib/harness.sh"
harness_tmp; export T
REPO="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../.." && pwd)"

echo "nightly-succession.test.sh"

mkdir -p "$T/bin" "$T/agent" "$T/srv"
cp "$REPO/agent/nightly.sh" "$T/agent/nightly.sh"

cat > "$T/bin/sudo" <<'STUB'
#!/usr/bin/env bash
shift
[ "$1" = cat ] && { printf 'not-a-real-token\n'; exit 0; }
exec "$@"
STUB
cat > "$T/bin/docker" <<'STUB'
#!/usr/bin/env bash
case "$1" in
  pull)  printf 'Status: pulled %s\n' "$2"; exit 0 ;;
  image) printf 'ghcr.io/hf7y-estate/agent@sha256:fixture\n' ;;
esac
STUB

# `gh` stub: each repo's milestones are $T/ms-<repo>.json ([{number,title,
# description,state}]); a GET filters by state and applies any --jq query
# with a real jq, a `-X PATCH .../milestones/<n>` updates that repo's entry
# in place (state always, description only when one was given, so opening a
# milestone with no -f description does not blank it). `gh issue list
# --milestone <n>` answers milestone_runnable_count straight from
# $T/run-<repo>-<n> (the runnable count a test seeds); without --milestone
# it is queue_count's own call, answered from $T/issues-<repo>.json.
cat > "$T/bin/gh" <<'STUB'
#!/usr/bin/env bash
args="$*"
owner=""; repo=""
if [[ "$args" =~ repos/([A-Za-z0-9._-]+)/([A-Za-z0-9._-]+)/milestones ]]; then
  owner="${BASH_REMATCH[1]}"; repo="${BASH_REMATCH[2]}"
elif [[ "$args" =~ --repo[[:space:]]([A-Za-z0-9._-]+)/([A-Za-z0-9._-]+) ]]; then
  owner="${BASH_REMATCH[1]}"; repo="${BASH_REMATCH[2]}"
fi
store="$T/ms-$repo.json"

case "$1" in
  repo)
    [ "$2" = list ] && cat "$T/org.txt" 2>/dev/null
    ;;
  api)
    if [ "$2" = "-X" ]; then
      path="$4"
      n="${path##*/milestones/}"
      shift 4
      newstate=""; newdesc=""; hasdesc=0
      while [ $# -gt 0 ]; do
        case "$1" in
          -f) shift
              case "$1" in
                state=*) newstate="${1#state=}" ;;
                description=*) newdesc="${1#description=}"; hasdesc=1 ;;
              esac
              ;;
        esac
        shift
      done
      tmp="$(mktemp)"
      jq --argjson n "$n" --arg st "$newstate" --arg d "$newdesc" --argjson hasdesc "$([ "$hasdesc" -eq 1 ] && echo true || echo false)" \
        '[.[] | if .number==$n then (.state=$st) + (if $hasdesc then {description:$d} else {} end) else . end]' \
        "$store" > "$tmp" && mv "$tmp" "$store"
      echo '{}'
    else
      jqexpr=""
      prev=""
      for a in "$@"; do
        [ "$prev" = "--jq" ] && jqexpr="$a"
        prev="$a"
      done
      case "$args" in
        *'state=open'*)   sel='[.[] | select(.state=="open")]' ;;
        *'state=closed'*) sel='[.[] | select(.state=="closed")]' ;;
        *)                sel='.' ;;
      esac
      if [ -n "$jqexpr" ]; then jq -r "$sel | $jqexpr" "$store" 2>/dev/null
      else jq "$sel" "$store" 2>/dev/null
      fi
    fi
    ;;
  issue)
    [ "$2" = list ] || exit 0
    if [[ "$args" =~ --milestone[[:space:]]+([0-9]+) ]]; then
      cat "$T/run-$repo-${BASH_REMATCH[1]}" 2>/dev/null || echo 0
    else
      cat "$T/issues-$repo.json" 2>/dev/null || echo '[]'
    fi
    ;;
  pr) : ;;
esac
STUB
cat > "$T/agent/merge-carry.sh" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
cat > "$T/agent/run-agent.sh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$1${3:+#$3}" >> "$T/dispatched"
exit 0
STUB
chmod +x "$T/bin/sudo" "$T/bin/docker" "$T/bin/gh" "$T/agent"/*.sh

run_only() {
  rm -f "$T/dispatched" "$T/srv/nightly."*.log
  PATH="$T/bin:$PATH" AGENT_DIR="$T/srv" AGENT_IMAGE="ghcr.io/hf7y-estate/agent:latest" \
    ONLY="$1" bash "$T/agent/nightly.sh" 2>&1
}
dispatched() { cat "$T/dispatched" 2>/dev/null; }
ms_state() { jq -r --argjson n "$2" '.[] | select(.number==$n) | .state' "$T/ms-$1.json"; }
ms_desc()  { jq -r --argjson n "$2" '.[] | select(.number==$n) | .description' "$T/ms-$1.json"; }

section "A. a drained open milestone closes and the lowest runnable closed one opens"
cat > "$T/ms-zeta.json" <<'JSON'
[{"number":1,"title":"m1","description":"","state":"open"},
 {"number":2,"title":"m2","description":"","state":"closed"}]
JSON
printf '0\n' > "$T/run-zeta-1"; printf '1\n' > "$T/run-zeta-2"
printf '[{"milestone":{"number":2}}]\n' > "$T/issues-zeta.json"
out="$(run_only zeta)"
has "...says milestone #1 drained and closed" "$out" "zeta: milestone #1 (m1) drained of runnable issues, closed"
has "...says milestone #2 opened, succeeding #1" "$out" "zeta: milestone #2 opened, succeeding #1"
eq "...milestone #1 is now closed" "$(ms_state zeta 1)" "closed"
eq "...milestone #2 is now open" "$(ms_state zeta 2)" "open"
has "...milestone #1's description carries the succession note" "$(ms_desc zeta 1)" "SUCCESSION: closed"
has "...and names its successor" "$(ms_desc zeta 1)" "succeeded by #2"
eq "...the now-open milestone's issue dispatches in the SAME pass" "$(dispatched | tr '\n' ' ')" "zeta "

section "B. an explicit NEXT: line picks the successor over the lowest number"
cat > "$T/ms-eta.json" <<'JSON'
[{"number":1,"title":"m1","description":"NEXT: 3","state":"open"},
 {"number":2,"title":"m2","description":"","state":"closed"},
 {"number":3,"title":"m3","description":"","state":"closed"}]
JSON
printf '0\n' > "$T/run-eta-1"; printf '1\n' > "$T/run-eta-2"; printf '1\n' > "$T/run-eta-3"
printf '[]\n' > "$T/issues-eta.json"
out="$(run_only eta)"
has "...opens #3, the NEXT: target, not #2 the lower number" "$out" "eta: milestone #3 opened, succeeding #1"
hasnt "...never opens #2" "$out" "milestone #2 opened"
eq "...milestone #2 stays closed" "$(ms_state eta 2)" "closed"
eq "...milestone #3 is now open" "$(ms_state eta 3)" "open"

section "C. the lowest-number fallback skips a closed milestone with nothing runnable"
cat > "$T/ms-theta.json" <<'JSON'
[{"number":1,"title":"m1","description":"","state":"open"},
 {"number":2,"title":"m2","description":"","state":"closed"},
 {"number":5,"title":"m5","description":"","state":"closed"}]
JSON
printf '0\n' > "$T/run-theta-1"; printf '0\n' > "$T/run-theta-2"; printf '1\n' > "$T/run-theta-5"
printf '[]\n' > "$T/issues-theta.json"
out="$(run_only theta)"
has "...skips #2 (nothing runnable) and opens #5 instead" "$out" "theta: milestone #5 opened, succeeding #1"
hasnt "...never opens #2" "$out" "milestone #2 opened"
eq "...milestone #2 stays closed" "$(ms_state theta 2)" "closed"
eq "...milestone #5 is now open" "$(ms_state theta 5)" "open"

section "D. an open milestone that still holds a runnable issue is not touched"
cat > "$T/ms-iota.json" <<'JSON'
[{"number":1,"title":"m1","description":"","state":"open"}]
JSON
printf '3\n' > "$T/run-iota-1"
printf '[{"milestone":{"number":1}}]\n' > "$T/issues-iota.json"
out="$(run_only iota)"
hasnt "...says nothing about closing it" "$out" "drained of runnable issues"
eq "...milestone #1 is still open" "$(ms_state iota 1)" "open"

summary
