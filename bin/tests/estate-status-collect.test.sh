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
# Read the set out of the collector, so adding a dispatch file does not leave
# this fixture one file short and every verdict DEGRADED.
DFILES="$(python3 -c 'import re,sys; print(" ".join(re.findall(r"\"([^\"]+)\"", re.search(r"DISPATCH_FILES = \((.*?)\)", open(sys.argv[1]).read(), re.S).group(1))))' "$COLLECTOR")"
UP='[{"Name":"/roster","Config":{"Image":"i","Labels":{"com.docker.compose.project":"roster"}},
     "State":{"Status":"running","StartedAt":"2026-09-25T00:00:00Z"},"RestartCount":0,
     "HostConfig":{"PortBindings":{"8646/tcp":[{"HostPort":"8646"}]}},
     "NetworkSettings":{"Ports":{"8646/tcp":[{"HostPort":"8646"}]}}}]'

# ESTATE_AGENT_SRC is the clone half of the dispatch-source probe. Default it to
# a mirror of the fixture so the OTHER sections are not all graded on wiring.
mkdir -p "$T/clone"
for f in $DFILES; do : > "$T/clone/$f"; ln -sfn "$T/clone/$f" "$T/agent/$f"; done
# The credential probe is stubbed whole: this suite must never read a real one,
# and TOK_OUT is the seam every case below steers.
cat > "$T/stub/tokcheck" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "${TOK_OUT:-$(printf 'kind\tclassic\nreachable\tyes\nlogin\thf7y\nworkflows\tyes')}"
exit "${TOK_RC:-0}"
STUB
chmod +x "$T/stub/tokcheck"
collect() {
  PATH="$T/stub:$PATH" ESTATE_SRV="$T/srv" ESTATE_AGENT_DIR="$T/agent" \
    ESTATE_AGENT_SRC="${AGENT_SRC_OVERRIDE:-$T/clone}" ESTATE_TOKCHECK="$T/stub/tokcheck" \
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

# run-agent.sh's own report, signed. rc 0 and a clean tree is an orderly pass
# that landed nothing -- legible, and NOT a finding (#1329).
{ printf '=== result: success  turns=47  cost=$1.02\n'
  printf '=== %s container exited (rc=0) ===\n' "$now"
  printf '=== REPORT.md (/x/REPORT.md) -- WRITTEN BY run-agent.sh, the agent wrote none ===\n'
  printf 'harness-report: rc=0 turns=47 of 150 tree=clean branch=main\n'
} > "$T/agent/roster.$stamp.log"
out="$(DOCKER_IDS="a" DOCKER_JSON="$UP" CRONTAB_OUT="$ARMED" collect)"
eq "a harness-written report is its own state, not \`present\` and not \`missing\`" \
   "$(printf '%s' "$out" | field '["nightly"]["passes"][0]["report"]')" '"synthesized"'
eq "...and rc 0 on a clean tree is OK, not DEGRADED" \
   "$(printf '%s' "$out" | field '["verdict"]')" '"OK"'

sed -i 's/tree=clean/tree=dirty/' "$T/agent/roster.$stamp.log"
out="$(DOCKER_IDS="a" DOCKER_JSON="$UP" CRONTAB_OUT="$ARMED" collect)"
eq "...while a dirty tree under the same silence IS a finding" \
   "$(printf '%s' "$out" | field '["verdict"]')" '"DEGRADED"'
has "...and it quotes the harness's own line" "$out" "tree=dirty"

rm -f "$T/agent/roster.$stamp.log"
out="$(DOCKER_IDS="a" DOCKER_JSON="$UP" CRONTAB_OUT="$ARMED" collect)"
eq "a repo on the list with no log at all reads as never dispatched" \
   "$(printf '%s' "$out" | field '["nightly"]["passes"][0]["log"]')" "null"
has "...and says so" "$out" "never dispatched"

section "H. the dispatcher's own source: only a link survives the next merge"
out="$(DOCKER_IDS="a" DOCKER_JSON="$UP" CRONTAB_OUT="$ARMED" collect)"
eq "four symlinks into the clone read as linked" \
   "$(printf '%s' "$out" | field '["nightly"]["dispatch_source"]["run-agent.sh"]')" '"linked"'
hasnt "...and that is not a finding" "$out" "wire-agent-dispatch"

rm -f "$T/agent/repos"; printf 'roster\n' > "$T/agent/repos"; printf 'roster\n' > "$T/clone/repos"
out="$(DOCKER_IDS="a" DOCKER_JSON="$UP" CRONTAB_OUT="$ARMED" collect)"
eq "a plain copy that AGREES is still not linked" \
   "$(printf '%s' "$out" | field '["nightly"]["dispatch_source"]["repos"]')" '"copy"'
eq "...and an unrefreshed copy is DEGRADED, not OK" \
   "$(printf '%s' "$out" | field '["verdict"]')" '"DEGRADED"'
has "...and the finding hands over the command that fixes it" "$out" "wire-agent-dispatch.sh --apply"

printf 'something-else\n' > "$T/clone/repos"
out="$(DOCKER_IDS="a" DOCKER_JSON="$UP" CRONTAB_OUT="$ARMED" collect)"
eq "a copy that DIFFERS is drifted, which is the loud one" \
   "$(printf '%s' "$out" | field '["nightly"]["dispatch_source"]["repos"]')" '"drifted"'
has "...and the finding says somebody edited the host" "$out" "never on \`main\`"

# The morning-after state: the host holds a real earlier version of the path.
# It must read as behind and link cleanly, or the verb refuses exactly when it
# is needed. The fixture clone is not a git repo, so this drives the real one.
prev="$(git -C "$REPO" log --format=%H -- agent/run-agent.sh | sed -n 2p)"
if [ -n "$prev" ]; then
  git -C "$REPO" show "$prev:agent/run-agent.sh" > "$T/agent/run-agent.sh"
  out="$(AGENT_SRC_OVERRIDE="$REPO/agent" DOCKER_IDS="a" DOCKER_JSON="$UP" CRONTAB_OUT="$ARMED" collect)"
  eq "an earlier version of the path is behind, not drifted" \
     "$(printf '%s' "$out" | field '["nightly"]["dispatch_source"]["run-agent.sh"]')" '"behind"'
  has "...and the finding says the nightly runs an earlier one" "$out" "running an EARLIER"
fi

out="$(AGENT_SRC_OVERRIDE="$T/no-clone-here" DOCKER_IDS="a" DOCKER_JSON="$UP" CRONTAB_OUT="$ARMED" collect)"
eq "run from outside a checkout it says UNKNOWN, never OK" \
   "$(printf '%s' "$out" | field '["nightly"]["dispatch_source"]')" "null"
has "...and that is a finding" "$out" "is UNKNOWN"

# back to linked, so G grades the sweep and not the wiring
for f in $DFILES; do rm -f "$T/agent/$f"; done
for f in $DFILES; do : > "$T/clone/$f"; ln -sfn "$T/clone/$f" "$T/agent/$f"; done

section "I. the credential the nightly pushes with"
out="$(DOCKER_IDS="a" DOCKER_JSON="$UP" CRONTAB_OUT="$ARMED" collect)"
eq "a live credential with workflow scope is not a finding" \
   "$(printf '%s' "$out" | field '["verdict"]')" '"OK"'
eq "...and only the derived answer is published, never a scope list" \
   "$(printf '%s' "$out" | field '["nightly"]["dispatch_token"]["workflows"]')" '"yes"'

out="$(TOK_OUT="$(printf 'kind\tclassic\nreachable\tyes\nlogin\thf7y\nworkflows\tno')" \
      DOCKER_IDS="a" DOCKER_JSON="$UP" CRONTAB_OUT="$ARMED" collect)"
eq "no workflow scope is DEGRADED -- it is crt's lost pass" \
   "$(printf '%s' "$out" | field '["verdict"]')" '"DEGRADED"'
has "...and the finding says what it costs" "$out" "commits, fails to push"

out="$(TOK_OUT="$(printf 'reachable\tno\nwhy\tthe API answered 401')" TOK_RC=5 \
      DOCKER_IDS="a" DOCKER_JSON="$UP" CRONTAB_OUT="$ARMED" collect)"
eq "a DEAD credential is DOWN, not degraded -- nothing tonight lands" \
   "$(printf '%s' "$out" | field '["verdict"]')" '"DOWN"'

out="$(TOK_OUT="$(printf 'reachable\tunknown\nwhy\tthe API was not reached')" TOK_RC=6 \
      DOCKER_IDS="a" DOCKER_JSON="$UP" CRONTAB_OUT="$ARMED" collect)"
eq "could-not-ask is DEGRADED, never OK" \
   "$(printf '%s' "$out" | field '["verdict"]')" '"DEGRADED"'
has "...and says it could not ask" "$out" "could not ask what the dispatch credential"

out="$(ESTATE_TOKCHECK_MISSING=1 DOCKER_IDS="a" DOCKER_JSON="$UP" CRONTAB_OUT="$ARMED" \
      PATH="$T/stub:$PATH" ESTATE_SRV="$T/srv" ESTATE_AGENT_DIR="$T/agent" \
      ESTATE_AGENT_SRC="$T/clone" ESTATE_TOKCHECK="$T/no-such-probe" \
      PYTHONDONTWRITEBYTECODE=1 python3 "$COLLECTOR")"
eq "no probe at all publishes null, never a healthy guess" \
   "$(printf '%s' "$out" | field '["nightly"]["dispatch_token"]')" "null"
has "...and that is a finding" "$out" "whether tonight can push is UNKNOWN"

section "G. a stale sweep is a finding, whatever the passes say"
old="$(date -u -d '-3 days' +%Y-%m-%dT%H:%M:%SZ)"
rm -f "$T/agent"/nightly.*.log
printf '=== nightly %s  turns=150  list=x ===\n=== nightly done %s ===\n' "$old" "$old" \
  > "$T/agent/nightly.$(date -u -d '-3 days' +%Y%m%dT%H%M%SZ).log"
out="$(DOCKER_IDS="a" DOCKER_JSON="$UP" CRONTAB_OUT="$ARMED" collect)"
eq "a sweep older than 26h is DOWN" "$(printf '%s' "$out" | field '["verdict"]')" '"DOWN"'
has "...and the finding carries the age" "$out" "past the 26h a daily cron allows"

section "J. which image the night ran, and a pull that failed"
# The image line and a digest, in the shape nightly.sh prints them.
rm -f "$T/agent"/nightly.*.log
{ printf '=== nightly %s  turns=150  list=x ===\n' "$now"
  printf '=== image: ghcr.io/hf7y-estate/agent@sha256:5b54277abad3 ===\n'
  printf -- '--- roster: 7 runnable, dispatching %s\n' "$now"
  printf -- '--- roster: pass finished\n'
  printf '=== nightly done %s ===\n' "$now"; } > "$T/agent/nightly.$stamp.log"
out="$(DOCKER_IDS="a" DOCKER_JSON="$UP" CRONTAB_OUT="$ARMED" collect)"
eq "the image the night ran is read back from the log" \
   "$(printf '%s' "$out" | field '["nightly"]["last_run"]["image"]')" \
   '"ghcr.io/hf7y-estate/agent@sha256:5b54277abad3"'
eq "...and a night that pulled is not reported as a pull failure" \
   "$(printf '%s' "$out" | field '["nightly"]["last_run"]["pull_failed"]')" "null"

# A failed pull: nightly.sh exits before the loop, so there is no `done` line
# and no dispatch -- and that must not read as "still running".
rm -f "$T/agent"/nightly.*.log
{ printf '=== nightly %s  turns=150  list=x ===\n' "$now"
  printf '=== PULL FAILED: ghcr.io/hf7y-estate/agent:latest -- dispatching nothing ===\n'
} > "$T/agent/nightly.$stamp.log"
out="$(DOCKER_IDS="a" DOCKER_JSON="$UP" CRONTAB_OUT="$ARMED" collect)"
eq "a failed pull names the image it could not get" \
   "$(printf '%s' "$out" | field '["nightly"]["last_run"]["pull_failed"]')" \
   '"ghcr.io/hf7y-estate/agent:latest"'
has "...and it is a finding that says nothing landed" "$out" "and dispatched nothing"
eq  "...and the verdict is DOWN, not a warning" "$(printf '%s' "$out" | field '["verdict"]')" '"DOWN"'
hasnt "...and it is NOT reported as a sweep that might still be running" "$out" "still running, or it died"

summary
