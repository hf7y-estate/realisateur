#!/usr/bin/env bash
# SUBJECT: bin/lib/ausculte-owner.tsv, and the property it exists to hold --
# EVERY PROBE CAN GET BACK TO OK.
#
# WHY THIS IS A SUITE AND NOT A PARAGRAPH (hf7y/realisateur#1207). A row that
# cannot clear is not an alarm, it is furniture: `fatals` counted FATAL over a
# never-rotated sweep.log and held DOWN on 25 aborts of which none were current
# (#1204), and the vault row could not clear until #1164 (#1206). Both were
# found by hand, in one afternoon, by accident. Unarmed that costs a human
# glance. Armed -- and bin/ausculte.sh --cadence files now -- a latched row IS
# the 10-issues-in-5-days failure that got the previous filing leg cut.
#
# So each probe below is driven DOWN (or BLIND) and then OK, hermetically:
# curl, ssh and gh are stubbed, and every composed probe is a stub. The pair is
# the claim. A probe that can only be made to fail does not appear here as a
# passing row -- it does not appear at all, which is what section A catches.
set -uo pipefail
. "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib/harness.sh"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$HERE/.."
TSV="$SRC/lib/ausculte-owner.tsv"
harness_tmp
mkdir -p "$T/bin/lib" "$T/stub"
cp "$SRC/ausculte.sh" "$T/bin/"
for l in cli-guard part host-check zaxon propagation-set estate-set cron-lock \
         fleet-hosts-set roster-set; do cp "$SRC/lib/$l.sh" "$T/bin/lib/"; done
for c in curl ssh gh; do printf '#!/usr/bin/env bash\nexit 1\n' > "$T/stub/$c"; chmod +x "$T/stub/$c"; done

# Off monkey for every row: on the real host `hosts`, `pullable`, `promote` and
# `propagation` take their NOT-MINE / local branches, and NOT-MINE is neither
# of the two states this suite is pairing.
run() { PATH="$T/stub:$PATH" SELFDEV_LOCAL_HOSTNAME=mandark \
        AUSCULTE_FLEET_HOSTS=monkey bash "$T/bin/ausculte.sh" "$@" >/dev/null 2>&1; }
part_stub() { printf '#!/usr/bin/env bash\nprintf "%%s\\n" "%s"\nexit %s\n' "${3:-}" "$2" > "$T/bin/$1"; chmod +x "$T/bin/$1"; }
curl_json() { printf '#!/usr/bin/env bash\ncat <<'"'"'J'"'"'\n%s\nJ\n' "$1" > "$T/stub/curl"; chmod +x "$T/stub/curl"; }
curl_rc()   { printf '#!/usr/bin/env bash\nexit %s\n' "$1" > "$T/stub/curl"; chmod +x "$T/stub/curl"; }
ssh_out()   { printf '#!/usr/bin/env bash\ncat <<'"'"'R'"'"'\n%s\nR\n' "$1" > "$T/stub/ssh"; chmod +x "$T/stub/ssh"; }
ssh_rc()    { printf '#!/usr/bin/env bash\nexit %s\n' "$1" > "$T/stub/ssh"; chmod +x "$T/stub/ssh"; }

# broke <probe> <label>  -- the fixtures are already in place; 5 DOWN, 6 BLIND.
# clear <probe> <label>  -- and now it reads OK. The PAIR is what is asserted:
# either half alone proves nothing about whether the row can move.
broke() { run "$1"; case "$?" in 5|6) ok "$2" ;; *) bad "$2" "wanted DOWN or BLIND, got exit $?" ;; esac; }
clear() { run "$1"; case "$?" in 0) ok "$2" ;; *) bad "$2" "wanted OK, got exit $?" ;; esac; }

section "A. the table names every probe, and every row can be acted on"
# The list comes from ausculte.sh itself, never a second copy: a probe added
# without a destination is the finding, and a hand-kept list cannot see one.
probes="$(grep -oE '^if want [a-z_]+' "$SRC/ausculte.sh" | awk '{print $3}' | sort -u | tr '\n' ' ')"
[ -n "$probes" ] && ok "A1 the probe list is read out of ausculte.sh" \
  || bad "A1 the probe list is read out of ausculte.sh" "grep found no probes"

