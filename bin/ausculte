#!/usr/bin/env bash
# ausculte.sh -- can Zach stop looking? Composed from probes that already exist.
# KIND: verb
# THE HUMAN CHANNEL IS FIRST: every other failure reaches Zach through zaxon,
# so a green report with zaxon down reaches nobody. BLIND never folds into OK.
set -uo pipefail

CLI_NAME='ausculte.sh'
CLI_SUMMARY='is self-dev healthy enough to stop watching?'
CLI_USAGE='  ausculte              every probe; the exit code is the answer
  ausculte --json       one object per probe
  ausculte <probe>      just one: channel hosts routes arming roster_read
                        pullable promote hygiene propagation rot landing
                        unarmed fleet fatals handoff
  ausculte --cadence    run once on a clock: report, and record how long
                        each DOWN/BLIND row has held (--quiet to hush it)
  ausculte --install-cadence [--apply]
                        show, or install, the crontab line for --cadence'
CLI_FLAGS='--json --cadence --install-cadence --apply --quiet'
CLI_POSITIONAL=any
CLI_EXITS='  0  every declared probe answered OK
  5  something declared is DOWN (the report names it)
  6  BLIND: at least one probe could not look, and none was DOWN'
# readlink -f: a verb is a symlink; without this the guard silently misses.
. "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib/cli-guard.sh"
cli_guard "$@"

HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"

. "$HERE/lib/part.sh"
. "$HERE/lib/host-check.sh"
. "$HERE/lib/estate-set.sh"
. "$HERE/lib/fleet-hosts-set.sh"
JSON=0; ONLY=(); CADENCE=0; INSTALL_CADENCE=0; APPLY=0; QUIET=0
while [ $# -gt 0 ]; do
  case "$1" in
    --json) JSON=1 ;;
    --cadence) CADENCE=1 ;;
    --install-cadence) INSTALL_CADENCE=1 ;;
    --apply) APPLY=1 ;;
    --quiet) QUIET=1 ;;
    -*) printf '%s: unknown flag: %s\n' "$CLI_NAME" "$1" >&2; exit 2 ;;
    *)  ONLY+=("$1") ;;
  esac; shift
done
{ [ "$CADENCE" = 1 ] || [ "$INSTALL_CADENCE" = 1 ]; } && [ ${#ONLY[@]} -gt 0 ] \
  && { printf '%s: --cadence/--install-cadence take no probe name\n' "$CLI_NAME" >&2; exit 2; }

if [ "$INSTALL_CADENCE" = 1 ]; then
  self="$(readlink -f "${BASH_SOURCE[0]}")"
  line="${AUSCULTE_CRON_SPEC:-37 */4 * * *} $self --cadence --quiet # realisateur:ausculte:CADENCE"
  if [ "$APPLY" -eq 0 ]; then echo "  would   install into $(id -un)'s crontab: $line"; exit 0; fi
  ( crontab -l 2>/dev/null | grep -v 'realisateur:ausculte:CADENCE'; printf '%s\n' "$line" ) | crontab -
  # WITNESS: read it back rather than believing `crontab -` exited 0.
  if crontab -l 2>/dev/null | grep -q 'realisateur:ausculte:CADENCE'; then
    echo "  OK      cadence in $(id -un)'s crontab (re-read, not asserted): $line"
    exit 0
  fi
  echo "  BAD     the cadence is NOT in the crontab -- nothing will run ausculte" >&2
  exit 1
fi

# WHAT --cadence ADDS OVER A BARE RUN: a SINCE record per DOWN/BLIND row
# (written once, on entry, never rewritten while the state holds -- that
# mtime is the only thing an escalation ever produced that is worth keeping),
# a GH_TOKEN minted for the root crontab that has no gh login, and nothing
# that files or pages -- the relay and issue-filing legs cost 47 questions
# sent/0 answered and 10 issues/5 days before both were cut for cause.
if [ "$CADENCE" = 1 ]; then
  . "$HERE/lib/cron-lock.sh"
  cron_lock ausculte-cadence
  STATE="${AUSCULTE_CADENCE_STATE:-${XDG_STATE_HOME:-$HOME/.local/state}/ausculte-cadence}"
  mkdir -p "$STATE" || { echo "$CLI_NAME: BLIND -- cannot write $STATE" >&2; exit 6; }
  APP_MINT="${SELFDEV_APP_MINT:-${SELFDEV_LIBEXEC:-/usr/local/libexec/selfdev}/selfdev-gh-app.sh}"
  if [ -z "${GH_TOKEN:-}${GITHUB_TOKEN:-}" ] && [ -x "$APP_MINT" ]; then
    t="$("$APP_MINT" --token 2>/dev/null | tail -1)"
    case "$t" in ghs_*|ghu_*|gh[a-z]_*) export GH_TOKEN="$t" ;; esac
  fi
  SELF="${AUSCULTE_BIN:-$HERE/ausculte.sh}"
  [ -n "$SELF" ] && [ -x "$SELF" ] || SELF="$(command -v ausculte || true)"
  [ -n "$SELF" ] && [ -x "$SELF" ] \
    || { echo "$CLI_NAME: BLIND -- ausculte is not runnable from here" >&2; exit 6; }
  out="$("$SELF" --json 2>/dev/null)"
  cad_rows="$(printf '%s' "$out" | jq -c '.[]' 2>/dev/null)"
  [ -n "$cad_rows" ] || { echo "$CLI_NAME: BLIND -- ausculte produced no rows" >&2; exit 6; }
  [ "$QUIET" -eq 1 ] || printf '%s\n' "$out"
  cad_down=0
  while IFS= read -r row; do
    [ -n "$row" ] || continue
    name="$(printf '%s' "$row" | jq -r '.probe // .row // empty' 2>/dev/null)"
    status="$(printf '%s' "$row" | jq -r '.status // empty' 2>/dev/null)"
    detail="$(printf '%s' "$row" | jq -r '.detail // empty' 2>/dev/null)"
    [ -n "$name" ] || continue
    # BLIND is not DOWN: "I could not look" is a claim about the observer,
    # and it keeps its own file so the two never collapse into one number.
    case "$status" in
      OK)    rm -f "$STATE/$name.down" "$STATE/$name.blind"; continue ;;
      DOWN)  f="$STATE/$name.down";  rm -f "$STATE/$name.blind"; word=DOWN ;;
      BLIND) f="$STATE/$name.blind"; rm -f "$STATE/$name.down"; word=BLIND ;;
      *)     rm -f "$STATE/$name.down" "$STATE/$name.blind"; continue ;;
    esac
    [ "$word" = DOWN ] && cad_down=1
    if [ ! -f "$f" ]; then
      printf '%s\n' "$detail" > "$f"
      [ "$QUIET" -eq 1 ] || echo "  $word    $name -- since now: $detail"
    else
      [ "$QUIET" -eq 1 ] || echo "  $word    $name -- since $(date -u -r "$f" +%Y-%m-%dT%H:%MZ 2>/dev/null || echo earlier): $detail"
    fi
  done <<< "$cad_rows"
  [ "$cad_down" -eq 0 ] || exit 5
  exit 0
