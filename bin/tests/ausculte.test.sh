#!/usr/bin/env bash
# SUBJECT: bin/ausculte.sh. Hermetic -- every composed probe is a stub and
# curl/ssh/gh are stubbed failing, so this cannot pass because the fleet
# happened to be healthy. The exit ladder IS the contract, pinned rung by rung.
set -uo pipefail
. "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib/harness.sh"
check(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected [$3] got [$2]"; fi; }

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin/lib"
cp "$HERE/../ausculte.sh" "$TMP/bin/"
cp "$HERE/../lib/cli-guard.sh" "$TMP/bin/lib/"
cp "$HERE/../lib/part.sh" "$TMP/bin/lib/"
cp "$HERE/../lib/host-check.sh" "$TMP/bin/lib/"
cp "$HERE/../lib/zaxon.sh" "$TMP/bin/lib/"
cp "$HERE/../lib/propagation-set.sh" "$TMP/bin/lib/"
cp "$HERE/../lib/estate-set.sh" "$TMP/bin/lib/"
cp "$HERE/../lib/cron-lock.sh" "$TMP/bin/lib/"
cp "$HERE/../lib/fleet-hosts-set.sh" "$TMP/bin/lib/"

stub() { printf '#!/usr/bin/env bash\nprintf "%%s\\n" "%s"\nexit %s\n' "${3:-}" "$2" > "$TMP/bin/$1"; chmod +x "$TMP/bin/$1"; }

mkdir -p "$TMP/stub"
for c in curl ssh gh; do printf '#!/usr/bin/env bash\nexit 1\n' > "$TMP/stub/$c"; chmod +x "$TMP/stub/$c"; done
run() { PATH="$TMP/stub:$PATH" bash "$TMP/bin/ausculte.sh" "$@" 2>&1; }

echo "ausculte contract"

stub decision-rot.sh 0
run rot >/dev/null; check "a clean probe exits 0" "$?" "0"

stub decision-rot.sh 1 "answered and still open"
run rot >/dev/null; check "a probe reporting rot is DOWN (5)" "$?" "5"

stub decision-rot.sh 2 "usage"
out="$(run rot)"; check "a usage error from a probe is BLIND, not DOWN" "$?" "6"
case "$out" in *"fix ausculte"*) ok "...and it says the fault is ausculte's" ;;
  *) bad "usage error names itself" "got: $out" ;; esac

rm -f "$TMP/bin/decision-rot.sh"
out="$(run rot)"; check "a missing probe is BLIND (6), never OK" "$?" "6"
case "$out" in *"NOT \"all clear\""*) ok "...and the summary refuses to read as all-clear" ;;
  *) bad "blind summary" "got: $out" ;; esac

stub decision-rot.sh 1 "rot found"
run rot >/dev/null
check "a probe DOWN exits DOWN" "$?" "5"

# THE HEADLINE IS A COUNT AND THE OLDEST ROW. `tail -1` read the LAST line of a
# block sorted oldest-first, so it named the NEWEST rot and hid the rest: one
# 2d tracker stood in for 69 rotting decisions, and a 12d question of Zach's in
# the same output was never mentioned. Fixture is decision-rot.sh's real shape.
cat > "$TMP/bin/decision-rot.sh" <<'ROT'
#!/usr/bin/env bash
cat <<'OUT'
REPO                ANSWERED  ROTTING  OLDEST_DAYS   UNC_OPEN
groc-mangr                 3        1           12          0
realisateur                9        1            2          0
TOTAL                     12        2                       0

ROTTING -- answered, still open:
  groc-mangr       #10    answered 2026-08-14    12d  DECISION: delivery windows
  realisateur      #577   answered 2026-08-24     2d  TRACKER: provisioning block
OUT
exit 1
ROT
chmod +x "$TMP/bin/decision-rot.sh"
out="$(run rot)"
case "$out" in *"2 answered decision(s) still open"*) ok "the rot headline carries the COUNT, not one row" ;;
  *) bad "rot headline counts" "got: $out" ;; esac
case "$out" in *"#10"*) ok "...and names the OLDEST row" ;;
  *) bad "rot headline names the oldest" "got: $out" ;; esac
case "$out" in *"#577"*) bad "rot headline names the newest" "got: $out" ;;
  *) ok "...and not the newest one" ;; esac

# --- arming reads what the accounts DID ----------------------------------
# Counting the word "armed" said OK while three accounts had been dead eight
# days -- and fromdateiso8601 rejected the ledger's real offsets until the
# collector started normalising every timestamp to Z (#919).
status() { printf '#!/usr/bin/env bash\ncat <<'"'"'J'"'"'\n%s\nJ\n' "$1" > "$TMP/stub/curl"; chmod +x "$TMP/stub/curl"; }
recent="$(date -u -d '-1 hour' +%Y-%m-%dT%H:%M:%SZ)"
old_run="$(date -u -d '-9 days' +%Y-%m-%dT%H:%M:%SZ)"

status "{\"accounts\":[{\"account\":\"live\",\"armed\":true,\"last_run\":{\"started_at\":\"$recent\"}}]}"
out="$(run arming)"; rc=$?
check "an account that dispatched recently is OK" "$rc" "0"
has "and a Z-format timestamp grades cleanly" "$out" "OK      arming"

status "{\"accounts\":[{\"account\":\"dead\",\"armed\":true,\"last_run\":{\"started_at\":\"$old_run\"}}]}"
out="$(run arming)"; rc=$?
check "an armed account that stopped dispatching is DOWN (5)" "$rc" "5"
has "and it is named" "$out" "dead"

status "{\"accounts\":[{\"account\":\"live\",\"armed\":true,\"last_run\":{\"started_at\":\"2026-09-01T00:30:45-05:00\"}}]}"
out="$(run arming)"; rc=$?
check "a negative-offset timestamp is not this probe's to parse -- BLIND (6), not a silent pass (#919)" "$rc" "6"
has "and it says so rather than reading as OK" "$out" "could not be graded"

# No run record is BLIND, not DOWN: three accounts dispatch and write none at
# all (hf7y/scheduler#259), so the document cannot say either way.
status "{\"accounts\":[{\"account\":\"never\",\"armed\":true,\"last_run\":null}]}"
out="$(run arming)"; rc=$?
check "an armed account with no run record is BLIND (6), not DOWN" "$rc" "6"
has "and it is named too" "$out" "never"
hasnt "and it is never called not-dispatching" "$out" "not dispatching"

status "{\"nonsense\":true}"
out="$(run arming)"; rc=$?
check "a status document with no accounts is BLIND (6)" "$rc" "6"
hasnt "and never reports an account count it did not read" "$out" "account(s) armed"

status "{\"accounts\":[],\"watcher\":{\"accounts_from\":\"NOT COLLECTED -- the guest was unreachable\"}}"
out="$(run arming)"; rc=$?
check "an empty accounts[] is BLIND (6) -- it read OK through the 2026-08-29 wedge" "$rc" "6"
has "and it repeats why the publisher collected nothing" "$out" "NOT COLLECTED"
hasnt "and it never calls zero accounts armed" "$out" "0 account(s) armed"

expired="$(date -u -d '-1 hour' +%Y-%m-%dT%H:%M:%SZ)"
status "{\"accounts\":[{\"account\":\"live\",\"armed\":true,\"last_run\":{\"started_at\":\"$recent\"}}],\"watcher\":{\"valid_until\":\"$expired\"}}"
out="$(run arming)"; rc=$?
check "a status past its own valid_until is BLIND (6) even with healthy accounts -- a DEAD watcher publishes nothing new" "$rc" "6"
has "and it names the expiry" "$out" "expired at"

status "{\"accounts\":[{\"account\":\"live\",\"armed\":true,\"last_run\":{\"started_at\":\"$recent\"}}],\"valid_until\":\"$expired\"}"
out="$(run arming)"; rc=$?
check "and the flat shape expires too, so neither side of the schema is a blind spot" "$rc" "6"

# --- roster_read grades the AUTHORITY, not what the accounts did with it --
status '{"roster_read":true,"accounts":[{"account":"a","roster_state":"live"}]}'  # arming above reads accounts[].armed, which the accounts publish and which stays populated with the roster service gone -- so roster sat Exited four days and ausculte still read clean (#1191), while the collector measured the fact the whole time
out="$(run roster_read)"; rc=$?
check "a collector that read the roster service is OK" "$rc" "0"

status '{"roster_read":false,"accounts":[{"account":"a","roster_state":null},{"account":"b","roster_state":null}]}'
out="$(run roster_read)"; rc=$?
check "roster_read false is DOWN (5) -- the arming authority is unreachable" "$rc" "5"
has "and it counts the accounts left with no roster_state" "$out" "2 account(s)"

