#!/usr/bin/env bash
# roster-service.test.sh -- ARMING WORKS WHILE `suites` IS RED, proved with
# `gh` off PATH so there is no build to wait for. hf7y/scheduler#429: a park of
# 20 PRs on 2026-08-30 left EIGHT unmerged, each having exited 0.
#
# STATE ONLY -- why there is no declaration half: roster_server.py's docstring.
set -uo pipefail
. "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib/harness.sh"
HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../.." && pwd)"
SRV="$HERE/provision/dexter/roster/roster_server.py"

T="$(mktemp -d)"
PORT="${ROSTER_TEST_PORT:-18747}"
URL="http://127.0.0.1:$PORT"
cleanup() { [ -n "${PID:-}" ] && kill "$PID" 2>/dev/null; rm -rf "$T"; }
trap cleanup EXIT

section "A. the service comes up holding nothing, and reaches no git host to do it"
env -i PATH=/usr/bin:/bin \
    ROSTER_DB="$T/roster.db" ROSTER_PORT="$PORT" ROSTER_WRITE_TOKEN=tok \
    python3 "$SRV" > "$T/srv.log" 2>&1 &
PID=$!
for _ in $(seq 1 40); do curl -fsS "$URL/healthz" >/dev/null 2>&1 && break; sleep 0.25; done

H="$(curl -fsS "$URL/healthz")"
eq "A1 healthz answers" "$(jq -r .ok <<<"$H")" "true"
eq "A2 it starts EMPTY -- there is no declaration to ingest and none is invented" \
   "$(jq -r .rows <<<"$H")" "0"
eq "A3 nothing is live, so an empty service arms nothing" "$(jq -r .live <<<"$H")" "0"
eq "A4 no declaration URL is served, because none is read" \
   "$(jq -r 'has("declaration_url")' <<<"$H")" "false"
eq "A5 the server names no git host at all" \
   "$(grep -c 'githubusercontent\|api.github.com' "$SRV")" "0"

section "B. arming needs no build, no PR, and no GitHub at all"
GHLESS="$T/nogh"; mkdir -p "$GHLESS"
for b in curl jq; do ln -sf "$(command -v "$b")" "$GHLESS/$b"; done
arm() { env -i PATH="$GHLESS" curl -fsS -X POST "$URL/roster/$1" \
          -H 'X-Roster-Token: tok' -d "{\"state\":\"$2\",\"by\":\"witness\"}"; }

eq "B1 a FIRST write creates the row and returns it COMMITTED, not a scheduled intent" \
   "$(arm alpha live | jq -r .state)" "live"
eq "B2 and a fresh read agrees -- it is live NOW, not once something goes green" \
   "$(curl -fsS "$URL/roster/alpha" | jq -r .state)" "live"
eq "B3 parking works the same way, which is the half you want during an incident" \
   "$(arm alpha parked | jq -r .state)" "parked"
eq "B4 no gh binary was reachable while that happened" \
   "$(PATH="$GHLESS" command -v gh || echo none)" "none"
arm crt parked >/dev/null
eq "B5 a project is born from its write, so the roster now holds exactly what was written" \
   "$(curl -fsS "$URL/roster" | jq -r '[.rows[].project] | sort | join(",")')" "alpha,crt"

section "C. the audit survives: who armed what, when"
LOG="$(curl -fsS "$URL/log")"
eq "C1 every transition is logged, the creating write included" \
   "$(jq -r '.armings | length' <<<"$LOG")" "3"
eq "C2 a created row's from_state is null, so birth is distinguishable from a flip" \
   "$(jq -r '[.armings[] | select(.from_state == null)] | length' <<<"$LOG")" "2"
eq "C3 and with who did it" "$(jq -r '.armings[0].by' <<<"$LOG")" "witness"

section "D. the write refuses by default and on a bad token"
eq "D1 a wrong token is 403" \
   "$(curl -s -o /dev/null -w '%{http_code}' -X POST "$URL/roster/crt" \
        -H 'X-Roster-Token: wrong' -d '{"state":"live"}')" "403"