fi

_monkey_status=''; _monkey_status_fetched=0
fetch_monkey_status() {  # one curl per run for monkey/status.json -- hosts and arming both want it, and two fetches could disagree with each other about the same fact
  [ "$_monkey_status_fetched" = 1 ] && return 0
  _monkey_status_fetched=1
  _monkey_status="$(curl -s -m 20 "${MONKEY_STATUS_URL:-https://$GH_ESTATE_SITE/monkey/status.json}" 2>/dev/null)"
}

down=0; blind=0; rows=()
# FOUR STATES, NOT THREE (2026-08-22). OK / DOWN / BLIND could not express
# "this host must not answer that question", so containment showed up as
# failure: monkey is a VM GUEST on dexter, and a guest holding shell on its own
# hypervisor is backwards. Without a fourth word the only honest readings left
# were BLIND forever -- an alarm that can never clear, which trains its reader
# to ignore the row and then the verb.
#
#   OK        it serves what it declares
#   DOWN      it does not                       -> exit 5
#   BLIND     I could not look                  -> exit 6
#   NOT-MINE  I must not look, from here        -> neither
#
# NOT-MINE IS NOT A QUIET BLIND. It says the question has an owner and this is
# not it, and it names who. dexter is watched from dexter by monkey-watch.sh,
# which publishes where monkey cannot suppress it -- that is the answer, and it
# is a better one than a guest reaching across the boundary to ask.
record() {
  rows+=("$1|$2|$3")
  case "$2" in DOWN) down=1 ;; BLIND) blind=1 ;; esac
}

