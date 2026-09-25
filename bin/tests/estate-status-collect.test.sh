#!/usr/bin/env bash
# SUBJECT: bin/estate-status-collect.py. Hermetic -- fixture /srv, fixture agent
# dir, stubbed `docker` and `crontab`: it cannot pass because dexter happened to
# be healthy while it ran.
set -uo pipefail
. "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib/harness.sh"
harness_tmp
REPO="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../.." && pwd)"
COLLECTOR="$REPO/bin/estate-status-collect.py"

echo "estate-status-collect.test.sh"

mkdir -p "$T/stub" "$T/srv/roster" "$T/srv/groc-browser" "$T/agent"
: > "$T/srv/roster/compose.yaml"
: > "$T/srv/groc-browser/compose.yaml"
: > "$T/srv/groc-browser/.no-autostart"

# `docker ps -aq` answers DOCKER_IDS (rc DOCKER_RC); `docker inspect` answers
# whatever DOCKER_JSON holds. Both seams, because an unreachable daemon and an
# empty host are the two answers this collector must never conflate.
cat > "$T/stub/docker" <<'STUB'
#!/usr/bin/env bash
case "$1" in
  ps)      printf '%s\n' "${DOCKER_IDS:-}"; exit "${DOCKER_RC:-0}" ;;
  inspect) printf '%s\n' "${DOCKER_JSON:-[]}"; exit "${DOCKER_INSPECT_RC:-0}" ;;
esac
exit 0
STUB
cat > "$T/stub/crontab" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "${CRONTAB_OUT:-}"; exit "${CRONTAB_RC:-0}"
STUB
chmod +x "$T/stub/docker" "$T/stub/crontab"

ARMED='0 1 * * * /srv/agent/nightly.sh # realisateur:agent-nightly:RUNNER'
UP='[{"Name":"/roster","Config":{"Image":"i","Labels":{"com.docker.compose.project":"roster"}},
     "State":{"Status":"running","StartedAt":"2026-09-25T00:00:00Z"},"RestartCount":0,
     "HostConfig":{"PortBindings":{"8646/tcp":[{"HostPort":"8646"}]}},
     "NetworkSettings":{"Ports":{"8646/tcp":[{"HostPort":"8646"}]}}}]'

collect() {
  PATH="$T/stub:$PATH" ESTATE_SRV="$T/srv" ESTATE_AGENT_DIR="$T/agent" \
    PYTHONDONTWRITEBYTECODE=1 python3 "$COLLECTOR"
}
field() { python3 -c 'import json,sys;print(json.dumps(eval("d"+sys.argv[1],{"d":json.load(sys.stdin)})))' "$1"; }

# A nightly that ran to the end, dispatched one repo, and the repo's own pass
# log carrying a result, an rc, a report and a PR.
now="$(date -u -d '-2 hours' +%Y-%m-%dT%H:%M:%SZ)"
stamp="$(date -u -d '-2 hours' +%Y%m%dT%H%M%SZ)"
printf 'roster\n' > "$T/agent/repos"
{ printf '=== nightly %s  turns=150  list=x ===\n' "$now"
  printf -- '--- roster: 7 runnable, dispatching %s\n' "$now"
  printf -- '--- roster: pass finished\n'
  printf '=== nightly done %s ===\n' "$now"; } > "$T/agent/nightly.$stamp.log"
{ printf '=== result: success  turns=12  cost=$0.5\n'
  printf '=== %s container exited (rc=0) ===\n' "$now"
  printf '=== REPORT.md (/x/REPORT.md) ===\nPR: https://github.com/hf7y-estate/roster/pull/12\n'
} > "$T/agent/roster.$stamp.log"

section "A. an unreachable daemon is not an empty host"
out="$(DOCKER_RC=1 CRONTAB_OUT="$ARMED" collect)"
eq "containers is null when \`docker ps\` fails"  "$(printf '%s' "$out" | field '["containers"]')" "null"
eq "...and the verdict is DOWN, not OK"          "$(printf '%s' "$out" | field '["verdict"]')" '"DOWN"'
has "...and it says nothing below was read" "$out" "nothing below was read"

out="$(DOCKER_IDS="" CRONTAB_OUT="$ARMED" collect)"
eq "an empty host reads as an EMPTY LIST, never null" "$(printf '%s' "$out" | field '["containers"]')" "[]"

section "B. a declared service that is not running is DOWN"
out="$(DOCKER_IDS="" CRONTAB_OUT="$ARMED" collect)"
eq "no container for roster/compose.yaml" "$(printf '%s' "$out" | field '["verdict"]')" '"DOWN"'
has "...and the finding names the file that declares it" "$out" "roster/compose.yaml"
hasnt "...while .no-autostart exempts groc-browser from the same test" "$out" "groc-browser: declared"