status '{"accounts":[],"watcher":{"verdict":"DEGRADED","why":"sshd sent its banner but the session stalled -- no answer in 180s"}}'  # ABSENT IS NOT FALSE: this is the watcher's degraded fallback, measured live 2026-09-15 -- it publishes no accounts and no roster_read when the collector could not run, and reading that silence as DOWN alarms on the wrong host
out="$(run roster_read)"; rc=$?
check "an absent roster_read is BLIND (6), never DOWN -- the document cannot say" "$rc" "6"
has "and it repeats why the publisher could not collect" "$out" "the session stalled"
hasnt "and it never claims the roster service is unreachable" "$out" "could not read the roster service"

status '{"roster_read":null,"accounts":[]}'
out="$(run roster_read)"; rc=$?
check "an explicit null grades BLIND too, not DOWN" "$rc" "6"

status "{\"roster_read\":true,\"accounts\":[{\"account\":\"a\",\"roster_state\":\"live\"}],\"watcher\":{\"valid_until\":\"$expired\"}}"
out="$(run roster_read)"; rc=$?
check "a status past its own valid_until is BLIND (6) even reading true -- a DEAD watcher publishes nothing new" "$rc" "6"
has "and it names the expiry" "$out" "expired at"

# --- pullable: can a rebuilt dexter recover from its compose files alone? ----
pullssh() {  # $1 the image: lines dexter's compose files hold; $2 `docker manifest inspect` exit on dexter, $3 its first stderr line. The probe calls ssh twice; only the pull call names docker.
  { printf '#!/usr/bin/env bash\n'
    printf 'case "$*" in *docker*) while IFS= read -r l; do printf "%%s\\t%%s\\t%%s\\n" %q "$l" %q; done; exit 0 ;; esac\n' "$2" "${3:-}"
    printf 'cat <<'"'"'R'"'"'\n%s\nR\n' "$1"
  } > "$TMP/stub/ssh"; chmod +x "$TMP/stub/ssh"; }

out="$(run pullable)"; rc=$?
check "an unreachable dexter is BLIND (6) -- an unread compose file grades nothing" "$rc" "6"

pullssh 'groc-browser:local' 1 'Error response from daemon: pull access denied for groc-browser'
out="$(run pullable)"; rc=$?
check "an image with no registry is DOWN (5) -- it exists only in dexter's local store" "$rc" "5"
has "and it says a rebuilt dexter cannot recover it" "$out" "cannot recover it"

pullssh 'ghcr.io/hf7y/wtul-dexter-promote:latest' 1 'unauthorized'
out="$(run pullable)"; rc=$?
check "a ghcr package dexter's credential cannot pull is DOWN (5)" "$rc" "5"
has "and it names dexter's read:packages login, the path Zach ruled (#1210)" "$out" "read:packages"

pullssh 'ghcr.io/hf7y/roster:latest' 0
out="$(run pullable)"; rc=$?
check "a PRIVATE ghcr package dexter pulls with its own credential is OK -- private is the rule, not the fault (#1210)" "$rc" "0"

pullssh 'ghcr.io/hf7y/groc-browser:latest  # NOT groc-browser:local with a build: . -- dexter pulls and never builds (#322)' 0
out="$(run pullable)"; rc=$?
check "a trailing YAML comment is stripped, not fed to the registry -- the prose ratchet puts explanation exactly there" "$rc" "0"
hasnt "and no verdict quotes the comment back" "$out" "never builds"

pullssh 'ghcr.io/hf7y/roster:latest' 1 'Get "https://ghcr.io/v2/": dial tcp: i/o timeout'  # A REGISTRY THAT WILL NOT ANSWER IS NOT A PRIVATE PACKAGE: grading silence as DOWN would alarm about dexter when the fault is the network or ghcr itself
out="$(run pullable)"; rc=$?
check "a registry that does not answer is BLIND (6), never DOWN" "$rc" "6"

printf '#!/usr/bin/env bash\nexit 1\n' > "$TMP/stub/ssh"; chmod +x "$TMP/stub/ssh"

# --- promote: is it cycling, or merely up? ----------------------------------
# `docker ps` says "Up 3 hours" for a container whose loop died; the timestamp
# on the container's own `cycle ok` line is the only thing that separates them.
prssh() { printf '#!/usr/bin/env bash\ncat <<'"'"'R'"'"'\n%s\nR\n' "$1" > "$TMP/stub/ssh"; chmod +x "$TMP/stub/ssh"; }
now="$(date -u +%FT%TZ)"; long_ago="$(date -u -d '2 hours ago' +%FT%TZ)"

out="$(run promote)"; rc=$?
check "an unreachable dexter is BLIND (6) -- an unread container grades nothing" "$rc" "6"

prssh 'NODECL'
out="$(run promote)"; rc=$?
check "an undeployed promote is BLIND (6), never OK -- the declaration lives in wtul, not on dexter" "$rc" "6"
has "and it names what would deploy it" "$out" "deploy.sh"

prssh "INTERVAL 300
APPLY 1
STATE running
LAST wtul-dexter-promote: cycle ok, $now"
out="$(run promote)"; rc=$?
check "running with a fresh cycle stamp is OK" "$rc" "0"

prssh "INTERVAL 300
APPLY 0
STATE running
LAST wtul-dexter-promote: cycle ok, $now"
out="$(run promote)"; rc=$?
check "a dry-run promote still grades the clock OK" "$rc" "0"
has "...and the row refuses to read as 'discs are reaching the library'" "$out" "promotes nothing"

prssh "INTERVAL 300
APPLY 1
STATE running
LAST wtul-dexter-promote: cycle ok, $long_ago"
out="$(run promote)"; rc=$?
check "up for hours past a 300s interval is DOWN (5) -- which is the question docker ps cannot answer" "$rc" "5"
has "and it says up is not cycling" "$out" "it is not cycling"

prssh "INTERVAL 300
APPLY 1
STATE exited"
out="$(run promote)"; rc=$?
check "a stopped container is DOWN (5) -- the entrypoint exits on a failed cycle rather than looping silently" "$rc" "5"

prssh "INTERVAL 300
APPLY 1
STATE running"
out="$(run promote)"; rc=$?
check "running with no completed cycle is DOWN (5)" "$rc" "5"
has "and it says up is not promoting" "$out" "up is not the same as promoting"

prssh "INTERVAL 300
APPLY 1
STATE "
out="$(run promote)"; rc=$?
check "a compose file declaring promote with no container at all is DOWN (5)" "$rc" "5"
has "and it says nothing is promoting" "$out" "nothing is promoting"

prssh "INTERVAL 300
APPLY 1
STATE running
LAST wtul-dexter-promote: cycle ok, not-a-date"  # A STAMP THAT WILL NOT PARSE IS NOT A STALE CYCLE: grading it DOWN would alarm about promote when the fault is this probe's reading of it
out="$(run promote)"; rc=$?
check "an unparseable cycle stamp is BLIND (6), never DOWN" "$rc" "6"

printf '#!/usr/bin/env bash\nexit 1\n' > "$TMP/stub/ssh"; chmod +x "$TMP/stub/ssh"

hygiene() { printf '#!/usr/bin/env bash\ncat <<'"'"'J'"'"'\n%s\nJ\n' "$1" > "$TMP/stub/curl"; chmod +x "$TMP/stub/curl"; }  # hygiene grades what monkey-status-collect.py already publishes (#706); ecosim#91 refused a CI grant onto 0700 self-dev homes, so the question is answered here instead, off the same published status arming reads
CLEAN='{"account":"a","uid":1,"containment":{"foreign_clones":[],"outside_home":[],"sudoers":[]},"credentials":{"claude_settings":"0o600"}}'

hygiene "{\"schema\":1,\"accounts\":[$CLEAN]}"
out="$(run hygiene)"; rc=$?
check "a status document older than schema 2 is BLIND (6)" "$rc" "6"
has "and names the schema" "$out" "schema 1"

hygiene '{"nonsense":true}'
out="$(run hygiene)"; rc=$?
check "a status document with no accounts is BLIND (6)" "$rc" "6"

hygiene "{\"schema\":2,\"accounts\":[$CLEAN]}"
out="$(run hygiene)"; rc=$?
check "clean containment and one shared credential shape is OK" "$rc" "0"

BAD_CLONE='{"account":"b","uid":2,"containment":{"foreign_clones":[{"path":"/home/b/Documents/Projects/x","origin":"https://github.com/hf7y/x.git"}],"outside_home":[],"sudoers":[]},"credentials":{"claude_settings":"0o600"}}'
hygiene "{\"schema\":2,\"accounts\":[$CLEAN,$BAD_CLONE]}"
out="$(run hygiene)"; rc=$?
check "an account with a foreign clone is DOWN (5)" "$rc" "5"
has "and it is named" "$out" "b"