rows="$(grep -vE '^[[:space:]]*(#|$)' "$TSV")"
for p in $probes; do
  row="$(printf '%s\n' "$rows" | awk -F'\t' -v p="$p" '$1 == p {print; exit}')"
  if [ -z "$row" ]; then
    bad "A2 $p has a row in ausculte-owner.tsv" "no row -- a DOWN $p row has nowhere to go"
    continue
  fi
  IFS=$'\t' read -r _p owner route after clears <<<"$row"
  case "$route" in
    agent|human) [ "$owner" = from-detail ] || case "$owner" in */*) ;; *)
        bad "A3 $p names a repo or from-detail" "route $route with owner_repo [$owner]" ;; esac ;;
    zaxon-only) [ "$owner" = '--' ] \
        || bad "A3 $p files nothing, so it names no repo" "route zaxon-only with owner_repo [$owner]" ;;
    *) bad "A3 $p declares a known route" "route [$route] is not agent/human/zaxon-only" ;;
  esac
  case "$after" in ''|*[!0-9]*) bad "A4 $p declares escalate_after in ticks" "got [$after]" ;;
    *) [ "$after" -ge 1 ] || bad "A4 $p waits at least one tick" "escalate_after is $after" ;; esac
  # THE PHASE 1 COLUMN. Without it nothing states what would end the alarm, and
  # "is this row latched?" is answerable only by reading the probe's source.
  [ -n "$clears" ] && ok "A5 $p says what would put it back to OK" \
    || bad "A5 $p says what would put it back to OK" "clears_when is empty"
done

# And no row for a probe that does not exist: a destination for a finding that
# cannot arrive reads as coverage and is not.
while IFS=$'\t' read -r p _rest; do
  [ -n "$p" ] || continue
  case " $probes " in *" $p "*) ;;
    *) bad "A6 every row names a probe ausculte emits" "$TSV has a row for [$p], which ausculte does not probe" ;;
  esac
done <<<"$rows"
ok "A6 every row names a probe ausculte emits"

section "B. every probe reaches OK from broken"

# channel -- the relay answers, or it does not.
curl_rc 1; broke channel "B1 channel is DOWN with no relay"
curl_rc 0; clear channel "B1 ...and OK when one answers"

# hosts -- the published monkey-watch verdict, from dexter.
future="$(date -u -d '+1 hour' +%Y-%m-%dT%H:%M:%SZ)"
curl_json "{\"watcher\":{\"verdict\":\"BAD\",\"valid_until\":\"$future\",\"why\":\"a unit is dead\"}}"
broke hosts "B2 hosts is DOWN on a bad published verdict"
curl_json "{\"watcher\":{\"verdict\":\"OK\",\"valid_until\":\"$future\"}}"
clear hosts "B2 ...and OK once dexter publishes OK inside its own freshness"

# routes -- the port at dexter's address is what selects the host.
ADDR=dexter.tail893f2c.ts.net
cat > "$T/stub/ssh" <<'SSHSTUB'
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
chmod +x "$T/stub/ssh"
printf 'Host dexter-staging\n  HostName %s\n  User zach\n' "$ADDR" > "$T/portless"
SSH_ROUTE_CONFIG="$T/portless" run routes; rc=$?
[ "$rc" = 5 ] && ok "B3 routes is DOWN on an alias that omits the port" \
  || bad "B3 routes is DOWN on an alias that omits the port" "got exit $rc"
printf 'Host dexter-staging\n  HostName %s\n  Port 2223\n' "$ADDR" > "$T/portful"
SSH_ROUTE_CONFIG="$T/portful" run routes; rc=$?
[ "$rc" = 0 ] && ok "B3 ...and OK once it names the port that selects dexter" \
  || bad "B3 ...and OK once it names the port" "got exit $rc"
ssh_rc 1

# arming -- what the accounts did, off the published status.
recent="$(date -u -d '-1 hour' +%Y-%m-%dT%H:%M:%SZ)"
stale="$(date -u -d '-9 days' +%Y-%m-%dT%H:%M:%SZ)"
curl_json "{\"accounts\":[{\"account\":\"a\",\"armed\":true,\"last_run\":{\"started_at\":\"$stale\"}}]}"
broke arming "B4 arming is DOWN on an armed account that stopped dispatching"
curl_json "{\"accounts\":[{\"account\":\"a\",\"armed\":true,\"last_run\":{\"started_at\":\"$recent\"}}]}"
clear arming "B4 ...and OK once it dispatches again"

# roster_read -- the arming AUTHORITY, not what the accounts did with it.
curl_json '{"roster_read":false,"accounts":[{"account":"a","armed":true,"roster_state":null}]}'
broke roster_read "B5 roster_read is DOWN when the collector could not read the authority"
curl_json '{"roster_read":true,"accounts":[{"account":"a","armed":true,"roster_state":"live"}]}'
clear roster_read "B5 ...and OK once it can"

# pullable -- can a rebuilt dexter recover from its compose files alone?
pullssh() {  # <image lines> <docker rc> [<first stderr line>]
  { printf '#!/usr/bin/env bash\n'
    printf 'case "$*" in *docker*) while IFS= read -r l; do printf "%%s\\t%%s\\t%%s\\n" %q "$l" %q; done; exit 0 ;; esac\n' "$2" "${3:-}"
    printf 'cat <<'"'"'R'"'"'\n%s\nR\n' "$1"
  } > "$T/stub/ssh"; chmod +x "$T/stub/ssh"; }
pullssh 'groc-browser:local' 1 'pull access denied for groc-browser'
broke pullable "B6 pullable is DOWN on an image no registry serves"
pullssh 'ghcr.io/hf7y/roster:latest' 0
clear pullable "B6 ...and OK once every declared image resolves"

# promote -- cycling, not merely up.
now="$(date -u +%FT%TZ)"
ssh_out "INTERVAL 300
APPLY 1
STATE exited"
broke promote "B7 promote is DOWN with the container stopped"
ssh_out "INTERVAL 300
APPLY 1
STATE running
LAST wtul-dexter-promote: cycle ok, $now"
clear promote "B7 ...and OK once it logs a completed cycle inside its interval"
ssh_rc 1

# hygiene -- containment and credential shape, off the same published status.
CLEAN='{"account":"a","uid":1,"containment":{"foreign_clones":[],"outside_home":[],"sudoers":[]},"credentials":{"claude_settings":"0o600"}}'
DIRTY='{"account":"b","uid":2,"containment":{"foreign_clones":[{"path":"/home/b/x","origin":"https://github.com/hf7y/x.git"}],"outside_home":[],"sudoers":[]},"credentials":{"claude_settings":"0o600"}}'
curl_json "{\"schema\":2,\"accounts\":[$CLEAN,$DIRTY]}"
broke hygiene "B8 hygiene is DOWN on an account holding a foreign clone"
curl_json "{\"schema\":2,\"accounts\":[$CLEAN]}"
clear hygiene "B8 ...and OK once every account is contained and shares one credential shape"

# propagation -- the channel's verdict, then who adopted the build.
fresh="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
curl_json "{\"decision\":\"ERROR\",\"blocked_streak\":3,\"cadence_hours\":24,\"grace_hours\":4,\"last_cut\":{\"at\":\"$fresh\",\"build_id\":\"B\"}}"
broke propagation "B9 propagation is DOWN with the channel refusing"
ssh_out '/usr/local/share/verb-builds/B'
curl_json "{\"decision\":\"CUT\",\"build_id\":\"B\",\"blocked_streak\":0,\"cadence_hours\":24,\"grace_hours\":4,\"last_cut\":{\"at\":\"$fresh\",\"build_id\":\"B\"}}"
clear propagation "B9 ...and OK once it cuts and every host pin is on the cut"
ssh_rc 1

# rot / landing / unarmed / handoff -- composed probes, graded by exit code.
part_stub decision-rot.sh 1 "answered and still open"
broke rot "B10 rot is DOWN with an answered decision still open"
part_stub decision-rot.sh 0
clear rot "B10 ...and OK once none is"

part_stub landing-drift.sh 1 "realisateur 3 2026-09-01 x stranded"
broke landing "B11 landing is DOWN with green work unlanded"
part_stub landing-drift.sh 0
clear landing "B11 ...and OK once every repo can land what it opens"

part_stub unarmed.sh 1 "EXPIRED promote-witness"
broke unarmed "B12 unarmed is DOWN with a row past its own window"
part_stub unarmed.sh 0
clear unarmed "B12 ...and OK once the floor holds"

part_stub reprise.sh 1 "reprise: hf7y/senechal#4 MERGED but the deletion it owes is outstanding"
broke handoff "B13 handoff is DOWN with a merged handoff uncollected"
part_stub reprise.sh 0 "reprise: 0 rows collectable"
clear handoff "B13 ...and OK once nothing is outstanding"

# fleet -- the reason an account gives for stopping.
ssh_out "2026-08-20	monkey	wtul	wtul	batch	0	DONE	fine
FLEET-GATE-ERR realisateur 4
FLEET-LEDGERS 1"
broke fleet "B14 fleet is DOWN with the usage gate erroring"
ssh_out "2026-08-20	monkey	wtul	wtul	batch	0	DONE	fine
FLEET-LEDGERS 1"
clear fleet "B14 ...and OK once the gate paces again"

# fatals -- a hard abort before `claude` starts writes no ledger row at all.
ssh_out "FATALS-FOUND dcp-gate-site 69
FATALS-CHECKED 3"
broke fatals "B15 fatals is DOWN with an account aborting every dispatch"
ssh_out "FATALS-CHECKED 3"
clear fatals "B15 ...and OK once none has aborted since its last run marker"

summary