# not_mine <probe> <who owns it> -- record the boundary, and never the alarm.
not_mine() { record "$1" NOT-MINE "$2"; }
want() {
  [ ${#ONLY[@]} -eq 0 ] && return 0
  local p; for p in "${ONLY[@]}"; do [ "$p" = "$1" ] && return 0; done
  return 1
}

if want channel; then
  . "$HERE/lib/zaxon.sh"
  ep="$(zaxon_probe ausculte)" || ep=''
  if [ -n "$ep" ]; then record channel OK "zaxon answers at $ep"
  else record channel DOWN 'no zaxon relay answered -- questions cannot reach Zach'; fi
fi

if want hosts; then
  # A CONTAINED GUEST DOES NOT AUDIT ITS OWN HYPERVISOR. monkey is a WSL2
  # distro ON dexter and root there holds an empty authorized_keys with no
  # config, key or known_hosts -- so from here this row could only ever read
  # BLIND. The question is answered where it belongs: monkey-watch.sh runs ON
  # dexter every ten minutes and publishes, precisely so the report survives
  # monkey being down. There is no local probe any more: dexter-liveness.sh was
  # deleted (hf7y/senechal#562), so the PUBLISHED document is the only source.
  if on_target_host monkey; then
    not_mine hosts 'dexter is watched from dexter by monkey-watch.sh; a guest must not hold shell on its host'
  else
    fetch_monkey_status  # #735: monkey-watch.sh publishes this exact verdict from dexter every 10 minutes
    wv="$(printf '%s' "$_monkey_status" | jq -r '.watcher.verdict // empty' 2>/dev/null)"
    wvu="$(printf '%s' "$_monkey_status" | jq -r '.watcher.valid_until // empty' 2>/dev/null)"
    why="$(printf '%s' "$_monkey_status" | jq -r '.watcher.why // empty' 2>/dev/null)"
    if [ -z "$wv" ]; then
      record hosts BLIND 'the published monkey-watch status could not be read, and nothing else measures dexter'
    elif [ -n "$wvu" ] && [ "$(date -u +%s)" -gt "$(date -u -d "$wvu" +%s 2>/dev/null || echo 0)" ]; then
      record hosts BLIND "the published monkey-watch status expired at $wvu -- nothing is publishing it"
    elif [ "$wv" = OK ]; then
      record hosts OK 'monkey-watch (dexter) reports dexter serves what it declares'
    else
      record hosts DOWN "${why:-monkey-watch (dexter) reports $wv}"
    fi
  fi
fi

if want routes; then
  # A ROUTE THAT ANSWERS IS NOT A ROUTE THAT ARRIVED. dexter, monkey and
  # vaporwave share one network namespace, so the PORT selects the machine and
  # Windows sshd holds 22 -- an alias missing Port reaches a REAL sshd on the
  # WRONG host, and its refusal reads as a broken key. wtul#131 spent three
  # days concluding "dexter's sshd rejects restrict/command=" from exactly
  # that. See bin/lib/fleet-hosts-set.sh.
  rconf="${SSH_ROUTE_CONFIG:-$HOME/.ssh/config}"
  if [ ! -r "$rconf" ]; then
    record routes BLIND "no ssh config at $rconf -- nothing to check"
  else
    # ssh -G, NOT a grep over the file: it resolves Include and Match, which is
    # where an alias's real port can live. A wildcard Host is a pattern, not a
    # route, so it is skipped rather than resolved and flagged.
    rbad=''; rok=0
    for ra in $(awk 'tolower($1)=="host"{for(i=2;i<=NF;i++) if ($i !~ /[*?!]/) print $i}' "$rconf" | sort -u); do
      rg="$(ssh -G -F "$rconf" "$ra" 2>/dev/null)" || continue
      [ "$(printf '%s\n' "$rg" | awk '$1=="hostname"{print $2; exit}')" = "$SSH_NETNS_ADDR" ] || continue
      rp="$(printf '%s\n' "$rg" | awk '$1=="port"{print $2; exit}')"
      rwho="$(ssh_netns_host_at "$rp")" \
        || { rbad="$rbad $ra->:$rp(nothing is declared on that port -- see lib/fleet-hosts-set.sh)"; continue; }
      # The whole point: 22 ANSWERS, and is the wrong machine. A missing Port is
      # indistinguishable from naming it, which is why this cannot be eyeballed.
      if [ "$rwho" = windows ]; then
        rbad="$rbad $ra->:$rp(dexter's WINDOWS sshd -- different authorized_keys; every key in the WSL2 file is refused there)"
      else rok=$((rok+1)); fi
    done
    if [ -n "$rbad" ]; then
      record routes DOWN "ssh alias reaching dexter's address without naming its host:$rbad -- 2223 dexter, 2224 monkey, 2225 vaporwave"
    else
      record routes OK "$rok ssh alias(es) at dexter's address, each naming the port that selects its host"
    fi
  fi
fi

if want arming; then
  # WHAT THE ACCOUNTS ARE DOING, not how often the word "armed" appears.
  fetch_monkey_status; st="$_monkey_status"
  vu="$(printf '%s' "$st" | jq -r '.watcher.valid_until // .valid_until // empty' 2>/dev/null)"
  if ! printf '%s' "$st" | jq -e '.accounts' >/dev/null 2>&1; then
    record arming BLIND 'the published monkey status could not be read'
  elif [ -n "$vu" ] && [ "$(date -u +%s)" -gt "$(date -u -d "$vu" +%s 2>/dev/null || echo 0)" ]; then
    # A document past the freshness it declares for itself is not evidence.
    record arming BLIND "the published monkey status expired at $vu -- nothing is publishing it"
  elif [ "$(printf '%s' "$st" | jq -r '.accounts | length' 2>/dev/null)" = 0 ]; then
    record arming BLIND "the published monkey status lists no accounts: $(printf '%s' "$st" | jq -r '.watcher.accounts_from // .accounts_from // "no reason given"' 2>/dev/null)"
  else
    # fromdateiso8601 wants "Z" only; the collector normalises to it now (#919)
    if ! stale="$(printf '%s' "$st" | jq -er --argjson d "${ARMING_STALE_DAYS:-3}" '
      (now - ($d * 86400)) as $cut
      | [ .accounts[]
          | select(.armed)
          | select(.last_run.started_at != null)
          | select((.last_run.started_at | fromdateiso8601) < $cut)
          | .account ] | join(" ")' 2>/dev/null)"; then
      record arming BLIND 'the status document could not be graded (unreadable timestamps)'
      stale=SKIP
    fi
    # NO RECORD IS NOT NO DISPATCH (hf7y/scheduler#259).
    norec="$(printf '%s' "$st" | jq -r '[.accounts[]|select(.armed)|select(.last_run.started_at == null)|.account]|join(" ")' 2>/dev/null)"
    n_armed="$(printf '%s' "$st" | jq -r '[.accounts[]|select(.armed)]|length')"
    gen="$(printf '%s' "$st" | jq -r '.generated')"
    if [ "$stale" = SKIP ]; then :
    elif [ -n "$stale" ]; then
      record arming DOWN "armed but not dispatching for ${ARMING_STALE_DAYS:-3}d: $stale (status generated $gen)"
    elif [ -n "$norec" ]; then
      # The document omits their last_run; their ledgers are on a host. Which
      # one is not recorded here, so every host in the set is asked (#1139) --
      # an account with no record is not evidence it lives on the first host
      # that answers, and an unreachable host must not silently look like an
      # account that simply has no ledger there.
      lr=""
      for _ah in "${FLEET_HOSTS[@]}"; do
        lr="$lr $(${AUSCULTE_SSH:-ssh} -o ConnectTimeout=10 -o BatchMode=yes "$_ah" "
          sudo -n true 2>/dev/null && SU='sudo -n' || SU=''
          for a in $norec; do
            f=/home/\$a/.local/share/scheduler-paced-runner/ledger.tsv
            \$SU test -r \"\$f\" && printf '%s %s\n' \"\$a\" \"\$(\$SU tail -1 \"\$f\" | cut -f1)\"
          done" 2>/dev/null)"
      done
      if [ -n "${lr// /}" ]; then
        record arming DOWN "published status omits last_run for: $norec (hf7y/scheduler#259) -- their own ledgers say: $(printf '%s' "$lr" | tr '\n' ' ')"
      else
        record arming BLIND "no run record published for: $norec -- cannot tell whether they dispatched (hf7y/scheduler#259)"
      fi
    else
      record arming OK "$n_armed account(s) armed, each dispatched within ${ARMING_STALE_DAYS:-3}d"
    fi
  fi
fi

if want roster_read; then  # THE ARMING AUTHORITY ITSELF, not what the accounts did with it (#1191): arming reads accounts[].armed, which the accounts publish and which stays populated with the roster service gone -- so a dead authority read as a clean ausculte for four days while monkey-status-collect.py measured and published the fact the whole time.
  fetch_monkey_status; rst="$_monkey_status"
  rvu="$(printf '%s' "$rst" | jq -r '.watcher.valid_until // .valid_until // empty' 2>/dev/null)"
  rr="$(printf '%s' "$rst" | jq -r 'if has("roster_read") then (.roster_read | tostring) else "absent" end' 2>/dev/null)"
  if [ -z "$rst" ] || ! printf '%s' "$rst" | jq -e . >/dev/null 2>&1; then
    record roster_read BLIND 'the published monkey status could not be read'
  elif [ -n "$rvu" ] && [ "$(date -u +%s)" -gt "$(date -u -d "$rvu" +%s 2>/dev/null || echo 0)" ]; then
    record roster_read BLIND "the published monkey status expired at $rvu -- nothing is publishing it"  # a document past its own declared freshness is not evidence, as in arming and hosts above
  elif [ -z "$rr" ] || [ "$rr" = absent ] || [ "$rr" = null ]; then
    record roster_read BLIND "the published monkey status carries no roster_read field: $(printf '%s' "$rst" | jq -r '.watcher.why // .watcher.verdict // "no reason given"' 2>/dev/null)"  # BLIND, NOT DOWN: absent is a document that cannot say -- a collector older than the field, or the watcher's degraded fallback, which publishes no accounts and no roster_read when the collector could not run at all. Reading that silence as DOWN would alarm on the wrong host.
  elif [ "$rr" = false ]; then
    rnull="$(printf '%s' "$rst" | jq -r '[.accounts[]? | select(.roster_state == null)] | length' 2>/dev/null)"
    record roster_read DOWN "the collector could not read the roster service at $GH_ESTATE_ROSTER_URL -- ${rnull:-?} account(s) have no roster_state, so arming_state() answers nothing and BLIND classifies nothing"
  else
    record roster_read OK "the collector read the roster service; every account carries a roster_state"
  fi
fi

if want pullable; then  # CAN A REBUILT DEXTER RECOVER FROM ITS COMPOSE FILES ALONE? The container pattern's first rule -- "PULLED, NOT BUILT: a dexter that lost its checkout recovers from this file". Asked WITH dexter's own credential: Zach ruled 2026-09-16 that packages are private and dexter pulls with a read:packages token in docker login (#1210, superseding #1196's anonymous rule), so the question is what dexter itself can fetch.
  if on_target_host monkey; then
    not_mine pullable 'dexter is watched from dexter; a guest must not hold shell on its host to audit it'
  else
    pdh="${AUSCULTE_DEXTER_HOST:-dexter}"
    prefs="$(${AUSCULTE_SSH:-ssh} -o ConnectTimeout=10 -o BatchMode=yes "$pdh" '
      for f in /srv/*/compose.yaml; do [ -r "$f" ] || continue
        sed -n "s/^[[:space:]]*image:[[:space:]]*//p" "$f"; done' 2>/dev/null \
      | sed -e 's/[[:space:]]#.*$//' -e 's/[[:space:]]*$//' \
      | tr -d "\"'" | sort -u)"  # A TRAILING COMMENT IS PART OF THE LINE, NOT THE REF: this repo's prose ratchet pushes explanation into trailing comments, so the first `image:` line written under that rule fed the whole comment to the registry and graded a healthy groc-browser BLIND. Stripped locally, not in the remote sed, so the stub in ausculte.test.sh exercises it.
    if [ -z "$prefs" ]; then
      record pullable BLIND "no compose.yaml under /srv on $pdh could be read -- nothing to grade"
    else
      pres="$(printf '%s\n' "$prefs" | ${AUSCULTE_SSH:-ssh} -o ConnectTimeout=10 -o BatchMode=yes "$pdh" 'while IFS= read -r r; do [ -n "$r" ] || continue; e="$(timeout 30 docker manifest inspect "$r" 2>&1 >/dev/null)"; printf "%s\t%s\t%s\n" "$?" "$r" "$(printf %s "$e" | head -1)"; done' 2>/dev/null)"
      pbad=''; pblind=''; pok=0; pup=0
      while IFS=$'\t' read -r prc pr perr; do  # ASKED, NOT GUESSED: `nginx:latest` and `groc-browser:local` are both registry-less and only one is recoverable, so each is resolved by the registry that would serve it.
        [ -n "$pr" ] || continue
        if [ "$prc" = 0 ]; then case "$pr" in ghcr.io/*) pok=$((pok+1)) ;; *) pup=$((pup+1)) ;; esac
        elif printf '%s' "$perr" | grep -qiE 'unauthorized|denied|not found|no such manifest|manifest unknown'; then
          case "$pr" in ghcr.io/*) pbad="$pbad $pr(dexter's own credential cannot pull it: $perr -- is dexter logged in to ghcr.io with a read:packages token?)" ;;
                        *) pbad="$pbad $pr(no registry serves this: $perr -- it exists only in dexter's local image store and a rebuilt dexter cannot recover it)" ;; esac
        else pblind="$pblind $pr(${perr:-no answer})"; fi
      done <<PULLABLE_EOF
$pres
PULLABLE_EOF
      if [ -z "$pres" ]; then record pullable BLIND "$pdh read its compose files but answered nothing about pulling them"
      elif [ -n "$pbad" ]; then record pullable DOWN "declared in a compose file on $pdh and NOT pullable by dexter:$pbad"
      elif [ -n "$pblind" ]; then record pullable BLIND "a registry could not be asked about:$pblind"
      else record pullable OK "$pok vendored and $pup upstream image(s) declared on $pdh, every one pullable with dexter's own credential"; fi
    fi
  fi
fi

if want promote; then  # WHEN DID IT LAST RUN, AND WHEN DOES IT RUN NEXT? `docker ps` says "Up 3 hours", which is a different question -- a promote container can sit up for days with a dead loop. A systemd timer answers it for free via `systemctl list-timers`, at the price of a second scheduler on a host where compose is already the first and where duplicate mechanisms were deleted on 2026-09-16. The container already stamps `cycle ok, <ts>` on every pass (hf7y/wtul#211, the line deploy.sh gates on), so the witness is READ here beside roster_read and pullable rather than BUILT again -- the same move that turned "is the arming authority alive" from an architecture question into a probe.
  if on_target_host monkey; then
    not_mine promote 'dexter is watched from dexter; a guest must not hold shell on its host to audit it'
  else
    mdh="${AUSCULTE_DEXTER_HOST:-dexter}"
    mout="$(${AUSCULTE_SSH:-ssh} -o ConnectTimeout=10 -o BatchMode=yes "$mdh" '
      d=/srv/wtul-dexter-promote
      [ -r "$d/compose.yaml" ] || { echo NODECL; exit 0; }
      sed -n "s/.*PROMOTE_INTERVAL_SECONDS:[^0-9]*\([0-9][0-9]*\).*/INTERVAL \1/p" "$d/compose.yaml" | head -1
      sed -n "s/.*PROMOTE_APPLY:[^0-9]*\([0-9]\).*/APPLY \1/p" "$d/compose.yaml" | head -1
      echo "STATE $(sudo -n docker inspect -f "{{.State.Status}}" wtul-dexter-promote 2>/dev/null)"
      sudo -n docker logs --tail 200 wtul-dexter-promote 2>&1 | grep "^wtul-dexter-promote: cycle ok" | tail -1 | sed "s/^/LAST /"
    ' 2>/dev/null)"
    mfield() { printf '%s' "$mout" | sed -n "s/^$1 //p" | head -1; }
    case "$mout" in
      '') record promote BLIND "no answer from $mdh -- the promote container could not be looked at" ;;
      NODECL*) record promote BLIND "no /srv/wtul-dexter-promote/compose.yaml on $mdh -- promote is not deployed, so nothing measures whether a staged disc ever reaches the library; hf7y/wtul provision/dexter/wtul-dexter-promote/deploy.sh is what puts it there" ;;  # BLIND, NOT DOWN: the declaration lives in wtul's checkout, not on dexter, so an absent compose file is a question this host cannot answer rather than a service that failed. It still is not OK, and exit 6 says so.
      *)
        mint="$(mfield INTERVAL)"; mint="${mint:-300}"
        mst="$(mfield STATE)"
        mlast="$(printf '%s' "$mout" | sed -n 's/^LAST wtul-dexter-promote: cycle ok, //p' | head -1)"
        mts=''; [ -n "$mlast" ] && mts="$(date -u -d "$mlast" +%s 2>/dev/null)"
        mnote=''; [ "$(mfield APPLY)" = 0 ] && mnote=' -- and PROMOTE_APPLY=0, so it cycles and promotes nothing; this row grades the clock, not the library'
        if [ -z "$mst" ]; then
          record promote DOWN "$mdh declares promote in /srv/wtul-dexter-promote/compose.yaml and no container by that name exists -- nothing is promoting"
        elif [ "$mst" != running ]; then
          record promote DOWN "the promote container on $mdh is $mst, not running -- its entrypoint exits non-zero on a failed cycle rather than looping silently (hf7y/wtul b4a1171), so a stopped container IS the failed cycle; \`sudo docker compose logs\` in /srv/wtul-dexter-promote names it"
        elif [ -z "$mlast" ]; then
          record promote DOWN "the promote container on $mdh is running and has logged no completed cycle -- up is not the same as promoting"
        elif [ -z "$mts" ]; then
          record promote BLIND "the last cycle stamp on $mdh could not be read as a date: $mlast"
        elif [ "$(( $(date -u +%s) - mts ))" -gt "$(( mint * 3 ))" ]; then
          record promote DOWN "the last completed promote cycle on $mdh was $mlast, $(( ($(date -u +%s) - mts) / 60 ))m ago -- past 3x the declared ${mint}s interval. It is up and it is not cycling"
        else
          record promote OK "promote on $mdh completed a cycle $(( ($(date -u +%s) - mts) / 60 ))m ago, inside the declared ${mint}s interval (last: $mlast)$mnote"
        fi ;;
    esac
  fi