BAD_SUDO='{"account":"c","uid":3,"containment":{"foreign_clones":[],"outside_home":[],"sudoers":["/etc/sudoers.d/c-extra"]},"credentials":{"claude_settings":"0o600"}}'
hygiene "{\"schema\":2,\"accounts\":[$CLEAN,$BAD_SUDO]}"
out="$(run hygiene)"; rc=$?
check "an account with an unexpected sudoers.d entry is DOWN (5)" "$rc" "5"
has "and it is named too" "$out" "c"

ODD_SHAPE='{"account":"d","uid":4,"containment":{"foreign_clones":[],"outside_home":[],"sudoers":[]},"credentials":{"claude_settings":"0o640"}}'
hygiene "{\"schema\":2,\"accounts\":[$CLEAN,$ODD_SHAPE]}"
out="$(run hygiene)"; rc=$?
check "one account off the shared credential shape is DOWN (5)" "$rc" "5"
has "and it says shapes differ, not which is 'right'" "$out" "distinct credential permission shapes"

NULL_CONTAINMENT='{"account":"e","uid":5,"containment":null,"credentials":{"claude_settings":"0o600"}}'
hygiene "{\"schema\":2,\"accounts\":[$CLEAN,$NULL_CONTAINMENT]}"
out="$(run hygiene)"; rc=$?
check "an account containment could not read is BLIND (6), not clean" "$rc" "6"
has "and it is named" "$out" "e"

hygiene "{\"schema\":2,\"accounts\":[$BAD_CLONE,$NULL_CONTAINMENT]}"
out="$(run hygiene)"; rc=$?
check "a real DOWN finding outranks an unrelated BLIND account" "$rc" "5"
has "and both are named" "$out" "b"
has "the unreadable account is named too, not silently dropped" "$out" "e"

echo
echo "-- hygiene: a SET of hosts, not a single default (#1139) -----------------"
# The stub differentiates by the HOST NAME IN THE URL curl was actually called
# with (.../<host>/status.json) -- the same idea as fleet_hosts's ssh-argument
# stub further below: BOTH members of the default fleet set get exercised, and
# one host unreachable (or unreadable) must read BLIND, never fold into the
# other's OK. The rows above all answered identically for every host (the
# stub ignores its argument), so they already proved grading survives being
# asked twice; these prove the CROSS-HOST aggregation itself.
hygiene_hosts() {  # hygiene_hosts <host> <exit> <body> [<host> <exit> <body> ...]
  rm -rf "$TMP/hygiene-hosts"; mkdir -p "$TMP/hygiene-hosts"
  while [ $# -gt 0 ]; do
    printf '%s' "$2" > "$TMP/hygiene-hosts/$1.exit"
    printf '%s' "$3" > "$TMP/hygiene-hosts/$1.out"
    shift 3
  done
  cat > "$TMP/stub/curl" <<STUB
#!/usr/bin/env bash
url="\${!#}"                  # curl is called "curl -s -m 20 <url>"
tmp="\${url%/status.json}"
host="\${tmp##*/}"
d="$TMP/hygiene-hosts"
[ -f "\$d/\$host.exit" ] || exit 1
[ -s "\$d/\$host.out" ] && cat "\$d/\$host.out"
exit "\$(cat "\$d/\$host.exit")"
STUB
  chmod +x "$TMP/stub/curl"
}

hygiene_hosts monkey    0 "{\"schema\":2,\"accounts\":[$CLEAN]}" \
              vaporwave 0 "{\"schema\":2,\"accounts\":[$CLEAN]}"
out="$(run hygiene)"; rc=$?
check "both hosts clean is OK (0)" "$rc" "0"

hygiene_hosts monkey    0 "{\"schema\":2,\"accounts\":[$CLEAN]}" \
              vaporwave 1 ""
out="$(run hygiene)"; rc=$?
check "one host in the set unreachable is BLIND (6), never folded into the other's OK" "$rc" "6"
has "and the unreachable host is named" "$out" "vaporwave"
hasnt "and it never reports the whole hygiene row as OK on a partial read" "$out" "OK      hygiene"

hygiene_hosts monkey    0 "{\"schema\":2,\"accounts\":[$CLEAN,$BAD_CLONE]}" \
              vaporwave 1 ""
out="$(run hygiene)"; rc=$?
check "a real DOWN finding on one host outranks the other host being unreachable" "$rc" "5"
has "and the finding is named" "$out" "b"
has "and the unreachable host is still named, not silently dropped" "$out" "vaporwave"

hygiene_hosts monkey    1 "" vaporwave 1 ""
out="$(run hygiene)"; rc=$?
check "both hosts unreachable is BLIND (6)" "$rc" "6"

hygiene_hosts monkey 0 "{\"schema\":2,\"accounts\":[$CLEAN]}"
out="$(AUSCULTE_FLEET_HOSTS=monkey run hygiene)"; rc=$?
check "AUSCULTE_FLEET_HOSTS overrides the set down to one host" "$rc" "0"

# --- propagation reads the channel's VERDICT, not the verb count ---------
# The count said OK through two days of a refusing cutter. curl/ssh stubbed.
verdict() { printf '#!/usr/bin/env bash\ncat <<'"'"'J'"'"'\n%s\nJ\n' "$1" > "$TMP/stub/curl"; chmod +x "$TMP/stub/curl"; }
fresh="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
old="$(date -u -d '-6 days' +%Y-%m-%dT%H:%M:%SZ)"

verdict "{\"decision\":\"ERROR\",\"blocked_streak\":3,\"cadence_hours\":24,\"grace_hours\":4,\"last_cut\":{\"at\":\"$old\",\"build_id\":\"B\"}}"
out="$(run propagation)"; rc=$?
check "a refusing channel is DOWN (5)" "$rc" "5"
has "and it names the decision and the date nothing has propagated since" "$out" "the channel is ERROR"

# BUILD AGE IS GRADED AGAINST THE CUT INTERVAL, NOT THE EMITTER CADENCE
# (#603). Under a 30-day interval the floor is 30d+28h, so the fixture has to
# be older than that to fail -- at -6d this row used to read DOWN, which is
# exactly the false alarm that would have fired on 29 nights in 30.
ancient="$(date -u -d '-40 days' +%Y-%m-%dT%H:%M:%SZ)"
verdict "{\"decision\":\"CUT\",\"build_id\":\"B\",\"blocked_streak\":0,\"cadence_hours\":24,\"grace_hours\":4,\"cut_interval_days\":30,\"last_cut\":{\"at\":\"$ancient\",\"build_id\":\"B\"}}"
out="$(run propagation)"; rc=$?
check "a build older than its CUT INTERVAL is DOWN (5)" "$rc" "5"
has "and it says the cutter has stopped, not that a cadence slipped" "$out" "the cutter has stopped"

# A DOCUMENT DECLARING NO INTERVAL IS A NIGHTLY ONE: cut_max_h collapses to
# max_h, so a schema-2 verdict grades exactly as it did before #603.
verdict "{\"decision\":\"CUT\",\"build_id\":\"B\",\"blocked_streak\":0,\"cadence_hours\":24,\"grace_hours\":4,\"last_cut\":{\"at\":\"$old\",\"build_id\":\"B\"}}"
out="$(run propagation)"; rc=$?
check "a schema-2 verdict with no cut_interval_days still grades at 28h (5)" "$rc" "5"

verdict "{\"decision\":\"CUT\",\"build_id\":\"B\",\"blocked_streak\":0,\"cadence_hours\":24,\"grace_hours\":4,\"last_cut\":{\"at\":\"$fresh\",\"build_id\":\"B\"}}"
out="$(run propagation)"; rc=$?
# BLIND, not DOWN: could-not-look is typed 6, and still not OK.
check "a fresh cut with an unreachable host is BLIND (6), never OK" "$rc" "6"
has "and the unreadable consumer is named" "$out" "could not read"

printf '#!/usr/bin/env bash\necho OLDBUILD\n' > "$TMP/stub/ssh"; chmod +x "$TMP/stub/ssh"
out="$(run propagation)"; rc=$?
check "a host behind a FRESH cut is OK -- it has not missed its window yet" "$rc" "0"
has "and the row still names who has not adopted" "$out" "not yet adopted by"

verdict "{\"decision\":\"CUT\",\"build_id\":\"B\",\"blocked_streak\":0,\"cadence_hours\":24,\"grace_hours\":4,\"last_cut\":{\"at\":\"$old\",\"build_id\":\"B\"}}"
out="$(run propagation)"; rc=$?
check "a host still behind a build past the window is DOWN (5)" "$rc" "5"

# A QUIET NIGHT IS NOT AN OUTAGE: 5 of the last 54 graded DOWN. NO_CHANGE
# publishes build_id "-", so the hosts are graded against last_cut.
printf '#!/usr/bin/env bash\necho /usr/local/share/verb-builds/B\n' > "$TMP/stub/ssh"
chmod +x "$TMP/stub/ssh"
verdict "{\"decision\":\"NO_CHANGE\",\"build_id\":\"-\",\"blocked_streak\":0,\"cadence_hours\":24,\"grace_hours\":4,\"last_cut\":{\"at\":\"$fresh\",\"build_id\":\"B\"}}"
out="$(run propagation)"; rc=$?
check "a NO_CHANGE night is healthy (0), not DOWN" "$rc" "0"
hasnt "and the channel is never called down for not moving" "$out" "the channel is NO_CHANGE"
has "and the hosts are graded against the last cut, not against \"-\"" "$out" "every host is on it"

verdict "{\"decision\":\"CUT\",\"build_id\":\"B\",\"blocked_streak\":0,\"cadence_hours\":24,\"grace_hours\":4,\"last_cut\":{\"at\":\"$fresh\",\"build_id\":\"B\"}}"
printf '#!/usr/bin/env bash\nexit 1\n' > "$TMP/stub/ssh"; chmod +x "$TMP/stub/ssh"

# No propagation-set reachable: BLIND, not a fleet of unreachable hosts.
mv "$TMP/bin/lib/propagation-set.sh" "$TMP/bin/lib/propagation-set.away"
out="$(run propagation)"; rc=$?
check "no propagation-set means BLIND, not unreachable hosts" "$rc" "6"
hasnt "and it never blames the hosts for a missing lib" "$out" "unreachable"
mv "$TMP/bin/lib/propagation-set.away" "$TMP/bin/lib/propagation-set.sh"

# THE MONTHLY CADENCE (#603). Kept at the END of this section on purpose: the
# rows above are order-dependent on which ssh stub is in place, and one that
# reaches the host half-way through changes what a later row measures.
printf '#!/usr/bin/env bash\necho /usr/local/share/verb-builds/B\n' > "$TMP/stub/ssh"; chmod +x "$TMP/stub/ssh"

# The behaviour change, and nothing pinned it before: a monthly channel
# mid-interval is healthy. Twenty days old, every host on it.
midcycle="$(date -u -d '-20 days' +%Y-%m-%dT%H:%M:%SZ)"
verdict "{\"decision\":\"NO_CHANGE\",\"build_id\":\"-\",\"blocked_streak\":0,\"cadence_hours\":24,\"grace_hours\":4,\"cut_interval_days\":30,\"last_cut\":{\"at\":\"$midcycle\",\"build_id\":\"B\"}}"
out="$(run propagation)"; rc=$?
check "a 20-day-old build under a 30-day interval is OK (0)" "$rc" "0"
has "and it says every host is on it" "$out" "every host is on it"

# THE ADOPTION BRANCH, REACHABLE FOR THE FIRST TIME. Before the split there
# was one number, so the build-age test returned DOWN first and the clause
# naming a host that failed to ADOPT could never be true -- a host that never
# took the build was reported as a channel-age problem instead. Here the build
# is well inside cut_max_h, so the only thing wrong is the host.
printf '#!/usr/bin/env bash\necho OLDBUILD\n' > "$TMP/stub/ssh"; chmod +x "$TMP/stub/ssh"
verdict "{\"decision\":\"CUT\",\"build_id\":\"B\",\"blocked_streak\":0,\"cadence_hours\":24,\"grace_hours\":4,\"cut_interval_days\":30,\"last_cut\":{\"at\":\"$old\",\"build_id\":\"B\"}}"
out="$(run propagation)"; rc=$?
check "a host that missed its adoption window under a healthy channel is DOWN (5)" "$rc" "5"
has "and the reason is ADOPTION, not the age of the build" "$out" "adoption window"

printf '#!/usr/bin/env bash\nexit 1\n' > "$TMP/stub/curl"; chmod +x "$TMP/stub/curl"
out="$(run propagation)"; rc=$?
check "an unreadable verdict is BLIND (6), never OK" "$rc" "6"
has "and it says it could not read the verdict" "$out" "cannot read the release channel verdict"

run nosuchprobe >/dev/null; check "an unknown probe is a usage error (2)" "$?" "2"

out="$(run channel)"; rc=$?
check "channel is DOWN (5) when no zaxon relay answers" "$rc" "5"
case "$out" in *"no zaxon relay answered"*) ok "...and it names why" ;;
  *) bad "channel DOWN detail" "got: $out" ;; esac