section "C. green: every declared service up, the sweep finished, the pass left a report"
out="$(DOCKER_IDS="a" DOCKER_JSON="$UP" CRONTAB_OUT="$ARMED" collect)"
eq "verdict"                     "$(printf '%s' "$out" | field '["verdict"]')" '"OK"'
eq "no findings"                 "$(printf '%s' "$out" | field '["findings"]')" "[]"
eq "the pass's PR is read off the report, not off an author" \
   "$(printf '%s' "$out" | field '["nightly"]["passes"][0]["pr"]')" '"https://github.com/hf7y-estate/roster/pull/12"'
eq "the queue depth comes from the sweep's own line" \
   "$(printf '%s' "$out" | field '["nightly"]["last_run"]["dispatched"]["roster"]["queue"]')" "7"

section "D. running is not reachable: declared ports that never published"
BLIND_PORTS='[{"Name":"/roster","Config":{"Image":"i","Labels":{"com.docker.compose.project":"roster"}},
     "State":{"Status":"running","StartedAt":"2026-09-25T00:00:00Z"},"RestartCount":0,
     "HostConfig":{"PortBindings":{"8646/tcp":[{"HostPort":"8646"}]}},
     "NetworkSettings":{"Ports":{"8646/tcp":null}}}]'
out="$(DOCKER_IDS="a" DOCKER_JSON="$BLIND_PORTS" CRONTAB_OUT="$ARMED" collect)"
eq "a running container with no published binding is DEGRADED" \
   "$(printf '%s' "$out" | field '["verdict"]')" '"DEGRADED"'
has "...and the finding says so in those words" "$out" "NONE of its declared ports published"

section "E. the dispatcher itself"
out="$(DOCKER_IDS="a" DOCKER_JSON="$UP" CRONTAB_RC=1 collect)"
eq "an unreadable crontab is null (UNKNOWN), never false" \
   "$(printf '%s' "$out" | field '["nightly"]["armed"]')" "null"
has "...and that is a finding, not a pass" "$out" "is armed is UNKNOWN"

out="$(DOCKER_IDS="a" DOCKER_JSON="$UP" CRONTAB_OUT="# $ARMED" collect)"
eq "a COMMENTED-OUT cron line is NOT armed" "$(printf '%s' "$out" | field '["nightly"]["armed"]')" "false"
eq "...and nothing dispatching tonight is DOWN" "$(printf '%s' "$out" | field '["verdict"]')" '"DOWN"'

section "F. a pass is graded on what it left, not on exiting 0"
{ printf '=== result: success  turns=12  cost=$0.5\n'
  printf '=== %s container exited (rc=0) ===\n' "$now"
  printf '=== REPORT.md (/x/REPORT.md) ===\nNOT FOUND at that path.\n'
} > "$T/agent/roster.$stamp.log"
out="$(DOCKER_IDS="a" DOCKER_JSON="$UP" CRONTAB_OUT="$ARMED" collect)"
eq "success + rc 0 + no REPORT.md is DEGRADED" "$(printf '%s' "$out" | field '["verdict"]')" '"DEGRADED"'
has "...and the finding names the report" "$out" "wrote no REPORT.md"

rm -f "$T/agent/roster.$stamp.log"
out="$(DOCKER_IDS="a" DOCKER_JSON="$UP" CRONTAB_OUT="$ARMED" collect)"
eq "a repo on the list with no log at all reads as never dispatched" \
   "$(printf '%s' "$out" | field '["nightly"]["passes"][0]["log"]')" "null"
has "...and says so" "$out" "never dispatched"

section "G. a stale sweep is a finding, whatever the passes say"
old="$(date -u -d '-3 days' +%Y-%m-%dT%H:%M:%SZ)"
rm -f "$T/agent"/nightly.*.log
printf '=== nightly %s  turns=150  list=x ===\n=== nightly done %s ===\n' "$old" "$old" \
  > "$T/agent/nightly.$(date -u -d '-3 days' +%Y%m%dT%H%M%SZ).log"
out="$(DOCKER_IDS="a" DOCKER_JSON="$UP" CRONTAB_OUT="$ARMED" collect)"
eq "a sweep older than 26h is DOWN" "$(printf '%s' "$out" | field '["verdict"]')" '"DOWN"'
has "...and the finding carries the age" "$out" "past the 26h a daily cron allows"

summary