fi

if want hygiene; then  # THE QUESTION'S OWNER, NOT ECOSIM'S CI (#706): hf7y/ecosim#91 refused a CI grant onto 0700 self-dev homes for "is any account holding something it shouldn't" -- a host fact about monkey, read where host facts about monkey already get read. monkey-status-collect.py (schema 2) already publishes containment and credentials per account; this probe only grades what it already collects.
  # A SET, NOT A DEFAULT (hf7y/realisateur#1139): this used to curl only
  # monkey's published status.json, reproducing this issue's own defect --
  # a second host's silence reading as health -- in the one probe the
  # fleet/fatals migrations did not touch. monkey-watch.sh publishes the same
  # document shape per instance (<host>/status.json), so each host in the set
  # gets its own curl and its own grade; a host whose document cannot be read,
  # or is the wrong schema, is BLIND for THAT HOST, never folded into another
  # host's OK. <HOST>_STATUS_URL overrides one host's URL -- the same name
  # MONKEY_STATUS_URL already used, just no longer the only host it works for.
  hy_down=""; hy_blind=""; hy_ok=""; hy_n=0
  for _hh in "${FLEET_HOSTS[@]}"; do
    _hh_var="$(printf '%s' "$_hh" | tr '[:lower:]' '[:upper:]')_STATUS_URL"
    _hh_url="${!_hh_var:-https://$GH_ESTATE_SITE/$_hh/status.json}"
    st="$(curl -s -m 20 "$_hh_url" 2>/dev/null)"
    if ! printf '%s' "$st" | jq -e '.accounts' >/dev/null 2>&1; then
      hy_blind="$hy_blind $_hh:unreadable"
    elif [ "$(printf '%s' "$st" | jq -r '.schema // 0')" -lt 2 ] 2>/dev/null; then
      hy_blind="$hy_blind $_hh:schema $(printf '%s' "$st" | jq -r '.schema') has no containment/credentials field"
    else
      unreadable="$(printf '%s' "$st" | jq -r '.accounts[] | select(.containment == null) | .account' | tr '\n' ' ')"
      contained="$(printf '%s' "$st" | jq -r '
        .accounts[]
        | select(.containment != null)
        | select((.containment.foreign_clones|length)>0 or (.containment.outside_home|length)>0 or (.containment.sudoers|length)>0)
        | .account' | tr '\n' ' ')"
      # UNIFORMITY, NOT AN ABSOLUTE BAR: this repo does not invent what mode a
      # credential file "should" be -- only whether every account on THIS HOST
      # got the SAME treatment (ecosim#91's row_creds, ported as-is). Graded
      # per host: nothing says two different hosts must share a shape with
      # each other.
      shapes="$(printf '%s' "$st" | jq -r '[.accounts[].credentials | tostring] | unique | length')"
      if [ -n "$contained" ]; then
        hy_down="$hy_down $_hh:holding something it should not: $contained${unreadable:+; unreadable: $unreadable}"
      elif [ "${shapes:-0}" -gt 1 ]; then
        hy_down="$hy_down $_hh:$shapes distinct credential permission shapes across accounts -- not every account got the same treatment${unreadable:+; unreadable: $unreadable}"
      elif [ -n "$unreadable" ]; then
        hy_blind="$hy_blind $_hh:containment unreadable for: $unreadable"
      else
        _hn="$(printf '%s' "$st" | jq -r '.accounts | length')"
        hy_ok="$hy_ok $_hh($_hn)"; hy_n=$((hy_n + _hn))
      fi
    fi
  done
  # DOWN beats BLIND beats OK, the same aggregation fleet/fatals already use
  # above: a real finding on one host must not hide behind another host merely
  # being unreadable, and an unreadable host must never be folded into an OK.
  if [ -n "$hy_down" ]; then
    record hygiene DOWN "${hy_down# }${hy_blind:+ -- also could not grade:$hy_blind}"
  elif [ -n "$hy_blind" ]; then
    record hygiene BLIND "could not grade:$hy_blind"
  else
    record hygiene OK "$hy_n account(s) across${hy_ok:+:$hy_ok} -- no foreign clone, no file outside home, no sudoers.d entry, one shared credential shape per host"
  fi