stub decision-rot.sh 0
out="$(run)"; rc=$?
check "a DOWN human channel is never folded into OK, even with everything else clean" "$rc" "5"
first="$(printf '%s\n' "$out" | awk 'NF{print $2; exit}')"
[ "$first" = "channel" ] && ok "the human channel is probed and reported first" \
  || bad "channel probed first" "first row named: $first"

# arming reads the PUBLISHED status, so it answers the same from any host.
printf '#!/usr/bin/env bash\necho called >> "%s/ssh_called"\nexit 255\n' "$TMP" > "$TMP/stub/ssh"
chmod +x "$TMP/stub/ssh"
out="$(run arming)"; rc=$?
check "an unreadable status document is BLIND (6)" "$rc" "6"
case "$out" in *"could not be read"*) ok "...and it names why" ;;
  *) bad "arming BLIND detail" "got: $out" ;; esac
[ -f "$TMP/ssh_called" ] \
  && bad "the arming probe never shells out to ssh" "ssh was invoked" \
  || ok "the arming probe never shells out to ssh"

expired="$(date -u -d '-2 days' +%Y-%m-%dT%H:%M:%SZ)"
status "{\"valid_until\":\"$expired\",\"accounts\":[{\"account\":\"a\",\"armed\":true,\"last_run\":{\"started_at\":\"$recent\"}}]}"
out="$(run arming)"; rc=$?
check "a status document past its own valid_until is BLIND (6)" "$rc" "6"
has "and it says nothing is publishing it" "$out" "expired at"

# The `delivery` and `silence` probes went with their scripts (#511);
# their cases went too, rather than being stubbed against a deleted probe.

echo
echo "-- fleet: the reason an account gives for stopping ---------------------"
# Pinned to ONE host for this whole block (#1139 added a second default host,
# vaporwave, to the fleet set): the ssh stub below answers identically for
# whichever host it is called with, so a second host would double every
# count these assertions pin exactly (e.g. "1 still working"). The multi-host
# set itself -- BOTH answering, and one UNREACHABLE reading BLIND rather than
# folding into the other's OK -- gets its own section right after this one.
export AUSCULTE_FLEET_HOSTS=monkey
fleet() { printf '#!/usr/bin/env bash\nprintf "%%s\\n" "%s"\nexit 0\n' "$1" > "$TMP/stub/ssh"; chmod +x "$TMP/stub/ssh"; }

fleet "2026-08-20	monkey	wtul	wtul	batch	0	DONE	fine
FLEET-LEDGERS 1"
out="$(run fleet)"; rc=$?
check "a fleet that finished its last run is OK (0)" "$rc" "0"

# NOT-DONE IS THE HEALTHY STATE, and this suite used to assert the opposite.
# The runner records NOT-DONE for an agent verdict of CONTINUE --
# schedule/_verdict-semantics.md, "there is ACTIONABLE work left". Measured
# 2026-08-22: 9 of 14 accounts read NOT-DONE and six had shipped a merged PR in
# that very run. The old assertion made this row DOWN whenever the fleet was
# working, which is the one failure a health verb may not have.
fleet "2026-08-20	monkey	wtul	wtul	batch	0	NOT-DONE	Landed PR #54 and closed #58; more in the queue
FLEET-LEDGERS 1"
out="$(run fleet)"; rc=$?
check "an account still working, and saying so, is OK (0) -- not DOWN" "$rc" "0"
has  "and the count of accounts still working is reported" "$out" "1 still working"

# A run the runner itself could get no verdict out of is the same silence as a
# blank reason: gardien and scheduler both read this way on 2026-08-22.
fleet "2026-08-20	monkey	gardien	gardien	batch	1	NOT-DONE	no-verdict: ran with no verdict written
FLEET-LEDGERS 1"
out="$(run fleet)"; rc=$?
check "a run that wrote no verdict is DOWN (5) -- the sensor got nothing" "$rc" "5"
has  "and it says so in the account's own words" "$out" "no-verdict"