eq "D2 a junk state is 400 -- the only two words are live and parked" \
   "$(curl -s -o /dev/null -w '%{http_code}' -X POST "$URL/roster/crt" \
        -H 'X-Roster-Token: tok' -d '{"state":"sortof"}')" "400"
eq "D3 crt was not armed by any of that" \
   "$(curl -fsS "$URL/roster/crt" | jq -r .state)" "parked"
eq "D4 a GET for a row nobody has written is 404 -- an ANSWER, never a connect failure" \
   "$(curl -s -o /dev/null -w '%{http_code}' "$URL/roster/nosuch")" "404"

env -i PATH=/usr/bin:/bin ROSTER_DB="$T/notok.db" ROSTER_PORT="$((PORT + 1))" \
    python3 "$SRV" > "$T/notok.log" 2>&1 &
NOTOK=$!
for _ in $(seq 1 40); do curl -fsS "http://127.0.0.1:$((PORT + 1))/healthz" >/dev/null 2>&1 && break; sleep 0.25; done
eq "D5 with no ROSTER_WRITE_TOKEN every write is 503, not accepted" \
   "$(curl -s -o /dev/null -w '%{http_code}' -X POST "http://127.0.0.1:$((PORT + 1))/roster/alpha" \
        -H 'X-Roster-Token: anything' -d '{"state":"live"}')" "503"
kill "$NOTOK" 2>/dev/null

section "E. a reader that cannot reach the service is BLIND, never stale"
OUT="$(ARMING_ROSTER_URL="http://127.0.0.1:$((PORT + 2))/roster" bash -c \
  ". '$HERE/bin/lib/arming.sh'; arming_load; printf '%s|%s' \"\$?\" \"\$(arming_state alpha)\"")"
eq "E1 arming_load returns 6 and arming_state answers with nothing" "$OUT" "6|"
OUT="$(ARMING_ROSTER_URL="$URL/roster" bash -c \
  ". '$HERE/bin/lib/arming.sh'; arming_load && arming_state crt")"
eq "E2 ...and reaches the real thing when it is up" "$OUT" "parked"

section "G. schedule/ config is served from what the build baked in -- never fetched here, never carried"
SCHED="$T/schedule"; mkdir -p "$SCHED"
printf 'PROJECT=alpha\n' > "$SCHED/alpha.conf"
printf '# fragment\nsome prose\n' > "$SCHED/_gen2.md"
printf 'ROSTER-CONTENTS-MUST-NEVER-SERVE\n' > "$SCHED/ROSTER"
printf 'FREEZE-CONTENTS-MUST-NEVER-SERVE\n' > "$SCHED/FREEZE"

env -i PATH=/usr/bin:/bin ROSTER_DB="$T/sched.db" ROSTER_PORT="$((PORT + 3))" \
    ROSTER_SCHEDULE_DIR="$SCHED" python3 "$SRV" > "$T/sched.log" 2>&1 &
SCHEDPID=$!
SURL="http://127.0.0.1:$((PORT + 3))"
for _ in $(seq 1 40); do curl -fsS "$SURL/healthz" >/dev/null 2>&1 && break; sleep 0.25; done

eq "G1 a served .conf returns exactly what the build baked in" \
   "$(curl -fsS "$SURL/schedule/alpha.conf")" "PROJECT=alpha"
eq "G2 an .md fragment is served the same way" \
   "$(curl -fsS "$SURL/schedule/_gen2.md")" "$(printf '# fragment\nsome prose')"
eq "G3 a missing file 404s" \
   "$(curl -s -o /dev/null -w '%{http_code}' "$SURL/schedule/nosuch.conf")" "404"
eq "G4 ROSTER is never served, even sitting right there in the baked dir" \
   "$(curl -s -o /dev/null -w '%{http_code}' "$SURL/schedule/ROSTER")" "404"
eq "G5 FREEZE is never served either -- both stay live gh api reads, forever" \
   "$(curl -s -o /dev/null -w '%{http_code}' "$SURL/schedule/FREEZE")" "404"
eq "G6 a path-traversal attempt is rejected, not answered from outside the dir" \
   "$(curl -s --path-as-is -o /dev/null -w '%{http_code}' "$SURL/schedule/../etc/passwd")" "400"
kill "$SCHEDPID" 2>/dev/null

summary