fi

if want propagation; then
  # THE CHANNEL'S OWN VERDICT FIRST: counting verbs answers "is something
  # installed", not "is the channel running", and said OK through an outage.
  ps=""
  for cand in "$HERE/lib/propagation-set.sh" \
              "${SELFDEV_LIBEXEC:-/usr/local/libexec/selfdev}/lib/propagation-set.sh"; do
    [ -r "$cand" ] && { ps="$cand"; break; }
  done
  # shellcheck source=lib/propagation-set.sh
  [ -n "$ps" ] && . "$ps"
  v="$(curl -s -m 15 "${VERBS_STATUS_URL:-https://$GH_ESTATE_SITE/verbs/status.json}" 2>/dev/null)"
  dec="$(printf '%s' "$v" | jq -r '.decision // empty' 2>/dev/null)"
  if [ -z "$dec" ]; then
    record propagation BLIND 'cannot read the release channel verdict'
  else
    cut_at="$(printf '%s' "$v" | jq -r '.last_cut.at // empty' 2>/dev/null)"
    streak="$(printf '%s' "$v" | jq -r '.blocked_streak // 0' 2>/dev/null)"
    # TWO NUMBERS, NOT ONE (realisateur#603). Under a monthly cut they differ
    # by 29 days:
    #   max_h      the ADOPTION window -- how long a host may lag a cut it has
    #              been told about. Keyed to the emitter's nightly cadence, so
    #              this is unchanged at 28h.
    #   cut_max_h  the BUILD-AGE floor -- how old the newest build may be before
    #              the cutter is presumed dead. Keyed to the published cut
    #              interval, plus one adoption window.
    # Conflating them graded a healthy 20-day-old monthly build as DOWN on 29
    # nights in 30, and hid the adoption branch below behind line :183's return.
    max_h=$(( $(printf '%s' "$v" | jq -r '.cadence_hours // 24') + $(printf '%s' "$v" | jq -r '.grace_hours // 4') ))
    # A document that declares no interval is a NIGHTLY one: defaulting to 0
    # makes cut_max_h == max_h, i.e. exactly the pre-#603 grade. A schema-2
    # verdict therefore reads identically after this change, which is what
    # lets the publisher and the consumers move on different nights.
    cut_max_h=$(( $(printf '%s' "$v" | jq -r '.cut_interval_days // 0') * 24 + max_h ))
    age_h=-1
    if [ -n "$cut_at" ]; then
      cut_epoch="$(date -u -d "$cut_at" +%s 2>/dev/null)" \
        && age_h=$(( ( $(date -u +%s) - cut_epoch ) / 3600 ))
    fi
    # NO_CHANGE IS A HEALTHY NIGHT -- gate green, nothing moved, today's build
    # still current. 5 of the last 54 read as an outage. BLOCKED/ERROR remain.
    if [ "$dec" != CUT ] && [ "$dec" != NO_CHANGE ]; then
      record propagation DOWN "the channel is $dec ($streak run(s) running); nothing has propagated since $cut_at"
    elif [ "$age_h" -lt 0 ]; then
      record propagation BLIND 'the verdict names no last cut this could age'
    elif [ "$age_h" -gt "$cut_max_h" ]; then
      record propagation DOWN "the newest build is ${age_h}h old, past the ${cut_max_h}h its cut interval allows -- the cutter has stopped"
    else
      # Only with the channel proven live does what is installed mean
      # anything: a host behind the pin did not adopt.
      # Graded against the row the AGE came from: "-" names no build.
      bid="$(printf '%s' "$v" | jq -r '.last_cut.build_id // .build_id // empty' 2>/dev/null)"
      [ "$bid" = "-" ] && bid=""
      if [ -z "${PROP_HOST_PIN:-}" ]; then
        record propagation BLIND 'no propagation-set.sh reachable, so the host pin path is unknown'
        bid=""
      fi
      # A GUEST DOES NOT SSH ITS OWN HYPERVISOR, so on monkey the dexter half
      # of this question is not ours to ask -- it could only read "unreachable"
      # and take the whole row BLIND with it. Recorded, not silently dropped:
      # a host omitted without saying so is how a partial answer reads as a
      # complete one.
      bad=''; unreachable=''; skipped=''
      # The port is READ, not retyped: fleet-hosts-set.sh is the one place that
      # says 2223 is dexter. This line carried its own copy because the ssh
      # config could not be trusted to -- which is now the `routes` probe's job.
      _hosts=(monkey "-p $(ssh_netns_port_for dexter) dexter")
      on_target_host monkey && { _hosts=(monkey); skipped=' dexter'; }
      for h in "${_hosts[@]}"; do
        # LOCALHOST IS NOT AN SSH TARGET: the row read "monkey:unreachable"
        # about the host it was standing on.
        if on_target_host "${h##* }"; then
          n="$(readlink "$PROP_HOST_PIN" 2>/dev/null)"
        else
          # shellcheck disable=SC2086
          n="$(ssh -n -o ConnectTimeout=10 -o BatchMode=yes $h "readlink $PROP_HOST_PIN" 2>/dev/null)"
        fi
        [ -n "$n" ] || { unreachable="$unreachable ${h##* }"; continue; }
        [ "$(basename "$n")" = "$bid" ] || bad="$bad ${h##* }:$(basename "$n")"
      done
      # A DAILY CONSUMER IS LEGITIMATELY BEHIND A FRESH CUT: exact equality
      # made this DOWN daily between the cut and dexter's 05:49 tick. Lagging
      # is DOWN only past the cadence+grace the channel grades ITSELF by.
      # The skipped host is named in every verdict below, so "every host is on
      # it" can never quietly mean "every host I was allowed to ask".
      _sk=""; [ -z "$skipped" ] || _sk=" (not asked from here:$skipped -- see monkey-watch on dexter)"
      if [ -z "$bid" ]; then :
      elif [ -n "$unreachable" ]; then
        record propagation BLIND "channel cut $bid ${age_h}h ago; could not read:$unreachable$_sk"
      elif [ -n "$bad" ] && [ "$age_h" -gt "$max_h" ]; then
        record propagation DOWN "channel cut $bid ${age_h}h ago, past the ${max_h}h adoption window; behind:$bad$_sk"
      elif [ -n "$bad" ]; then
        record propagation OK "channel cut $bid ${age_h}h ago; not yet adopted by:$bad (within the ${max_h}h window)$_sk"
      else record propagation OK "channel cut $bid ${age_h}h ago; every host is on it$_sk"; fi
    fi
  fi
fi

if want handoff; then
  # A HANDOFF THAT NEVER COMPLETES IS INVISIBLE. The senechal block moved on
  # 2026-08-22 and the deletion owed here was still outstanding four days
  # later, because "delete once it merges" lived in an issue body and nothing
  # read it on a clock. reprise reads bin/lib/handoffs.tsv instead.
  if rp="$(part reprise.sh)"; then
    out="$(bash "$rp" --check 2>&1)"; rc=$?
    case $rc in
      0) if printf '%s' "$out" | grep -q 'collectable'; then
           record handoff OK "$(printf '%s' "$out" | grep -E '^reprise: [0-9]+ row' | tail -1)"
         else record handoff OK 'no handoffs outstanding'; fi ;;
      1) record handoff DOWN "$(printf '%s' "$out" | grep -E 'MERGED but' | head -1)" ;;
      2) record handoff BLIND 'ausculte invoked reprise wrongly -- fix ausculte' ;;
      *) record handoff BLIND "$(printf '%s' "$out" | tail -1)" ;;
    esac
  # NOT-MINE, not BLIND: reprise is LOCAL to realisateur and the table it reads
  # is realisateur's. On any other account this row would otherwise be an alarm
  # that can never clear -- the exact failure the fourth state exists for.
  else not_mine handoff 'realisateur -- handoffs.tsv is its table'; fi