fleet "2026-08-20	monkey	chezz	chezz	batch	3	NOT-DONE	
FLEET-LEDGERS 1"
out="$(run fleet)"; rc=$?
check "an account that stops without saying why is DOWN" "$rc" "5"
has  "and the silence is NAMED, not printed as an empty message" "$out" "NO REASON RECORDED"
has  "...and the headline counts the SILENT ones, not every NOT-DONE" "$out" "stopped without saying why"

# A GATE THAT CANNOT REACH THE API IS NOT A PACED FLEET -- same silence.
fleet "2026-08-20	monkey	wtul	wtul	batch	0	DONE	fine
FLEET-GATE-ERR realisateur 4
FLEET-LEDGERS 1"
out="$(run fleet)"; rc=$?
check "a gate ERRORing for 2+ ticks is DOWN (5), not a quiet fleet" "$rc" "5"
has  "and it says the accounts are not being held on purpose" "$out" "is being held on purpose"
has  "and it names the account and the count" "$out" "realisateur(4)"

fleet "2026-08-20	monkey	wtul	wtul	batch	0	DONE	fine
FLEET-GATE-ERR realisateur 1
FLEET-LEDGERS 1"
out="$(run fleet)"; rc=$?
check "a single gate error is not yet DOWN -- one tick is a hiccup" "$rc" "0"

fleet "2026-08-20	monkey	wtul	wtul	batch	0	DONE	fine
FLEET-PULL realisateur 3 fetch-failed 0
FLEET-LEDGERS 1"
out="$(run fleet)"; rc=$?
check "a checkout frozen 3+ ticks is DOWN (5); the runner will not self-heal" "$rc" "5"
has  "and says a merged fix cannot land" "$out" "cannot land"

fleet "2026-08-20	monkey	wtul	wtul	batch	0	DONE	fine
FLEET-PULL scheduler 2 dirty-tracked 0
FLEET-LEDGERS 1"
out="$(run fleet)"; rc=$?
check "a dirty-tracked freeze is DOWN (5) too, not just fetch-failed" "$rc" "5"
has  "and it names the cause, not only the count" "$out" "scheduler(2 dirty-tracked)"

fleet "2026-08-20	monkey	wtul	wtul	batch	0	DONE	fine
FLEET-PULL scheduler 1 dirty-tracked 0
FLEET-LEDGERS 1"
out="$(run fleet)"; rc=$?
check "one blocked tick is a blip, not a freeze" "$rc" "0"

# THE FALSE OK THIS PROBE WAS BORN WITH: it globbed a path no account had.
fleet "FLEET-LEDGERS 0"
out="$(run fleet)"; rc=$?
check "zero ledgers is BLIND (6), not a quiet fleet" "$rc" "6"
has  "and it says it cannot tell" "$out" "cannot tell"

printf '#!/usr/bin/env bash\nexit 1\n' > "$TMP/stub/ssh"; chmod +x "$TMP/stub/ssh"
out="$(run fleet)"; rc=$?
check "an unreachable host is BLIND (6)" "$rc" "6"

# ON THE HOST ITSELF, THERE IS NOTHING TO SSH TO. The cadence runs as root on
# monkey, where root has an empty authorized_keys and no known_hosts, so
# `ssh monkey` from monkey failed host key verification and this row was BLIND
# on the one machine holding the files. ssh stays stubbed FAILING here: if the
# local path were not taken the message would be the ssh fallback's.
printf '#!/usr/bin/env bash\nexit 1\n' > "$TMP/stub/ssh"; chmod +x "$TMP/stub/ssh"
out="$(PATH="$TMP/stub:$PATH" AUSCULTE_FLEET_HOSTS=selfhost SELFDEV_LOCAL_HOSTNAME=selfhost \
       bash "$TMP/bin/ausculte.sh" fleet 2>&1)"; rc=$?
check "reading its OWN host needs no ssh -- still BLIND here, but for the right reason" "$rc" "6"
has  "and the reason is an empty fleet, not an unreachable one" "$out" "no account has a paced-runner ledger"
hasnt "so the ssh fallback was never taken" "$out" "could not read the accounts"
unset AUSCULTE_FLEET_HOSTS

echo
echo "-- fleet: a SET of hosts, not a single default (#1139) -----------------"
# The stub differentiates by the host argument ssh was actually called with,
# so these assertions exercise BOTH members of the default fleet set.
# Per-host FILES, not one TSV row: the fixtures are multi-line ledger tails,
# and a "row" awk can print is one physical line -- a multi-line value in a
# line-oriented table silently truncated to its first line the first time
# this was tried.
fleet_hosts() {  # fleet_hosts <host> <exit> <output> [<host> <exit> <output> ...]
  rm -rf "$TMP/fleet-hosts"; mkdir -p "$TMP/fleet-hosts"
  while [ $# -gt 0 ]; do
    printf '%s' "$2" > "$TMP/fleet-hosts/$1.exit"
    printf '%s' "$3" > "$TMP/fleet-hosts/$1.out"
    shift 3
  done
  cat > "$TMP/stub/ssh" <<STUB
#!/usr/bin/env bash
host=""
while [ \$# -gt 0 ]; do
  case "\$1" in
    -o) shift 2 ;;              # "-o ConnectTimeout=10": an OPTION's VALUE is
    -*) shift ;;                # not itself dash-prefixed -- consume the pair
    *)  host="\$1"; break ;;
  esac
done
d="$TMP/fleet-hosts"
[ -f "\$d/\$host.exit" ] || exit 1
[ -s "\$d/\$host.out" ] && cat "\$d/\$host.out"
exit "\$(cat "\$d/\$host.exit")"
STUB
  chmod +x "$TMP/stub/ssh"
}

# SELFDEV_LOCAL_HOSTNAME pinned to a name in neither set: on_target_host's
# match is against the REAL hostname otherwise, and a runner whose own
# hostname happens to BE "monkey" would take the no-ssh-needed local path for
# that host and silently bypass the ssh stub these assertions depend on.
runh() { SELFDEV_LOCAL_HOSTNAME=test-runner run "$@"; }

fleet_hosts monkey    0 "2026-08-20	monkey	wtul	wtul	batch	0	DONE	fine
FLEET-LEDGERS 1" \
            vaporwave 0 "2026-08-20	vaporwave	wavebucks	wavebucks	batch	0	DONE	fine
FLEET-LEDGERS 1"
out="$(runh fleet)"; rc=$?
check "both hosts in the set answer OK, so the fleet is OK" "$rc" "0"
has "and BOTH hosts' accounts are counted, not just the first" "$out" "2 account(s) reported"

fleet_hosts monkey    0 "2026-08-20	monkey	wtul	wtul	batch	0	DONE	fine
FLEET-LEDGERS 1" \
            vaporwave 1 ""
out="$(runh fleet)"; rc=$?
check "one host in the set unreachable is BLIND (6), never folded into the other's OK" "$rc" "6"
has "and the unreachable host is NAMED, not silently dropped" "$out" "vaporwave"
has "and it says its state is not clean, not merely absent" "$out" "not clean"
hasnt "and it never reports the whole fleet as OK on a partial read" "$out" "OK      fleet"

fleet_hosts monkey    1 "" vaporwave 1 ""
out="$(runh fleet)"; rc=$?
check "both hosts unreachable is BLIND (6)" "$rc" "6"
has "and it says so plainly" "$out" "could not read the accounts paced-runner ledgers"

fleet_hosts monkey 0 "2026-08-20	monkey	wtul	wtul	batch	0	DONE	fine
FLEET-LEDGERS 1"
out="$(AUSCULTE_FLEET_HOSTS=monkey runh fleet)"; rc=$?
check "AUSCULTE_FLEET_HOSTS overrides the set down to one host" "$rc" "0"
has "and only that host's account is counted" "$out" "1 account(s) reported"

echo
echo "-- fatals: an abort with no ledger row at all ---------------------------"
runf() { PATH="$TMP/stub:$PATH" SELFDEV_LOCAL_HOSTNAME=not-monkey bash "$TMP/bin/ausculte.sh" "$@" 2>&1; }  # forced off "monkey": on the real host this account is itself uid 3000-3099 with a real sweep.log, and on_target_host would take the local-exec branch fleet's own test already covers
fatals() { printf '#!/usr/bin/env bash\nprintf "%%s\\n" "%s"\nexit 0\n' "$1" > "$TMP/stub/ssh"; chmod +x "$TMP/stub/ssh"; }
# AUSCULTE_FLEET_HOSTS pinned to monkey alone below: these assertions are
# about the single-host FATALS-CHECKED/-FOUND grammar, not fleet-set
# aggregation, which gets its own host-differentiated section further down
# (#1139) -- left at the real default (monkey vaporwave) there.