fi

if want rot; then
  if dr="$(part decision-rot.sh)"; then
    out="$(bash "$dr" --all 2>&1)"; rc=$?
      case $rc in
      0) nm="$(printf '%s\n' "$out" | awk '$1 == "TOTAL" { print $4 }')"
         if [ "${nm:-0}" -gt 0 ] 2>/dev/null; then
           # Never silently: 30 real rows would otherwise vanish here.
           record rot OK "no answered decision open where anything dispatches ($nm NOT-MINE -- nothing is armed to act)"
         else record rot OK 'no answered-and-abandoned issues'; fi ;;
      # A COUNT AND THE OLDEST ROW, NOT `tail -1`: the block is sorted
      # oldest-first, so tail named the NEWEST and hid the rest (#661).
      1) n="$(printf '%s\n' "$out" | awk '$1 == "TOTAL" { print $3 }')"
         oldest="$(printf '%s\n' "$out" \
                    | awk '/^ROTTING/ { f = 1; next } f && NF { sub(/^ +/, ""); print; exit }')"
         if [ -n "$n" ] && [ -n "$oldest" ]; then
           record rot DOWN "$n answered decision(s) still open across the roster; oldest: $oldest"
         else record rot DOWN "$(printf '%s' "$out" | tail -1)"; fi ;;
      2) record rot BLIND 'ausculte invoked decision-rot.sh wrongly -- fix ausculte' ;;
      *) record rot BLIND "$(printf '%s' "$out" | tail -1)" ;;
    esac
  else record rot BLIND 'decision-rot.sh not present'; fi
fi

if want landing; then
  if ld="$(part landing-drift.sh)"; then
    out="$(bash "$ld" --all 2>&1)"; rc=$?
    case $rc in
      0) record landing OK 'every repo can land what it opens' ;;
      1) worst="$(printf '%s\n' "$out" \
                   | awk '$5 == "stranded" || $5 ~ /^stranded/ { if ($2 + 0 > n) { n = $2; r = $1; d = $3 } }
                          END { if (r != "") printf "%s has %s green and unlanded, oldest %s", r, n, d }')"
         record landing DOWN "${worst:-$(printf '%s\n' "$out" | grep -E '[0-9]+ finding' | tail -1)}" ;;
      2) record landing BLIND 'ausculte invoked landing-drift.sh wrongly -- fix ausculte' ;;
      *) record landing BLIND "$(printf '%s' "$out" | tail -1)" ;;
    esac
  else record landing BLIND 'landing-drift.sh not present'; fi
fi


# BUILT AND NOT TURNED ON (#754): seven found by conversation, none by a probe,
# while unarmed.sh sat on a weekly clock nobody reads. DOWN only past a row's
# OWN window -- a floor that merely persists is not an alarm.
if want unarmed; then
  if un="$(part unarmed.sh)"; then
    out="$(bash "$un" --check 2>&1)"; rc=$?
    case $rc in
      0) record unarmed OK 'the floor holds -- nothing newly built and unarmed, and no row past its own window' ;;
      # Name the rows, not a count: "3 findings" sends them to the file anyway.
      1) named="$(printf '%s\n' "$out" \
                   | awk '$1 == "EXPIRED" || $1 == "GREW" || $1 == "REGRESSED" { printf "%s %s; ", $1, $2 }')"
         record unarmed DOWN "${named:-$(printf '%s' "$out" | tail -1)}" ;;
      2) record unarmed BLIND 'ausculte invoked unarmed.sh wrongly -- fix ausculte' ;;
      *) record unarmed BLIND "$(printf '%s' "$out" | tail -1)" ;;
    esac
  else record unarmed BLIND 'unarmed.sh not present'; fi
fi

if want fleet; then
  # LOCALHOST IS NOT AN SSH TARGET -- the same fix the propagation row above
  # already carries. This probe used to ssh to ${AUSCULTE_FLEET_HOST:-monkey}
  # unconditionally, including FROM monkey, where the ledgers actually live.
  # root there has an EMPTY authorized_keys and no config, key or known_hosts,
  # so `ssh monkey` from monkey fails host key verification and the row read
  # BLIND on the one machine that could have answered it by reading a file.
  # The cadence runs as root on monkey, so that was every scheduled reading.
  _fleet_probe='
    sudo -n true 2>/dev/null && SU="sudo -n" || SU=""   # homes are 0700
    n=0
    for f in $($SU sh -c "ls /home/*/.local/share/scheduler-paced-runner/ledger.tsv 2>/dev/null"); do
      $SU test -r "$f" || continue
      n=$((n + 1))
      $SU tail -1 "$f"
    done
    # PRESENCE is the signal; the runner clears these on recovery.
    for d in $($SU sh -c "ls -d /home/*/.local/share/scheduler-paced-runner 2>/dev/null"); do
      a=${d#/home/}; a=${a%%/*}
      $SU test -r "$d/gate-error-streak.state" &&
        echo "FLEET-GATE-ERR $a $($SU cat "$d/gate-error-streak.state")"
      $SU test -r "$d/pull-block.state" &&
        echo "FLEET-PULL $a $($SU cat "$d/pull-block.state")"
    done
    echo "FLEET-LEDGERS $n"'
  # A SET, NOT A DEFAULT (hf7y/realisateur#1139): this used to ask only
  # ${AUSCULTE_FLEET_HOST:-monkey}, so a second host's silence read as health.
  # fleet-hosts-set.sh names who to ask; a host in that set this probe cannot
  # reach is recorded BELOW as unreachable and MUST NOT be folded into an OK --
  # reproducing "silence reads as health" at the scale of a whole host would be
  # worse than not fixing the single-host version at all.
  f_all=""; f_unreachable=""; f_reached=0
  for _fh in "${FLEET_HOSTS[@]}"; do
    if on_target_host "$_fh"; then
      _led="$(bash -c "$_fleet_probe" 2>/dev/null)"
    else
      _led="$(${AUSCULTE_SSH:-ssh} -o ConnectTimeout=10 -o BatchMode=yes "$_fh" "$_fleet_probe" 2>/dev/null)"
    fi
    case "$_led" in
      *FLEET-LEDGERS*) f_reached=$((f_reached + 1)); f_all="$f_all
$_led" ;;
      *) f_unreachable="$f_unreachable $_fh" ;;
    esac
  done
  if [ "$f_reached" -eq 0 ]; then
    record fleet BLIND "could not read the accounts paced-runner ledgers on any host in the fleet set:${f_unreachable:- (none reachable)}"
  else
    n_led="$(printf '%s\n' "$f_all" | awk '$1=="FLEET-LEDGERS"{s+=$2} END{print s+0}')"
    gate_err="$(printf '%s\n' "$f_all" | awk '$1=="FLEET-GATE-ERR" && $3+0 >= 2 {print $2"("$3")"}' | tr '\n' ' ')"
    # ANY cause, and >=2 not 3: the escalation dies before writing back.
    frozen="$(printf '%s\n' "$f_all" | awk '$1=="FLEET-PULL" && $3+0 >= 2 {print $2"("$3" "$4")"}' | tr '\n' ' ')"
    unreach_note=""; [ -n "$f_unreachable" ] && unreach_note=" -- UNREACHABLE, not counted, not clean:$f_unreachable"
    if [ -n "$gate_err" ]; then
      record fleet DOWN "the usage gate is ERRORing, not pacing: $gate_err consecutive failure(s) -- no account here is being held on purpose$unreach_note"
    elif [ -n "$frozen" ]; then
      record fleet DOWN "deployed code is FROZEN, so a merged fix cannot land: $frozen blocked tick(s)$unreach_note"
    elif [ -n "$f_unreachable" ]; then
      # #1139 constraint: a host in the set that could not be reached is BLIND,
      # never silently skipped into whatever the reachable hosts reported.
      record fleet BLIND "could not reach:$f_unreachable -- its fleet state is unknown, not clean ($f_reached host(s) reached, $n_led ledger(s) there)"
    elif [ "${n_led:-0}" -eq 0 ]; then
      # Zero ledgers is not a quiet fleet, it is a fleet we cannot see.
      record fleet BLIND 'no account has a paced-runner ledger -- cannot tell whether any of them worked'
    else
      # DONE and COOLDOWN are both fine -- COOLDOWN is the pacer holding a
      # finished account back on purpose. SO IS NOT-DONE WITH A REASON, which
      # this row called DOWN until 2026-08-22: it is what the runner records
      # for an agent verdict of CONTINUE (schedule/_verdict-semantics.md,
      # "there is ACTIONABLE work left"), the healthy steady state of an
      # account with a backlog. Measured that day, 9 of 14 accounts read
      # NOT-DONE and six had shipped a merged PR in that very run. A monitor
      # that reports DOWN in the normal case is one a human checks by hand
      # every time. So the finding is SILENCE, not incompleteness:
      #
      #   blank reason      the account stopped and said nothing (scheduler#261)
      #   no-verdict:       the runner ran it and no verdict was written
      #
      # Both mean the sensor got nothing; an account that explained itself is
      # answering, and whether its answer is good news is its tracker's
      # question, not this probe's.
      mute="$(printf '%s\n' "$f_all" | grep -v '^FLEET-LEDGERS' \
               | awk -F'\t' '$7 == "NOT-DONE" {
                   r = $8; sub(/^[ \t]+/, "", r)
                   if (r == "")                 print $3": *** NO REASON RECORDED ***"
                   else if (r ~ /^no-verdict:/) print $3": "r }' || true)"
      working="$(printf '%s\n' "$f_all" | grep -v '^FLEET-LEDGERS' \
               | awk -F'\t' '$7 == "NOT-DONE" {
                   r = $8; sub(/^[ \t]+/, "", r)
                   if (r != "" && r !~ /^no-verdict:/) print $3 }' || true)"
      n_mute="$(printf '%s' "$mute" | grep -c . || true)"
      n_work="$(printf '%s' "$working" | grep -c . || true)"
      if [ "${n_mute:-0}" -gt 0 ]; then
        record fleet DOWN "$n_mute of $n_led account(s) stopped without saying why: $(printf '%s' "$mute" | head -1 | cut -c1-90)"
      else
        record fleet OK "$n_led account(s) reported${n_work:+, $n_work still working}"
      fi
    fi
  fi