fatals "FATALS-CHECKED 3"
out="$(AUSCULTE_FLEET_HOSTS=monkey runf fatals)"; rc=$?
check "no account aborting is OK (0)" "$rc" "0"
has "and it names how many were checked" "$out" "3 account(s) checked"

fatals "FATALS-FOUND dcp-gate-site 69
FATALS-CHECKED 3"
out="$(AUSCULTE_FLEET_HOSTS=monkey runf fatals)"; rc=$?
check "an account hard-aborting every dispatch is DOWN (5)" "$rc" "5"
has "and it names the account and the count" "$out" "dcp-gate-site(69)"

fatals "FATALS-FOUND dcp-gate-site 69
FATALS-FOUND realisateur 56
FATALS-CHECKED 3"
out="$(AUSCULTE_FLEET_HOSTS=monkey runf fatals)"; rc=$?
check "two accounts aborting are both named, not just the first" "$rc" "5"
has "...dcp-gate-site" "$out" "dcp-gate-site(69)"
has "...and realisateur" "$out" "realisateur(56)"

fatals "FATALS-CHECKED 0"
out="$(AUSCULTE_FLEET_HOSTS=monkey runf fatals)"; rc=$?
check "no sweep.log readable for any account is BLIND (6), not a quiet fleet" "$rc" "6"
has "and it says it cannot tell" "$out" "cannot tell"

printf '#!/usr/bin/env bash\nexit 1\n' > "$TMP/stub/ssh"; chmod +x "$TMP/stub/ssh"
out="$(AUSCULTE_FLEET_HOSTS=monkey runf fatals)"; rc=$?
check "an unreachable host is BLIND (6)" "$rc" "6"

echo
echo "-- fatals: a SET of hosts, not a single default (#1139) -----------------"
# This probe landed (#1062) after fleet-hosts-set.sh existed and still asked
# only ${AUSCULTE_FLEET_HOST:-monkey} -- reusing fleet's own host-differentiated
# ssh stub (fleet_hosts, defined above) to prove the same fix applies here.
fleet_hosts monkey    0 "FATALS-CHECKED 3" \
            vaporwave 0 "FATALS-CHECKED 2"
out="$(runf fatals)"; rc=$?
check "both hosts in the set answer clean, so fatals is OK" "$rc" "0"
has "and BOTH hosts' checked counts are summed, not just the first" "$out" "5 account(s) checked"

fleet_hosts monkey    0 "FATALS-FOUND wtul 4
FATALS-CHECKED 3" \
            vaporwave 1 ""
out="$(runf fatals)"; rc=$?
check "an abort found on one host outranks the other host being unreachable -- DOWN (5), not BLIND" "$rc" "5"
has "and the found abort is named" "$out" "wtul(4)"
has "and the unreachable host is STILL named, not silently dropped" "$out" "UNREACHABLE"
has "...specifically vaporwave" "$out" "vaporwave"

fleet_hosts monkey    0 "FATALS-CHECKED 3" \
            vaporwave 1 ""
out="$(runf fatals)"; rc=$?
check "one host in the set unreachable (and the other clean) is BLIND (6), never folded into an OK" "$rc" "6"
has "and the unreachable host is named" "$out" "vaporwave"
has "and it says its state is not clean, not merely absent" "$out" "not clean"
hasnt "and it never reports the whole fatals row as OK on a partial read" "$out" "OK      fatals"

fleet_hosts monkey    1 "" vaporwave 1 ""
out="$(runf fatals)"; rc=$?
check "both hosts unreachable is BLIND (6)" "$rc" "6"
has "and it says so plainly" "$out" "could not read any account sweep.log on any host"

fleet_hosts monkey 0 "FATALS-CHECKED 3"
out="$(AUSCULTE_FLEET_HOSTS=monkey runf fatals)"; rc=$?
check "AUSCULTE_FLEET_HOSTS overrides the set down to one host" "$rc" "0"
has "and only that host's count is used" "$out" "3 account(s) checked"

echo
echo "-- fatals counts the CURRENT run, not the whole of history --------------"
# THE ROW MUST BE ABLE TO CLEAR. sweep.log is never rotated, so counting FATAL
# over the whole file latched this row DOWN for good: on 2026-09-16 it reported
# 25 aborts across 4 accounts, of which zero were current and the newest was 10
# days old. These run the program ausculte actually ships -- lifted out of the
# copied script rather than retyped, so the two cannot drift apart.
fatawk="$(grep -o 'awk "[^"]*END{print n+0}[^"]*"' "$TMP/bin/ausculte.sh" | head -1 | sed 's/^awk "//; s/"$//')"
[ -n "$fatawk" ] && ok "the FATAL counter can be lifted out of ausculte.sh" \
  || bad "the FATAL counter can be lifted out of ausculte.sh" "no awk program matched"
fatcount() { printf '%s\n' "$1" > "$TMP/sweep.log"; awk "$fatawk" "$TMP/sweep.log"; }

check "an abort in the CURRENT run still reads as aborting" "$(fatcount '=== 2026-09-16T05:37:10-05:00 ===
FATAL git fetch origin failed -- aborting rather than running against a stale base')" "1"

check "the same abort, once a later run completes, no longer counts" "$(fatcount '=== 2026-09-06T01:00:00-05:00 ===
FATAL git fetch origin failed -- aborting rather than running against a stale base
=== 2026-09-16T05:37:10-05:00 ===
=== done 2026-09-16T05:53:27-05:00 (975s) ===')" "0"

# sequestria's real shape on 2026-09-16: 19 lifetime FATALs, last run `done`.
check "19 historical aborts with a completed last run count zero" "$(fatcount '=== a ===
FATAL git fetch origin failed
=== b ===
FATAL git fetch origin failed
=== 2026-09-06T01:00:50-05:00 ===
COMPUTED VERDICT: WORKED -- pushed 3 commit(s)
=== done 2026-09-06T01:10:59-05:00 (609s) ===')" "0"

# vim-arcade's real shape: the last run ENDED, but on the turn ceiling. That is
# a completed dispatch, not an abort before one, and must not read as a FATAL.
check "a run that ends FAILED on the ceiling is not an abort" "$(fatcount '=== 2026-09-16T05:37:10-05:00 ===
COMPUTED VERDICT: WORKED-CUTOFF -- the run itself exited rc=1
=== FAILED (ceiling: max turns reached) 2026-09-16T05:53:27-05:00 (975s) ===')" "0"

# An abort BEFORE the run marker is written lands after the previous
# terminator, which is exactly the gap #1005 named. It must still be caught.
check "an abort before the next run marker is still caught" "$(fatcount '=== 2026-09-15T08:00:00-05:00 ===
=== done 2026-09-15T08:19:59-05:00 (1364s) ===
FATAL could not push salvage branch -- aborting before any claude work')" "1"

echo
echo "-- NOT-MINE: the containment boundary is not a failure -----------------"
# monkey is a WSL2 DISTRO on dexter. Holding shell on its own host is backwards,
# so root@monkey has an empty authorized_keys and no key -- and with only
# OK/DOWN/BLIND the `hosts` row could report that correct arrangement ONLY as
# BLIND: an alarm that can never clear, so its reader learns to ignore. Ashby S.8/7, the
# argument this file keeps making: a transducer with fewer output values than
# its input has distinct states loses distinctions.
stub decision-rot.sh 0
out="$(PATH="$TMP/stub:$PATH" SELFDEV_LOCAL_HOSTNAME=monkey bash "$TMP/bin/ausculte.sh" hosts 2>&1)"; rc=$?
case "$out" in *NOT-MINE*) ok "on the guest, hosts is NOT-MINE -- not BLIND" ;;
  *) bad "hosts is NOT-MINE on monkey" "got: $out" ;; esac
check "...and NOT-MINE is not an alarm: exit 0, neither 5 nor 6" "$rc" "0"
case "$out" in *monkey-watch*) ok "...and it NAMES who answers instead, so the question is not merely dropped" ;;
  *) bad "NOT-MINE names the owner" "got: $out" ;; esac

# A HOST OMITTED WITHOUT SAYING SO is how a partial answer reads as a complete
# one. Every propagation verdict has to carry the host it was not allowed to
# ask -- so the row needs a READABLE channel verdict to get that far, the same
# fixture the cut tests above use.
verdict "{\"decision\":\"CUT\",\"build_id\":\"B\",\"blocked_streak\":0,\"cadence_hours\":24,\"grace_hours\":4,\"last_cut\":{\"at\":\"$fresh\",\"build_id\":\"B\"}}"
out="$(PATH="$TMP/stub:$PATH" SELFDEV_LOCAL_HOSTNAME=monkey bash "$TMP/bin/ausculte.sh" propagation 2>&1)"
case "$out" in *"not asked from here"*) ok "propagation names the host it did not ask, so a partial answer cannot read as a complete one" ;;
  *) bad "propagation names the skipped host" "got: $out" ;; esac
case "$out" in *dexter*) ok "...and names WHICH host, not just that one was skipped" ;;
  *) bad "the skipped host is named" "got: $out" ;; esac

# Off the guest, nothing changes: mandark still asks dexter directly.
out="$(PATH="$TMP/stub:$PATH" SELFDEV_LOCAL_HOSTNAME=mandark bash "$TMP/bin/ausculte.sh" hosts 2>&1)"
case "$out" in *NOT-MINE*) bad "off-guest hosts still probes dexter" "it went NOT-MINE on mandark" ;;
  *) ok "off the guest the row still answers about dexter -- the boundary is monkey's, not everyone's" ;; esac

fresh_vu="$(date -u -d '+1 hour' +%Y-%m-%dT%H:%M:%SZ)"
status "{\"accounts\":[],\"watcher\":{\"verdict\":\"OK\",\"why\":\"running, sshd answering\",\"valid_until\":\"$fresh_vu\"}}"
out="$(PATH="$TMP/stub:$PATH" SELFDEV_LOCAL_HOSTNAME=mandark SELFDEV_LIBEXEC="$TMP/no-libexec" bash "$TMP/bin/ausculte.sh" hosts 2>&1)"; rc=$?
check "a fresh published OK verdict makes hosts OK (0), not BLIND" "$rc" "0"
has "and it credits monkey-watch, not a local probe" "$out" "monkey-watch"

status "{\"accounts\":[],\"watcher\":{\"verdict\":\"DOWN\",\"why\":\"VM running but sshd is silent\",\"valid_until\":\"$fresh_vu\"}}"
out="$(PATH="$TMP/stub:$PATH" SELFDEV_LOCAL_HOSTNAME=mandark SELFDEV_LIBEXEC="$TMP/no-libexec" bash "$TMP/bin/ausculte.sh" hosts 2>&1)"; rc=$?
check "a published DOWN verdict makes hosts DOWN (5) -- the outage ausculte used to miss entirely" "$rc" "5"
has "and it carries the watcher's own reason" "$out" "sshd is silent"

status "{\"accounts\":[],\"watcher\":{\"verdict\":\"OK\",\"valid_until\":\"$expired\"}}"
out="$(PATH="$TMP/stub:$PATH" SELFDEV_LOCAL_HOSTNAME=mandark SELFDEV_LIBEXEC="$TMP/no-libexec" bash "$TMP/bin/ausculte.sh" hosts 2>&1)"; rc=$?
check "a hosts verdict past its own valid_until is BLIND (6), not a stale OK" "$rc" "6"
has "and it names the expiry, same as arming" "$out" "expired at"

printf '#!/usr/bin/env bash\nexit 1\n' > "$TMP/stub/curl"; chmod +x "$TMP/stub/curl"
out="$(PATH="$TMP/stub:$PATH" SELFDEV_LOCAL_HOSTNAME=mandark SELFDEV_LIBEXEC="$TMP/no-libexec" bash "$TMP/bin/ausculte.sh" hosts 2>&1)"; rc=$?
check "no readable status document is BLIND (6)" "$rc" "6"
has "and it says nothing else measures dexter" "$out" "nothing else measures dexter"

echo
echo "-- --cadence: folded in from the retired ausculte-cadence.sh (#894) ----"
# Hermetic the same way: AUSCULTE_BIN still overrides what --cadence shells
# out to for its rows, only now that target can be ausculte.sh itself.
CADSTATE="$TMP/cadstate"
stub_cad_json() { # <json> [exit]
  printf '#!/usr/bin/env bash\ncat <<%s\n%s\n%s\nexit %s\n' "JSON" "$1" "JSON" "${2:-0}" > "$TMP/bin/cad-source.sh"
  chmod +x "$TMP/bin/cad-source.sh"
}
runcad() { OUT="$(PATH="$TMP/stub:$PATH" AUSCULTE_BIN="$TMP/bin/cad-source.sh" \
                  AUSCULTE_CADENCE_STATE="$CADSTATE" \
                  bash "$TMP/bin/ausculte.sh" --cadence 2>&1)"; RC=$?; }

DOWN_ROW='[{"probe":"arming","status":"DOWN","detail":"two accounts stopped"}]'
OK_ROW='[{"probe":"arming","status":"OK","detail":"all dispatching"}]'

section "cadence A. a DOWN row is reported and recorded"
rm -rf "$CADSTATE"; stub_cad_json "$DOWN_ROW"
runcad
check "A1 exit 5 -- a DOWN row is DOWN on the first reading, not the second" "$RC" "5"
has "A2 it names the row and its detail" "$OUT" "arming"
[ -f "$CADSTATE/arming.down" ] && ok "A3 the state is on disk, so a later reader can date it" \
  || bad "A3 the state is on disk" "no state file"

section "cadence B. the record is a SINCE, not a counter"
touch -d '2001-01-01T00:00:00Z' "$CADSTATE/arming.down"
runcad
check "B1 still DOWN, still exit 5" "$RC" "5"
_m="$(date -u -r "$CADSTATE/arming.down" +%Y 2>/dev/null)"
[ "$_m" = 2001 ] && ok "B2 a persisting state does not rewrite its own timestamp" \
  || bad "B2 a persisting state keeps its timestamp" "mtime year is now [$_m]"
has "B3 and the row is reported as having held since then" "$OUT" "since 2001-01-01"

section "cadence C. a recovery clears the record"
stub_cad_json "$OK_ROW"
runcad
check "C1 exit 0" "$RC" "0"
[ -f "$CADSTATE/arming.down" ] && bad "C2 the record is cleared" "state file survived" \
  || ok "C2 the record is cleared"
stub_cad_json "$DOWN_ROW"
runcad
has "C3 the next DOWN dates from now, not from the cleared record" "$OUT" "since now"

section "cadence D. BLIND from the source is BLIND here"
stub_cad_json '[{"probe":"hosts","status":"BLIND","detail":"cannot reach dexter"}]'
runcad
check "D1 a BLIND row is not DOWN and not OK" "$RC" "0"
[ -f "$CADSTATE/hosts.blind" ] && ok "D2 BLIND keeps its own record, never the DOWN one" \
  || bad "D2 BLIND keeps its own record" "no hosts.blind"
[ -f "$CADSTATE/hosts.down" ] && bad "D3 a BLIND row never writes the DOWN record" "hosts.down exists" \
  || ok "D3 a BLIND row never writes the DOWN record"

section "cadence E. a non-array answer is BLIND, never 'no rows'"
printf '#!/usr/bin/env bash\nprintf "not json\\n"\nexit 0\n' > "$TMP/bin/cad-source.sh"
chmod +x "$TMP/bin/cad-source.sh"
runcad
check "E1 exit 6" "$RC" "6"
has "E2 it says it produced no rows" "$OUT" "no rows"

section "cadence E2. mints a credential when it has none"
printf '#!/usr/bin/env bash\n[ "$1" = --token ] && printf "ghs_fixturetoken\\n"\n' > "$TMP/bin/mint.sh"
chmod +x "$TMP/bin/mint.sh"
printf '#!/usr/bin/env bash\nprintf "[{\\"probe\\":\\"rot\\",\\"status\\":\\"OK\\",\\"detail\\":\\"%%s\\"}]\\n" "$GH_TOKEN"\n' > "$TMP/bin/cad-source.sh"
chmod +x "$TMP/bin/cad-source.sh"
OUT="$(PATH="$TMP/stub:$PATH" AUSCULTE_BIN="$TMP/bin/cad-source.sh" AUSCULTE_CADENCE_STATE="$CADSTATE" \
       SELFDEV_APP_MINT="$TMP/bin/mint.sh" GH_TOKEN='' GITHUB_TOKEN='' \
       bash "$TMP/bin/ausculte.sh" --cadence 2>&1)"
has "E2a the minted token reaches the probes" "$OUT" "ghs_fixturetoken"

OUT="$(PATH="$TMP/stub:$PATH" AUSCULTE_BIN="$TMP/bin/cad-source.sh" AUSCULTE_CADENCE_STATE="$CADSTATE" \
       SELFDEV_APP_MINT="$TMP/bin/mint.sh" GH_TOKEN=ghs_alreadyhere \
       bash "$TMP/bin/ausculte.sh" --cadence 2>&1)"