fi

if want fatals; then  # A HARD ABORT BEFORE `claude` STARTS writes no ledger row, so `fleet` above never sees it -- two accounts hard-aborted every dispatch for days on exactly that gap (#1005) and a four-line sweep.log FATAL count found both in a minute.
  # CURRENT RUN, NOT LIFETIME. sweep.log is never rotated, so `grep -c FATAL`
  # over the whole file made this row LATCH: one abort in an account's history
  # held it DOWN forever, and no recovery could ever clear it. Measured
  # 2026-09-16, it was reporting 25 aborts across 4 accounts of which ZERO were
  # current -- the newest was 10 days old and every one of those accounts has
  # completed runs since. A row that cannot return to OK is not a witness, it
  # is furniture, and an operator learns to scroll past it -- which is the
  # failure this whole verb exists to prevent.
  #
  # A run writes `=== <ts> ===` on entry and `=== done|FAILED ... ===` on exit,
  # so resetting the count at every `^=== ` line counts only what has happened
  # since the last marker. A hard abort still lands after one and still reads
  # DOWN, which is the case #1005 named; a historical one does not.
  _fatals_probe='
    sudo -n true 2>/dev/null && SU="sudo -n" || SU=""   # homes are 0700
    n_checked=0
    while IFS=: read -r u _ id _; do
      case "$id" in "" | *[!0-9]*) continue ;; esac
      [ "$id" -ge 3000 ] && [ "$id" -lt 3100 ] || continue
      L=$($SU find /home/$u/.local/share -maxdepth 2 -name sweep.log 2>/dev/null | head -1)
      [ -n "$L" ] || continue
      $SU test -r "$L" || continue
      n_checked=$((n_checked + 1))
      c=$($SU awk "/^=== /{n=0} /FATAL/{n++} END{print n+0}" "$L" 2>/dev/null)
      [ "${c:-0}" -gt 0 ] && printf "FATALS-FOUND %s %s\n" "$u" "$c"
    done < /etc/passwd
    echo "FATALS-CHECKED $n_checked"'
  # A SET, NOT A DEFAULT (hf7y/realisateur#1139): this probe landed (#1062)
  # AFTER the fleet probe above was fixed to read fleet-hosts-set.sh, and
  # still asked only ${AUSCULTE_FLEET_HOST:-monkey} -- the exact regression
  # this issue is about, on a probe new enough that it should have known
  # better. A hard abort on a second host in the set must be found, and a
  # host this probe cannot reach must read BLIND, never be folded silently
  # into "none aborting".
  ft_all=""; ft_unreachable=""; ft_reached=0
  for _th in "${FLEET_HOSTS[@]}"; do
    if on_target_host "$_th"; then
      _fat="$(bash -c "$_fatals_probe" 2>/dev/null)"
    else
      _fat="$(${AUSCULTE_SSH:-ssh} -o ConnectTimeout=10 -o BatchMode=yes "$_th" "$_fatals_probe" 2>/dev/null)"
    fi
    case "$_fat" in
      *FATALS-CHECKED*) ft_reached=$((ft_reached + 1)); ft_all="$ft_all
$_fat" ;;
      *) ft_unreachable="$ft_unreachable $_th" ;;
    esac
  done
  if [ "$ft_reached" -eq 0 ]; then
    record fatals BLIND "could not read any account sweep.log on any host in the fleet set:${ft_unreachable:- (none reachable)}"
  else
    n_checked="$(printf '%s\n' "$ft_all" | awk '$1=="FATALS-CHECKED"{s+=$2} END{print s+0}')"
    found="$(printf '%s\n' "$ft_all" | awk '$1=="FATALS-FOUND" {printf "%s(%s) ", $2, $3}')"
    unreach_note=""; [ -n "$ft_unreachable" ] && unreach_note=" -- UNREACHABLE, not counted, not clean:$ft_unreachable"
    if [ -n "$found" ]; then
      record fatals DOWN "aborting every dispatch, unreported until now: $found$unreach_note"
    elif [ -n "$ft_unreachable" ]; then
      # #1139 constraint: a host in the set that could not be reached is
      # BLIND, never silently folded into whatever the reachable hosts found.
      record fatals BLIND "could not reach:$ft_unreachable -- its fatals state is unknown, not clean ($ft_reached host(s) reached, ${n_checked:-0} account(s) checked there)"
    elif [ "${n_checked:-0}" -eq 0 ]; then  # zero readable is not zero aborting -- same trap as fleet's ledger count
      record fatals BLIND 'no sweep.log could be read for any account -- cannot tell whether one is aborting'
    else
      record fatals OK "$n_checked account(s) checked, none aborting before dispatch"
    fi
  fi
fi


[ ${#rows[@]} -gt 0 ] || { printf '%s: no such probe: %s\n' "$CLI_NAME" "${ONLY[*]}" >&2; exit 2; }

if [ "$JSON" = 1 ]; then
  printf '['
  sep=''
  for r in "${rows[@]}"; do
    IFS='|' read -r p s d <<< "$r"
    printf '%s{"probe":"%s","status":"%s","detail":"%s"}' "$sep" "$p" "$s" "${d//\"/\\\"}"; sep=','
  done
  printf ']\n'
else
  for r in "${rows[@]}"; do
    IFS='|' read -r p s d <<< "$r"
    printf '  %-6s  %-12s %s\n' "$s" "$p" "$d"
  done
  echo
  if [ "$down" = 1 ]; then echo 'DOWN -- something declared is not serving. Named above.'
  elif [ "$blind" = 1 ]; then echo 'BLIND -- a probe could not look. This is NOT "all clear".'
  else echo 'OK -- every declared probe answered. You can stop looking.'; fi
fi

[ "$down" = 1 ] && exit 5
[ "$blind" = 1 ] && exit 6
exit 0