has "E2b an existing credential is not replaced" "$OUT" "ghs_alreadyhere"

section "cadence F. --install-cadence writes nothing without --apply"
before="$(crontab -l 2>/dev/null | md5sum)"
OUT="$(bash "$TMP/bin/ausculte.sh" --install-cadence 2>&1)"; RC=$?
has "F1 it prints the line it would install" "$OUT" "realisateur:ausculte:CADENCE"
has "...naming --cadence, not the retired standalone script" "$OUT" "--cadence"
eq "F2 the crontab is untouched" "$(crontab -l 2>/dev/null | md5sum)" "$before"

section "cadence G. it files nothing at anybody, and reaches no human on its own"
# Same guard #894 carried over from ausculte-cadence.sh: 47 zaxon questions
# sent/0 answered, 10 issues/5 days over 5 rows, both cut for cause. The
# `channel` probe still legitimately reaches zaxon (it is what answers
# "can Zach be reached at all") -- what must stay gone is the CADENCE layer
# escalating on its own, so the check is for zaxon_ask/issue-create/-close
# specifically, not for zaxon.sh being sourced anywhere in the file.
cat > "$TMP/bin/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GH_LOG"
case "$*" in *"issue list"*) echo 654 ;; esac
exit 0
STUB
chmod +x "$TMP/bin/gh"
ghruncad() { OUT="$(PATH="$TMP/stub:$PATH" GH_LOG="$TMP/gh.log" \
                    AUSCULTE_BIN="$TMP/bin/cad-source.sh" AUSCULTE_CADENCE_STATE="$CADSTATE" \
                    bash "$TMP/bin/ausculte.sh" --cadence 2>&1)"; RC=$?; }

: > "$TMP/gh.log"; rm -f "$CADSTATE"/*.down "$CADSTATE"/*.blind
stub_cad_json "$DOWN_ROW"
ghruncad; ghruncad
check "G1 a row DOWN twice running still exits 5" "$RC" "5"
case "$(cat "$TMP/gh.log")" in
  *"issue create"*) bad "G2 no issue is ever created" "it called gh issue create" ;;
  *)                ok  "G2 no issue is ever created" ;;
esac

: > "$TMP/gh.log"
stub_cad_json "$OK_ROW"
ghruncad
check "G3 a recovery exits 0" "$RC" "0"
case "$(cat "$TMP/gh.log")" in
  *"issue close"*) bad "G4 no issue is ever closed" "it called gh issue close" ;;
  *)               ok  "G4 no issue is ever closed" ;;
esac

live="$(grep -vE '^[[:space:]]*#' "$HERE/../ausculte.sh")"
case "$live" in
  *zaxon_ask*) bad "H1 no live call to zaxon_ask" "it is back -- 47 sent, 0 answered" ;;
  *)           ok  "H1 no live call to zaxon_ask" ;;
esac
case "$live" in
  *"issue create"*) bad "H2 the issue-filing leg is gone from the source too" "gh issue create is back" ;;
  *)                ok  "H2 the issue-filing leg is gone from the source too" ;;
esac
has "H3 a DOWN row still exits 5, so a caller can still see it" "$live" 'exit 5'

section "I. routes -- the port carries the identity at dexter's address (#1189)"
# The distros share ONE network namespace and Windows sshd holds 22, so an
# alias that omits Port does not fail: it reaches a REAL sshd on the WRONG
# host, and the refusal reads as a broken key. hf7y/wtul#131 lost three days
# concluding "dexter's sshd rejects restrict/command=" from exactly that.
ADDR=dexter.tail893f2c.ts.net
# A stub `ssh -G` so this stays offline. It answers from the fixture, which is
# all the probe reads.
cat > "$TMP/stub/ssh" <<'SSHSTUB'
#!/usr/bin/env bash
conf=""; alias=""
while [ $# -gt 0 ]; do
  case "$1" in
    -G) ;;
    -F) shift; conf="$1" ;;
    -*) ;;
    *)  alias="$1" ;;
  esac
  shift
done
awk -v want="$alias" '
  tolower($1)=="host" { inblk=0; for(i=2;i<=NF;i++) if ($i==want) inblk=1; next }
  inblk && tolower($1)=="hostname" { h=$2 }
  inblk && tolower($1)=="port"     { p=$2 }
  END { printf "hostname %s\nport %s\n", (h?h:want), (p?p:22) }
' "$conf"
SSHSTUB
chmod +x "$TMP/stub/ssh"

routes() { SSH_ROUTE_CONFIG="$1" run routes; }

# I1-I3: wtul#131's block exactly as it shipped -- five lines copied from
# ocf-chezz-deploy, where port 22 IS correct.
printf 'Host dexter-staging\n  HostName %s\n  User zach\n' "$ADDR" > "$TMP/portless"
out="$(routes "$TMP/portless")"; rc=$?
check "I1 a portless alias at that address is DOWN (5), not a route that quietly reaches Windows" "$rc" "5"
case "$out" in *"WINDOWS sshd"*) ok "I2 ...and it names what :22 actually is, so the key is not retried" ;;
  *) bad "I2 names the Windows sshd" "got: $out" ;; esac
case "$out" in *"2223=dexter"*) ok "I3 ...and hands over the ports rather than making the reader look them up" ;;
  *) bad "I3 names the ports" "got: $out" ;; esac

printf 'Host dexter-staging\n  HostName %s\n  Port 2223\nHost vaporwave\n  HostName %s\n  Port 2225\n' "$ADDR" "$ADDR" > "$TMP/portful"
out="$(routes "$TMP/portful")"; rc=$?
check "I4 naming the port is OK (0)" "$rc" "0"
case "$out" in *"2 ssh alias(es)"*) ok "I5 ...and it says how many it actually looked at" ;;
  *) bad "I5 counts the aliases" "got: $out" ;; esac

printf 'Host somewhere\n  HostName %s\n  Port 2299\n' "$ADDR" > "$TMP/unknownport"
out="$(routes "$TMP/unknownport")"; rc=$?
check "I6 a port nothing is declared on is a finding, not a silent pass" "$rc" "5"
case "$out" in *"fleet-hosts-set.sh"*) ok "I7 ...and it says which file declares the map" ;;
  *) bad "I7 names the map" "got: $out" ;; esac

# ocf-chezz-deploy is the block dexter-staging was copied FROM, and :22 is
# right there. A check that flagged it would be trained away within a week.
printf 'Host ocf-chezz-deploy\n  HostName tsunami.ocf.berkeley.edu\n  User pine\n' > "$TMP/elsewhere"
out="$(routes "$TMP/elsewhere")"; rc=$?
check "I8 an alias at a DIFFERENT address is none of this probe's business" "$rc" "0"
case "$out" in *ocf-chezz-deploy*) bad "I9 it is not even mentioned" "got: $out" ;;
  *) ok "I9 ...and it is not even mentioned" ;; esac

printf 'Host *\n  ServerAliveInterval 30\nHost dexter\n  HostName %s\n  Port 2223\n' "$ADDR" > "$TMP/wild"
out="$(routes "$TMP/wild")"; rc=$?
check "I10 a wildcard Host is a pattern, not a route -- skipped, not flagged" "$rc" "0"

out="$(routes "$TMP/does-not-exist")"; rc=$?
check "I11 no ssh config is BLIND (6), never a quiet OK" "$rc" "6"

rm -f "$TMP/stub/ssh"
printf '#!/usr/bin/env bash\nexit 1\n' > "$TMP/stub/ssh"; chmod +x "$TMP/stub/ssh"

section "J. the port map is a declaration, one file, and 22 is IN it"
. "$HERE/../lib/fleet-hosts-set.sh"
check "J1 22 is declared, so defaulting to it reads WRONG not merely unlisted" "$(ssh_netns_host_at 22)" "windows"
check "J2 2223 is dexter's WSL2" "$(ssh_netns_host_at 2223)" "dexter"
# 2224 WAS monkey, unregistered 2026-09-24. A port whose host is gone must not
# keep resolving: an alias pointed at it is a route to nothing, not to monkey.
if ssh_netns_host_at 2224 >/dev/null 2>&1; then bad "J3 2224 must not resolve -- monkey is deleted"; else ok "J3 2224 resolves to nothing, monkey having been deleted"; fi
check "J4 2225 is vaporwave" "$(ssh_netns_host_at 2225)" "vaporwave"
check "J5 the reverse lookup ausculte's propagation probe uses agrees" "$(ssh_netns_port_for dexter)" "2223"
if ssh_netns_host_at 9999 >/dev/null 2>&1; then bad "J6 an undeclared port must not resolve"; else ok "J6 an undeclared port does not resolve"; fi

summary
