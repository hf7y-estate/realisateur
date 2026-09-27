#!/usr/bin/env bash
#
# TRAPS (the rest of this header is in the vault):
# HERMETIC. No network, no ssh, no sudo, no read of the live machine. Fixture
# homes under a temp dir, a fake installer, HOME/TICK_STATE/VERB_BUILD_ROOT
# redirected. A suite that needed the real estate to be healthy could not tell
# its own passing from the estate's.
#

set -uo pipefail
# shellcheck source=bin/tests/lib/harness.sh
. "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib/harness.sh"

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
TICK="$REPO/bin/selfdev-release-tick.sh"
SET_LIB="$REPO/bin/lib/propagation-set.sh"
[ -x "$TICK" ]    || { echo "FAIL: $TICK not executable"; exit 1; }
[ -f "$SET_LIB" ] || { echo "FAIL: $SET_LIB missing"; exit 1; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT

echo "propagation.test.sh"
. "$SET_LIB"

# ===========================================================================
echo
echo "-- 1. EVERY ARTIFACT HAS EXACTLY ONE DECLARED CHANNEL ------------------"
# ===========================================================================
# The ratchet. A new script in bin/ cannot be merged without someone deciding
# how it reaches the accounts that will use it. One file to edit, one line to
# add -- and CI red until it is added.
unclassified=""
while IFS= read -r f; do  # executables, not just *.sh -- monkey-status-collect.py has none (#596)
  n="$(basename "$f")"
  prop_channel "$n" >/dev/null || unclassified="$unclassified $n"
done <<EOF
$(find "$REPO/bin" -maxdepth 1 -type f -perm -u+x | sort)
EOF
if [ -z "$unclassified" ]; then
  ok "every executable in bin/ is classified in bin/lib/propagation-set.sh"
else
  bad "UNCLASSIFIED, so they reach no account by any path:$unclassified"
  echo "       Add each to PROP_BOOTSTRAP_SCRIPTS, PROP_PROVISION_SCRIPTS,"
  echo "       PROP_PAYLOAD_SCRIPTS or PROP_LOCAL_SCRIPTS. The question is:"
  echo "       would it still be needed on a host with NO PAYLOAD INSTALLED?"
  echo "       yes -> bootstrap.  stands an account up once -> provision."
  echo "       no -> payload (a verb).  never leaves this repo -> local."
fi

ALL="$PROP_BOOTSTRAP_SCRIPTS $PROP_PROVISION_SCRIPTS $PROP_PAYLOAD_SCRIPTS $PROP_LOCAL_SCRIPTS"

# Classified twice is worse than classified zero times: two channels means two
# answers to "which copy is running", which is the one question a bug report
# must be able to answer.
dupes=""
for n in $ALL; do
  c=0; for m in $ALL; do [ "$m" = "$n" ] && c=$((c+1)); done
  [ "$c" -gt 1 ] && dupes="$dupes $n"
done
[ -z "$dupes" ] && ok "no script is declared in two channels" \
                || bad "declared in more than one channel:$dupes"

# Retirement must propagate to the roster. The identical bug lived inside
# cut-verb-build.sh: a project that CHANGED was handled,
# a project that LEFT was not, so every consumer kept installing a verb the
# manifest no longer named. A roster naming a deleted file is that shape.
ghosts=""
for n in $ALL; do [ -f "$REPO/bin/$n" ] || ghosts="$ghosts $n"; done
[ -z "$ghosts" ] && ok "the roster names no script that has been deleted" \
                 || bad "roster names files that no longer exist:$ghosts"

# The bootstrap is the set that is COPIED onto every consumer. Copies rot; the
# only thing that makes a copy acceptable is that it is small and near-
# immutable. Bound it, or "just add it to the bootstrap" becomes the path of
# least resistance and the copy set becomes the toolset again.
n_boot=$(echo $PROP_BOOTSTRAP_SCRIPTS | wc -w)
if [ "$n_boot" -le 4 ]; then
  ok "bootstrap is $n_boot script(s), within the declared bound of 4"
else
  bad "bootstrap has grown to $n_boot scripts. Every one is COPIED into every"
  echo "       account and rots there. Move work into the payload, or raise this"
  echo "       bound HERE, deliberately, in a commit that says why."
fi

# verb name -> script basename (`gh` <- gh-sign.sh). The table moved out of
# bin/carry-drift.sh into bin/lib/carries.tsv when that guard was deleted
# (2026-08-22): the mapping answers a question about the repo, not about the
# guard that happened to hold it.
CARRIES_BLOCK="$(grep -v '^#' "$REPO/bin/lib/carries.tsv" | grep -v '^$')"

main_script_for() {
  local v="$1" line
  line="$(printf '%s\n' "$CARRIES_BLOCK" | awk -F'\t' -v p="bin/$v" '$1==p{print $2}')"
  if [ -n "$line" ]; then
    basename "$line"
  elif [ -f "$REPO/bin/$v.sh" ]; then
    printf '%s.sh' "$v"
  else
    printf '%s' "$v"
  fi
}

. "$REPO/bin/lib/verb-set.sh"
V_REF="$(verb_set_ref_of "$REPO")" || V_REF=""
if [ -z "$V_REF" ]; then
  bad "no bashified ref in this checkout -- cannot check declared verbs against the contract"
else
  declared_verbs="$(verb_set_verbs_of "$REPO" "$V_REF")"
  verb_bad=""; verb_going=""
  while read -r v; do
    [ -n "$v" ] || continue
    s="$(main_script_for "$v")"
    # A REMOVAL IN FLIGHT IS NOT DRIFT. bashified is derived FROM main, so
    # during a PR that deletes a verb's script the two cannot be in lockstep:
    # main has dropped it and the next cut has not run yet. Failing here would
    # make every deletion unmergeable, which is how a guard ends up protecting
    # the thing it was meant to let you change. A verb whose backing script is
    # still present and misclassified is a real finding and still fails.
    if [ ! -e "$REPO/bin/$s" ] && [ ! -e "$REPO/bin/lib/$s" ]; then
      verb_going="$verb_going $v"; continue
    fi
    ch="$(prop_channel "$s" 2>/dev/null)" || { verb_bad="$verb_bad $v(<-$s: unclassified)"; continue; }
    [ "$ch" = payload ] || verb_bad="$verb_bad $v(<-$s: $ch, not payload)"
  done <<< "$declared_verbs"
  [ -z "$verb_going" ] || echo "  ..      verb(s) awaiting the next cut to disappear:$verb_going"
  if [ -z "$verb_bad" ]; then
    ok "every verb this repo's bashified branch declares resolves to a PAYLOAD-class script"
  else
    bad "declared verb(s) whose backing script is not PAYLOAD-classified:$verb_bad"
  fi

  # A verb installs as a SYMLINK: sourcing lib/ without readlink -f fails
  # QUIETLY and the verb runs with no cli_guard (live on ausculte, 08-21).
  link_bad=""
  while read -r v; do
    [ -n "$v" ] || continue
    s="$(main_script_for "$v")"
    f="$REPO/bin/$s"
    [ -r "$f" ] || continue
    grep -q 'dirname "\${BASH_SOURCE\[0\]}")/lib/' "$f" && link_bad="$link_bad $v(<-$s)"
  done <<< "$declared_verbs"
  if [ -z "$link_bad" ]; then
    ok "every declared verb resolves its lib/ through readlink -f, so the symlink install works"
  else
    bad "verb(s) sourcing lib/ without readlink -f -- the guard will not load when installed as a symlink:$link_bad"
  fi
fi

carried_libexec="$(printf '%s\n' "$CARRIES_BLOCK" | awk -F'\t' '$1 ~ /^libexec\//{sub(/^libexec\//,"",$1); print $1}' | sort)"
probed_local="$(prop_host_tools 2>/dev/null | sort -u | while read -r s; do  # LOCAL probes only (#596), not dresse.sh/wire-*.sh
  [ -n "$s" ] || continue
  for m in $PROP_LOCAL_SCRIPTS; do [ "$m" = "$s" ] && printf '%s\n' "$s"; done
done | sort -u)"
if [ "$carried_libexec" = "$probed_local" ]; then
  ok "carries.tsv's libexec/* rows match prop_host_tools()'s LOCAL-class probes exactly"
else
  bad "carries.tsv's libexec/* rows and prop_host_tools()'s LOCAL-class probes disagree:"
  echo "       carried:  $(printf '%s' "$carried_libexec" | tr '\n' ' ')"
  echo "       probed:   $(printf '%s' "$probed_local" | tr '\n' ' ')"
  echo "       Add/remove the script in both bin/lib/carries.tsv and prop_host_tools()."
fi

# ===========================================================================
echo
echo "-- 1b. A HOST TOOL'S LIB REACHES THE HOST WHATEVER ITS EXTENSION -------"
# ===========================================================================
SHIPPED_LIBS="$(prop_support_libs "$REPO/bin")"
missing=""
for s in $PROP_BOOTSTRAP_SCRIPTS $(prop_host_tools); do
  [ -f "$REPO/bin/$s" ] || continue
  for l in $(grep -ohE 'lib/[a-z0-9-]+\.[a-z0-9]+' "$REPO/bin/$s" 2>/dev/null | sort -u); do
    [ -f "$REPO/bin/$l" ] || continue
    case $'\n'"$SHIPPED_LIBS"$'\n' in *$'\n'"$l"$'\n'*) ;; *) missing="$missing $s->$l" ;; esac
  done
done
[ -z "$missing" ] && ok "every lib/ file a shipped script names, and that exists on disk, is in prop_support_libs" \
                  || bad "named by a shipped script, present on disk, and NOT shipped:$missing"

echo
echo "-- 1c. A CARRIED SCRIPT'S LIB IS ITSELF CARRIED, NOT JUST NEEDED -------"
carried_libs="$(printf '%s\n' "$CARRIES_BLOCK" | awk -F'\t' '$1 ~ /^bin\/lib\//{sub(/^bin\//,"",$1); print $1}' | sort -u)"
carried_bin="$(printf '%s\n' "$CARRIES_BLOCK" | awk -F'\t' '$1 ~ /^bin\//{print $1"\t"$2}')"
unlisted=""
while IFS=$'\t' read -r carried src; do            # realisateur#682
  [ -n "${src:-}" ] || continue
  f="$REPO/$src"
  [ -f "$f" ] || continue
  for l in $(grep -E '^[[:space:]]*(\.|source)[[:space:]]' "$f" 2>/dev/null \
               | grep -ohE 'lib/[a-z0-9-]+\.[a-z0-9]+' | sort -u); do
    case $'\n'"$carried_libs"$'\n' in
      *$'\n'"$l"$'\n'*) ;;
      *) unlisted="$unlisted $carried->$l" ;;
    esac
  done
done <<EOF
$carried_bin
EOF
[ -z "$unlisted" ] && ok "every lib/ a carried script sources is itself a bin/lib/* row in carries.tsv" \
                   || bad "carried, sources a lib NOT in carries.tsv's bin/lib/* rows:$unlisted"

echo
echo "-- 1d. A LIB ALREADY ON bashified IS IN THE TABLE ----------------------"
if [ -n "$V_REF" ]; then
  frozen=""
  for l in $(git -C "$REPO" ls-tree --name-only "$V_REF" bin/lib/ 2>/dev/null); do
    case $'\n'"$carried_libs"$'\n' in *$'\n'"${l#bin/}"$'\n'*) ;; *) frozen="$frozen ${l#bin/lib/}" ;; esac
  done
  [ -z "$frozen" ] && ok "every bin/lib file already on bashified is a carries.tsv row, so carry.sh still refreshes it" \
                   || bad "on bashified but NOT in carries.tsv -- frozen there, a fix on main reaches it on no path:$frozen"
fi

# ===========================================================================
echo
echo "-- 2. main IS NOT A DEPLOY REF, AND THE LEAK MAY NOT GROW --------------"
# ===========================================================================
# The prize in separating dev from prod is that `main` gets to STAY FAST. If
# four live accounts pull `main` on a tick, every commit is a deployment and
# `main` must turn conservative to protect them -- backwards for a repo whose
n_leak=$(echo $PROP_PAYLOAD_PENDING | wc -w)
if [ "$n_leak" -le "$PROP_LEAK_BOUND" ]; then
  ok "clone-backed payload leak is $n_leak, within the bound of $PROP_LEAK_BOUND"
else
  bad "the clone-backed leak GREW to $n_leak (bound $PROP_LEAK_BOUND)."
  echo "       Each of these is a command whose live version comes from a git clone"
  echo "       of main, not from a named build. Fix by adding bin/<n> + man/<n>.1"
  echo "       to a bashified branch -- never by raising this bound."
fi
# The bound is a RATCHET: lowering it is the intended direction, so the test
# also insists the bound tracks reality rather than drifting above it.
if [ "$PROP_LEAK_BOUND" -le 10 ]; then
  ok "the leak bound has not been raised above its 2026-08-07 measurement (10)"
else
  bad "PROP_LEAK_BOUND was raised to $PROP_LEAK_BOUND. This bound only goes down."
fi

# No payload-class script may also be bootstrap. That would be the exact move
# that dissolves the split: "it is easier to copy it than to make it a verb".
for n in $PROP_PAYLOAD_SCRIPTS; do
  for m in $PROP_BOOTSTRAP_SCRIPTS; do
    [ "$n" = "$m" ] && bad "$n is both payload and bootstrap -- the split is dissolving"
  done
done
ok "no payload script has been reclassified into the bootstrap"

# ===========================================================================
echo
echo "-- 3. A CHANNEL WITH NO CLOCK IS NOT A CHANNEL -------------------------"
# ===========================================================================
# Each declared channel names the mechanism that ticks it, and that mechanism
# must exist. This assertion would have been RED on 2026-08-06, when the
# release channel's only consumer-side cadence was a human remembering.
for pair in "release-payload:$REPO/bin/selfdev-release-tick.sh" \
            "release-fetch:$REPO/bin/install-verb-build.sh" \
            "release-cut:$REPO/bin/cut-verb-build.sh"
do
  ch="${pair%%:*}"; mech="${pair#*:}"
  [ -x "$mech" ] && ok "channel '$ch' has a mechanism: $(basename "$mech")" \
                 || bad "channel '$ch' names $mech, which does not exist"
done

CH="$T/cronhome"; mkdir -p "$CH"
O="$(HOME="$CH" TICK_STATE="$CH/state" "$TICK" --install-cadence 2>&1)"; R=$?
has "--install-cadence prints a cron line" "$O" "* * * "
has "the cron line runs --apply, not --check" "$O" "--apply"
has "the cron line is tagged for attribution" "$O" "realisateur:selfdev-release:TICK"
has "--install-cadence without --apply installs nothing" "$O" "not installed (--check)"
rc "--install-cadence --check exits 0 (it reported, it did not fail)" 0 "$R"

# --- the other half: retiring the clock (hf7y/realisateur#180) -------------
# A per-account clock is retired when ONE host-wide channel feeds every
# account. The precondition is checked from INSIDE the account, because a
# $HOME/.local/bin entry earlier on that account's PATH shadows the host-wide
RH="$T/retirehome"; mkdir -p "$RH/.local/share/verb-builds/B" "$T/hostbin" "$T/shim"
ln -s B "$RH/.local/share/verb-builds/current"
printf '#!/bin/sh\nexit 0\n' > "$T/hostbin/dose"; chmod +x "$T/hostbin/dose"
# The shim is the fixture crontab: `crontab -l` prints the file, `crontab -`
# replaces it. Same contract the real one has, no spool touched.
cat > "$T/shim/crontab" <<SHIM
#!/bin/sh
F="$T/fixture.crontab"
case "\$1" in
  -l) [ -f "\$F" ] && cat "\$F" || { echo "no crontab for fixture" >&2; exit 1; } ;;
  -)  cat > "\$F" ;;
esac
SHIM
chmod +x "$T/shim/crontab"
retire() { HOME="$RH" TICK_STATE="$RH/state" VERB_BUILD_ROOT="$RH/.local/share/verb-builds" \
           TICK_HOST_BIN="$T/hostbin" PATH="$T/shim:$T/hostbin:/usr/bin:/bin" "$TICK" "$@" 2>&1; }

# Precondition unmet: the probe verb does not come from the host-wide dir.
O="$(HOME="$RH" TICK_STATE="$RH/state" VERB_BUILD_ROOT="$RH/.local/share/verb-builds" \
     TICK_HOST_BIN="$T/hostbin" PATH="$T/shim:/usr/bin:/bin" "$TICK" --retire-cadence --apply 2>&1)"; R=$?
has "--retire-cadence refuses when the host-wide channel does not resolve" "$O" "refusing to retire"
rc "the refusal is a finding, not a silence" 1 "$R"
[ -d "$RH/.local/share/verb-builds" ] && ok "the refused retire left the private pin alone" \
                                      || bad "the refused retire removed the private pin anyway"

printf '%s\n' "0 1 * * * /some/other/job # someone-else:KEEP" \
              "47 5 * * * $RH/tick.sh --apply # realisateur:selfdev-release:TICK" > "$T/fixture.crontab"
O="$(retire --retire-cadence)"
has "--retire-cadence without --apply removes nothing" "$O" "not removed (--check)"
has "the cron tag is still in the fixture crontab after --check" "$(cat "$T/fixture.crontab")" "selfdev-release:TICK"

O="$(retire --retire-cadence --apply)"; R=$?
rc "--retire-cadence --apply exits 0 when it retires cleanly" 0 "$R"
has "the removal is verified by re-reading crontab -l" "$O" "verified by re-reading"
hasnt "the tagged line is gone from the crontab" "$(cat "$T/fixture.crontab")" "selfdev-release:TICK"
has "every OTHER crontab line survives the retire" "$(cat "$T/fixture.crontab")" "someone-else:KEEP"
[ -d "$RH/.local/share/verb-builds" ] && bad "the private build root survived --retire-cadence --apply" \
                                      || ok "the private build root is gone after --retire-cadence --apply"
has "a machine-wide change tells the operator to notify senechal" "$O" "notify-senechal"
O="$(retire --retire-cadence --apply)"
has "--retire-cadence is idempotent (a second run is 'already retired')" "$O" "already retired"

# --- the shims that point INTO the build root go with it -------------------
# Removing the root and leaving $HOME/.local/bin pointing into it produces
# dangling links that PATH search skips -- so the host-wide verb still wins
# and nobody notices the debris. That was the realisateur account on
# 2026-08-13: 33 dead links from a hand retire, reported as finished.
SH="$T/shimhome"; mkdir -p "$SH/.local/share/verb-builds/B/scheduler/bin" "$SH/.local/bin"
ln -s B "$SH/.local/share/verb-builds/current"
printf '#!/bin/sh\nexit 0\n' > "$SH/.local/share/verb-builds/B/scheduler/bin/dose"
chmod +x "$SH/.local/share/verb-builds/B/scheduler/bin/dose"
ln -s "$SH/.local/share/verb-builds/current/scheduler/bin/dose" "$SH/.local/bin/dose"
ln -s /bin/sh "$SH/.local/bin/unrelated"        # points elsewhere: must survive
printf 'not-a-link\n' > "$SH/.local/bin/plainfile"
printf '%s\n' "47 5 * * * x --apply # realisateur:selfdev-release:TICK" > "$T/fixture.crontab"
shimretire() { HOME="$SH" TICK_STATE="$SH/state" VERB_BUILD_ROOT="$SH/.local/share/verb-builds" \
  TICK_LOCAL_BIN="$SH/.local/bin" TICK_HOST_BIN="$T/hostbin" \
  PATH="$T/shim:$T/hostbin:/usr/bin:/bin" "$TICK" "$@" 2>&1; }
O="$(shimretire --retire-cadence)"
has "--check counts the shims pointing into the build root" "$O" "would retire 1 shim"
O="$(shimretire --retire-cadence --apply)"
has "a shim into the build root is retired with it" "$O" "shim dose"
[ -L "$SH/.local/bin/dose" ] && bad "the shim into the build root survived the retire" \
                             || ok "no dangling shim is left behind by the retire"
[ -L "$SH/.local/bin/unrelated" ] && ok "a shim pointing OUTSIDE the build root is left alone" \
                                  || bad "the retire removed a shim it does not own"
[ -f "$SH/.local/bin/plainfile" ] && ok "a plain file in the bin dir is left alone" \
                                  || bad "the retire removed a file that is not a symlink"
O="$(shimretire --retire-cadence)"
has "a fully retired account reports already retired" "$O" "already retired"

# The realisateur-account shape exactly: root gone by hand, links left behind.
ln -s "$SH/.local/share/verb-builds/current/scheduler/bin/dose" "$SH/.local/bin/dose"
O="$(shimretire --retire-cadence)"
hasnt "an account with DANGLING shims is not reported as already retired" "$O" "already retired"
O="$(shimretire --retire-cadence --apply)"
[ -L "$SH/.local/bin/dose" ] && bad "a dangling shim survived the retire" \
                             || ok "a dangling shim is cleaned even with the build root already gone"

RETIRE_FN="$(sed -n '/^retire_cadence()/,/^}/p' "$TICK")"
hasnt "the retire never touches another account's crontab" "$RETIRE_FN" "sudo"
has "the retire refuses to delete a build root outside \$HOME" "$RETIRE_FN" 'refusing to remove'

# ===========================================================================
echo
echo "-- 4. A STOPPED CLOCK IS A FINDING -------------------------------------"
# ===========================================================================
# The property land-selfdev.sh:175 never had: it could go un-run forever and
# nothing anywhere was observably worse off.

# A fake installer, so the clock rows can be graded with no network at all.
mkinst() { # mkinst <path> <exit-code> <stdout>
  cat > "$1" <<EOF
#!/usr/bin/env bash
echo "$3"
exit $2
EOF
  chmod +x "$1"
}
INST_CURRENT="$T/inst-current.sh"; mkinst "$INST_CURRENT" 0 "verbs: up to date (build 2026-08-07T040739Z)"
INST_NEWER="$T/inst-newer.sh";     mkinst "$INST_NEWER"   1 "verbs: a newer build is available"
INST_BLIND="$T/inst-blind.sh";     mkinst "$INST_BLIND"   6 "install-verb-build.sh: BLIND -- cannot fetch"

mkdir -p "$T/s_fresh" "$T/s_old" "$T/s_none"
printf '2026-08-07T12:00:00Z rc=0 pin=2026-08-07T040739Z 2 ok\n' > "$T/s_fresh/selfdev-release-tick.status"
printf '2026-07-01T12:00:00Z rc=0 pin=old 2 ok\n' > "$T/s_old/selfdev-release-tick.status"
touch -d '40 hours ago' "$T/s_old/selfdev-release-tick.status"

# The tick now grades the RELEASE CHANNEL live, by fetching a URL. Keeping
# that hermetic matters: a suite that reaches zach.audio could not tell its
# own passing from the site being up. curl speaks file://, so the fixture IS
# the real code path -- same curl, same JSON parse, same grading -- with no
# network involved.
mkfix() { # mkfix <file> <decision> <hours-ago>
  local f="$1" d="$2" h="${3:-1}"
  local at; at="$(date -u -d "@$(( $(date -u +%s) - h * 3600 ))" +%Y-%m-%dT%H:%M:%SZ)"
  cat > "$f" <<EOF
{"schema":1,"generated":"$at","decision":"$d","reason":"fixture",
 "main_sha":"abc1234","ci_run":"1","build_id":"b1","blocked_streak":0,
 "last_cut":{"at":"$at","build_id":"b1"},
 "history":[{"at":"$at","decision":"$d","reason":"fixture","build_id":"b1"}]}
EOF
}
mkdir -p "$T/emptyhome"
mkfix "$T/status-ok.json" CUT 1
FIXURL="file://$T/status-ok.json"

tick() { # tick <state-dir> <installer> [args...]
  local s="$1" i="$2"; shift 2
  HOME="$T/emptyhome" TICK_STATE="$s" TICK_INSTALLER="$i" \
    VERB_BUILD_ROOT="$T/emptyhome/.local/share/verb-builds" \
    RELEASE_STATUS_URL="$FIXURL" \
    "$TICK" "$@" 2>&1
}

O="$(tick "$T/s_none" "$INST_CURRENT")"
has "an account that has NEVER ticked is a gap, by name" "$O" "NO CLOCK"
has "the no-clock row prints the command that installs one" "$O" "--install-cadence --apply"

O="$(tick "$T/s_old" "$INST_CURRENT")"; R=$?
has "a tick that stopped 40h ago is reported CLOCK DEAD" "$O" "CLOCK DEAD"
has "the dead-clock row states the limit it breached" "$O" "limit 26h"
has "the dead-clock row says nothing else would have noticed" "$O" "nothing else would have said so"
rc "a dead clock exits 1, not 0" 1 "$R"

O="$(tick "$T/s_fresh" "$INST_CURRENT")"; R=$?
has "a tick within the window is ok" "$O" "clock alive"
rc "current pin + live clock exits 0" 0 "$R"

# Offline: the whole clock grading must survive with ssh and sudo absent.
O="$(PATH="/usr/bin:/bin" tick "$T/s_old" "$INST_CURRENT")"
has "clock grading works with ssh and sudo unavailable" "$O" "CLOCK DEAD"

# ===========================================================================
echo
echo "-- 5. PULL, NOT PUSH ---------------------------------------------------"
# ===========================================================================
# Push needs a human holding the right credential, does not scale past four
# accounts, and leaves no trace on the consumer side. The account must own its
# clock. Asserted against the source, because this is exactly the property
# that erodes the first time reaching in is more convenient.

# Everything from the first line to the --survey machinery is the tick's own
# path. --survey and its account scan are allowed ssh and sudo -u.
APPLY_PATH="$(sed -n '1,/^survey_scan_accounts()/p' "$TICK")"
hasnt "the tick's own path contains no 'sudo -u'" "$APPLY_PATH" "sudo -u "
hasnt "the tick's own path contains no ssh" "$APPLY_PATH" "ssh -o"

# The cron line goes in the invoking account's OWN crontab -- `crontab -`, not
# `sudo -u <acct> crontab`.
CADENCE_FN="$(sed -n '/^install_cadence()/,/^}/p' "$TICK")"
has "the cadence is written to the invoking account's own crontab" "$CADENCE_FN" "crontab -"
hasnt "the cadence is not written into another account's crontab" "$CADENCE_FN" "sudo"
has "the cadence is verified by re-reading crontab -l, not by the write's rc" "$CADENCE_FN" "crontab -l"

# --survey may read, but must not adopt or write.
SURVEY_FN="$(sed -n '/^survey_scan_accounts()/,/^}/p; /^run_survey()/,/^}/p' "$TICK")"
hasnt "--survey never adopts a build" "$SURVEY_FN" "--apply"
hasnt "--survey never repoints a symlink" "$SURVEY_FN" "ln -s"

# AND IT MUST NOT CALL THE FINISHED MIGRATION A FINDING. Before #180 an account
# with no private pin had no consumer of the channel; after it, that is the
# COMPLETED state. Probed 2026-08-13 minutes after the last account was
# retired: this view reported "0 ok, 13 gap" about an estate where every
# account resolved every verb. An alarm that fires on success is one nobody
# reads the next time it fires on failure.
has "--survey grades the host-wide channel, not just the private pin" "$SURVEY_FN" "host-wide"
has "...by asking AS THE ACCOUNT, since its own PATH can shadow the host dir" "$SURVEY_FN" 'sudo -u "$user" -H'
has "...and an account with neither is still a finding" "$SURVEY_FN" "this account has no verbs"

has "run_survey resolves locally when already on SURVEY_HOST" "$SURVEY_FN" "on_target_host \"\$SURVEY_HOST\""
has "the local branch calls the scan directly, no ssh" "$SURVEY_FN" 'out="$(survey_scan_accounts)"'

# ===========================================================================
echo
echo "-- 5b. THE SWITCH IS DELEGATED, NEVER REIMPLEMENTED --------------------"
# ===========================================================================
# install-verb-build.sh verifies every verb the manifest promises and discards
# an incomplete build rather than switching to it -- 17 hermetic cases already
TICK_SRC="$(cat "$TICK")"
hasnt "the tick contains no symlink switching of its own" "$TICK_SRC" "ln -sfn"
hasnt "the tick contains no atomic-rename of its own" "$TICK_SRC" "mv -Tf"
has "the tick delegates adoption to install-verb-build.sh" "$TICK_SRC" '"$inst" --latest --apply'

# ===========================================================================
echo
echo "-- 5c. FAIL-OPEN ON OPERATION, FAIL-CLOSED ON ADOPTION -----------------"
# ===========================================================================
# An unreachable release channel must not stop the account. It keeps running
# the build it already has -- fully verified when installed -- and says BLIND
# loudly. The rule is "fail LOUD", not "fail STOPPED": halting a nightly tick
# on a network blip is just a different silent failure.

mkdir -p "$T/pinned/.local/share/verb-builds/2026-08-06T043915Z"
ln -sfn "$T/pinned/.local/share/verb-builds/2026-08-06T043915Z" \
        "$T/pinned/.local/share/verb-builds/current"
PIN_BEFORE="$(readlink "$T/pinned/.local/share/verb-builds/current")"

O="$(HOME="$T/pinned" TICK_STATE="$T/s_fresh" TICK_INSTALLER="$INST_BLIND" \
     VERB_BUILD_ROOT="$T/pinned/.local/share/verb-builds" "$TICK" --check 2>&1)"; R=$?
rc "an unreachable release channel exits 6 BLIND, not 0 and not 1" 6 "$R"
has "BLIND says it is not 'up to date'" "$O" "not 'up to date'"
has "BLIND names the fail-open choice explicitly" "$O" "fail-open on operation"
PIN_AFTER="$(readlink "$T/pinned/.local/share/verb-builds/current")"
[ "$PIN_BEFORE" = "$PIN_AFTER" ] \
  && ok "a BLIND channel left the account's pin exactly where it was" \
  || bad "a BLIND channel changed the pin ($PIN_BEFORE -> $PIN_AFTER)"

# BLIND must outrank "a newer build exists". Reporting "could not look" with
# the same code as "looked, and you are behind" is the whole garde failure.
O="$(HOME="$T/pinned" TICK_STATE="$T/s_fresh" TICK_INSTALLER="$INST_NEWER" \
     VERB_BUILD_ROOT="$T/pinned/.local/share/verb-builds" "$TICK" --check 2>&1)"; R=$?
rc "a reachable channel with a newer build exits 1" 1 "$R"
has "the newer-build row names this account's pin" "$O" "a newer build exists"

# Fail-CLOSED on adoption: a refused install must leave the pin alone and say
# the account is still in a known state.
INST_REFUSE="$T/inst-refuse.sh"
cat > "$INST_REFUSE" <<'EOF'
#!/usr/bin/env bash
case " $* " in
  *" --check "*) echo "verbs: a newer build is available"; exit 1 ;;
esac
echo "install-verb-build.sh: build is INCOMPLETE (3 missing verbs). Discarded, and current is unchanged." >&2
exit 1
EOF
chmod +x "$INST_REFUSE"
O="$(HOME="$T/pinned" TICK_STATE="$T/s_apply" TICK_INSTALLER="$INST_REFUSE" \
     VERB_BUILD_ROOT="$T/pinned/.local/share/verb-builds" "$TICK" --apply 2>&1)"; R=$?
has "a refused adoption is reported as refused, not as done" "$O" "adoption refused"
has "a refused adoption names the state the account is left in" "$O" "known verified state"
PIN_AFTER="$(readlink "$T/pinned/.local/share/verb-builds/current")"
[ "$PIN_BEFORE" = "$PIN_AFTER" ] \
  && ok "a refused adoption left the pin untouched (fail-closed)" \
  || bad "a refused adoption moved the pin ($PIN_BEFORE -> $PIN_AFTER)"
[ -f "$T/s_apply/selfdev-release-tick.status" ] \
  && ok "--apply recorded itself, so the next --check can grade the clock" \
  || bad "--apply wrote no status file; the clock cannot be graded"

# ===========================================================================
echo
echo "-- 5d. BLIND MUST ARRIVE IN TIME TO BE A VERDICT -----------------------"
# ===========================================================================
# realisateur#54. install-verb-build.sh reached the right verdict against an
# unroutable host and took 2m15s to do it (measured 2026-08-07 against
# 192.0.2.1, TEST-NET-1) -- the kernel's TCP retry, unbounded. A human hits
INST="$REPO/bin/install-verb-build.sh"
t0=$(date +%s)
O="$(VERB_BUILD_ROOT="$T/blindroot" VERB_BUILD_NET_TIMEOUT=1 \
     "$INST" --check --remote https://192.0.2.1/verbs.git 2>&1)"; R=$?
t1=$(date +%s)
rc "an unroutable remote reaches BLIND (exit 6), not a hang" 6 "$R"
has "BLIND names the bound it hit" "$O" "within 1s"
if [ $((t1 - t0)) -le 10 ]; then
  ok "BLIND arrived in $((t1-t0))s -- the network reach is bounded, not left to TCP retry"
else
  bad "BLIND took $((t1-t0))s despite a 1s bound; the timeout is not on the reach"
fi
has "the fetch bound is configurable rather than hardcoded" "$(cat "$INST")" "VERB_BUILD_NET_TIMEOUT"
has "a credential prompt cannot be the second way to hang" "$(cat "$INST")" "GIT_TERMINAL_PROMPT=0"

echo
echo "-- 5e. THE PAYLOAD-CLASS HOST TOOLS REFRESH ON THE CLOCK THAT ALREADY RUNS (#517)"  # only the libexec/ rows in the ADOPTED BUILD's own carries.tsv, and only for the host-wide tick -- a per-account tick must never touch a host-wide path even if the env var leaks in, and dresse.sh / provision-class scripts stay a human's act (carries.tsv's own note on why they are not carried)
HT="$T/hosttools"
mkdir -p "$HT/build/current/realisateur/bin/lib" "$HT/build/current/realisateur/libexec" "$HT/libexec"
printf 'libexec/ausculte-cadence.sh\tbin/ausculte-cadence.sh\nbin/gh\tbin/gh-sign.sh\n' \
  > "$HT/build/current/realisateur/bin/lib/carries.tsv"
printf '#!/usr/bin/env bash\necho cadence-v2\n' > "$HT/build/current/realisateur/libexec/ausculte-cadence.sh"
chmod +x "$HT/build/current/realisateur/libexec/ausculte-cadence.sh"

O="$(TICK_LINK=0 TICK_HOST_LIBEXEC="$HT/libexec" VERB_BUILD_ROOT="$HT/build" \
     TICK_STATE="$T/s_ht_a" TICK_INSTALLER="$INST_CURRENT" "$TICK" --check 2>&1)"
hasnt "TICK_LINK=0 never runs the host-tools section, even with the var set" "$O" "host tools (payload-class"
[ ! -e "$HT/libexec/ausculte-cadence.sh" ] \
  && ok "...and nothing was written to the host libexec dir" \
  || bad "a per-account tick wrote into the host libexec dir"

O="$(TICK_LINK=1 VERB_BUILD_ROOT="$HT/build" TICK_STATE="$T/s_ht_b" \
     TICK_INSTALLER="$INST_CURRENT" "$TICK" --check 2>&1)"; R=$?
has "TICK_LINK=1 with TICK_HOST_LIBEXEC unset now surfaces the section" "$O" "host tools (payload-class"
has "...as a gap naming the missing var" "$O" "TICK_HOST_LIBEXEC"
has "...pointing at the fix" "$O" "wire-release-channel.sh --host"
[ ! -e "$HT/libexec/ausculte-cadence.sh" ] \
  && ok "...and still nothing was written -- visibility only, not a new sync" \
  || bad "an unset TICK_HOST_LIBEXEC still wrote into a host libexec dir"
rc "the gap counts against the exit code -- no longer a clean 0" 1 "$R"

O="$(TICK_LINK=1 TICK_HOST_LIBEXEC="$HT/libexec" VERB_BUILD_ROOT="$HT/build" \
     TICK_STATE="$T/s_ht_c" TICK_INSTALLER="$INST_CURRENT" "$TICK" --check 2>&1)"
has "--check reports the missing host tool as a gap" "$O" "gap"
has "...naming it" "$O" "ausculte-cadence.sh"
has "...and the fix" "$O" "refresh: $TICK --apply"
[ ! -e "$HT/libexec/ausculte-cadence.sh" ] \
  && ok "--check writes nothing" || bad "--check installed a file"

O="$(TICK_LINK=1 TICK_HOST_LIBEXEC="$HT/libexec" VERB_BUILD_ROOT="$HT/build" \
     TICK_STATE="$T/s_ht_d" TICK_INSTALLER="$INST_CURRENT" "$TICK" --apply 2>&1)"
has "--apply refreshes it, ok not gap" "$O" "ok"
has "...naming it too" "$O" "ausculte-cadence.sh refreshed"
[ -x "$HT/libexec/ausculte-cadence.sh" ] \
  && ok "the file landed, executable" || bad "the file did not land executable"
eq "...with the adopted build's own content" \
  "$(cat "$HT/libexec/ausculte-cadence.sh")" \
  "$(cat "$HT/build/current/realisateur/libexec/ausculte-cadence.sh")"

O="$(TICK_LINK=1 TICK_HOST_LIBEXEC="$HT/libexec" VERB_BUILD_ROOT="$HT/build" \
     TICK_STATE="$T/s_ht_e" TICK_INSTALLER="$INST_CURRENT" "$TICK" --check 2>&1)"
has "a second --check now reports ok, matching the adopted build" "$O" "ok"
hasnt "and no gap remains for it" "$O" "stale or absent"

rm -f "$HT/build/current/realisateur/libexec/ausculte-cadence.sh"
O="$(TICK_LINK=1 TICK_HOST_LIBEXEC="$HT/libexec" VERB_BUILD_ROOT="$HT/build" \
     TICK_STATE="$T/s_ht_f" TICK_INSTALLER="$INST_CURRENT" "$TICK" --apply 2>&1)"
has "a carried file missing from the adopted build is reported bad, not silently skipped" "$O" "bad"
has "...naming it" "$O" "is not in the adopted build"

rm -f "$HT/build/current/realisateur/bin/lib/carries.tsv"
O="$(TICK_LINK=1 TICK_HOST_LIBEXEC="$HT/libexec" VERB_BUILD_ROOT="$HT/build" \
     TICK_STATE="$T/s_ht_g" TICK_INSTALLER="$INST_CURRENT" "$TICK" --check 2>&1)"
has "a missing carries.tsv in the adopted build is UNVERIFIED, not clean" "$O" "UNVERIFIED"

mkdir -p "$HT/build2/current/realisateur/bin/lib"
printf 'bin/gh\tbin/gh-sign.sh\n' > "$HT/build2/current/realisateur/bin/lib/carries.tsv"
O="$(TICK_LINK=1 TICK_HOST_LIBEXEC="$HT/libexec" VERB_BUILD_ROOT="$HT/build2" \
     TICK_STATE="$T/s_ht_h" TICK_INSTALLER="$INST_CURRENT" "$TICK" --check 2>&1)"
has "a carries.tsv with no libexec/ row says so, and is not a failure" "$O" "no libexec/ row"

# ===========================================================================
echo
echo "-- 6. FOUND NOTHING IS NOT NOTHING IS WRONG ----------------------------"
# ===========================================================================
# A consumer that cannot even find its bootstrap must not report "up to date".
O="$(HOME="$T/nobootstrap" TICK_STATE="$T/s_fresh" TICK_INSTALLER="$T/does-not-exist" \
     VERB_BUILD_ROOT="$T/nobootstrap/verb-builds" "$TICK" --check 2>&1)"; R=$?
has "a missing installer is BOOTSTRAP INCOMPLETE, by name" "$O" "BOOTSTRAP INCOMPLETE"
has "it says the account cannot obtain a build at all" "$O" "cannot obtain a build at all"
rc "a missing bootstrap exits non-zero" 1 "$R"

O="$(TICK_SURVEY_HOST="no-such-host.invalid" TICK_STATE="$T/s_fresh" \
     HOME="$T/emptyhome" "$TICK" --survey 2>&1)"; R=$?
rc "an unreachable survey host exits 6 BLIND, not 0" 6 "$R"
has "the unreachable survey says nothing was verified" "$O" "Nothing was verified"

mkdir -p "$T/localsurvey/stub"
cat > "$T/localsurvey/stub/ssh" <<EOF
#!/usr/bin/env bash
echo called >> "$T/localsurvey/ssh_called"
exit 255
EOF
chmod +x "$T/localsurvey/stub/ssh"
cat > "$T/localsurvey/stub/sudo" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
chmod +x "$T/localsurvey/stub/sudo"
printf 'acct1:x:3001:3001::/home/acct1:/bin/bash\n' > "$T/localsurvey/passwd"

O="$(PATH="$T/localsurvey/stub:$PATH" SELFDEV_LOCAL_HOSTNAME="testhost" \
     TICK_SURVEY_HOST="testhost" TICK_SURVEY_PASSWD="$T/localsurvey/passwd" \
     TICK_STATE="$T/s_fresh" HOME="$T/localsurvey/home" "$TICK" --survey 2>&1)"
[ -f "$T/localsurvey/ssh_called" ] \
  && bad "a local survey never shells out to ssh" "ssh was invoked" \
  || ok "a local survey never shells out to ssh"
has "a local survey still finds the fixture account" "$O" "acct1"

# ===========================================================================
echo
echo "-- 6b. EVERY ARTIFACT RECORDS THE BUILD THAT PRODUCED IT ---------------"
# ===========================================================================
# "What was ecosim running when it did that?" has to be answerable from the
# artifact alone, later, by someone who was not there. The value already
# existed (the pin); nothing recorded it at the moment work was created.

BR="$T/pinned/.local/share/verb-builds"     # has current -> 2026-08-06T043915Z
O="$(VERB_BUILD_ROOT="$BR" bash -c '. '"$SET_LIB"'; prop_build_trailer')"
has "a host with an adopted build stamps the build id" "$O" "Verb-Build: 2026-08-06T043915Z"

# BOTH roots are pointed at nothing. Naming only the private one stopped
# being a hermetic test when prop_current_pin learned the host-wide root:
# it would then quietly read /usr/local/share/verb-builds on any machine that
# has one, and pass or fail on the estate's state rather than the fixture's.
O="$(VERB_BUILD_ROOT="$T/no-such-build-root" VERB_HOST_BUILD_ROOT="$T/no-such-host-root" \
     bash -c '. '"$SET_LIB"'; prop_build_trailer')"
has "a host with NO build adopted stamps 'unknown', honestly" "$O" "Verb-Build: unknown"
hasnt "...and never invents a plausible build id" "$O" "2026-"

# The retire in hf7y/realisateur#180 removes the PRIVATE pin and leaves the
# account running the host-wide build. Probed live on 2026-08-13: the four
# accounts retired that morning stamped `Verb-Build: unknown` while running a
# perfectly well-known build out of /usr/local/bin. "Unknown" is the right
# answer to an unreadable pin and the wrong answer to a pin that moved.
HR="$T/hostbuilds"; mkdir -p "$HR/2026-08-12T183347Z"; ln -s 2026-08-12T183347Z "$HR/current"
O="$(VERB_BUILD_ROOT="$T/no-such-build-root" VERB_HOST_BUILD_ROOT="$HR" \
     bash -c '. '"$SET_LIB"'; prop_build_trailer')"
has "a retired account stamps the HOST-WIDE build, not 'unknown'" "$O" "Verb-Build: 2026-08-12T183347Z"

# Order matters and is not cosmetic: an account that still holds a private pin
# is RUNNING it, because its ~/.local/bin shims point into it and shadow the
# host-wide directory. Reporting the host build there would name a build that
# account is not executing.
O="$(VERB_BUILD_ROOT="$BR" VERB_HOST_BUILD_ROOT="$HR" \
     bash -c '. '"$SET_LIB"'; prop_build_trailer')"
has "a private pin still wins over the host-wide one while it exists" "$O" "Verb-Build: 2026-08-06T043915Z"

# The trailer must be emitted unconditionally: a stamper that emits nothing
# when it does not know produces an artifact indistinguishable from an
# unstamped one, which is the failure this exists to prevent.
[ -n "$O" ] && ok "the trailer is emitted even when the build is unknown" \
            || bad "an unknown build produced NO trailer -- unstamped and stamped-unknown are now identical"

# --- EVERY commit, not just the mandated ones ------------------------------
# The stamper must work for ANY commit, not only the ones a protocol mandates.
STAMPER="$REPO/bin/stamp-verb-build.sh"
SHOME="$T/stamphome"; mkdir -p "$SHOME"
: > "$SHOME/gitconfig"
stamp() { GIT_CONFIG_GLOBAL="$SHOME/gitconfig" STAMP_HOOK_DIR="$SHOME/hooks" \
          VERB_BUILD_ROOT="$T/no-such-build-root" VERB_HOST_BUILD_ROOT="$HR" \
          "$STAMPER" "$@" 2>&1; }

O="$(stamp)"; R=$?
has "--check reports an unwired account as not stamping" "$O" "does not stamp its commits"
rc "...and that is a finding, not a silence" 1 "$R"
[ -e "$SHOME/hooks/prepare-commit-msg" ] && bad "--check installed the hook anyway" \
                                         || ok "--check installs nothing"

O="$(stamp --apply)"; R=$?
rc "--apply exits 0 once the account stamps" 0 "$R"
has "the hook is witnessed by RUNNING it, not by its presence" "$O" "witnessed by running it"
has "...and it stamps the build the account actually resolves" "$O" "Verb-Build: 2026-08-12T183347Z"
has "an amend or rebase does not collect a second trailer" "$O" "does not add a second trailer"

# The end-to-end witness: a real `git commit` in a real repository. Everything
# above tests the hook; this tests that git RUNS it.
SREPO="$T/stamprepo"; mkdir -p "$SREPO"
# The build-root overrides go to the COMMIT too, not only to the installer.
# Without them the hook reads the real ~/.local/share/verb-builds of whoever
# runs the suite -- which is how this case passed on a workstation with a live
# pin and failed in CI, testing the machine instead of the fixture.
( cd "$SREPO" && git init -q . && echo x > f && git add f && \
  GIT_CONFIG_GLOBAL="$SHOME/gitconfig" VERB_BUILD_ROOT="$T/no-such-build-root" \
  VERB_HOST_BUILD_ROOT="$HR" git -c user.email=t@t -c user.name=t commit -q -m "work" ) >/dev/null 2>&1
O="$(cd "$SREPO" && git log -1 --format='%(trailers:key=Verb-Build,valueonly)' 2>/dev/null)"
has "a real commit carries the trailer, written by git itself" "$O" "2026-08-12T183347Z"

# A hooks directory someone else owns is not this command's to take: doing so
# would silently disable whatever else lives in it.
printf '[core]\n\thooksPath = /somebody/elses/hooks\n' > "$SHOME/gitconfig2"
O="$(GIT_CONFIG_GLOBAL="$SHOME/gitconfig2" STAMP_HOOK_DIR="$SHOME/hooks" \
     VERB_HOST_BUILD_ROOT="$HR" "$STAMPER" --apply 2>&1)"; R=$?
# And a config that cannot be PARSED is not an empty slot either.
printf 'this is not a git config\n' > "$SHOME/gitconfig3"
OB="$(GIT_CONFIG_GLOBAL="$SHOME/gitconfig3" STAMP_HOOK_DIR="$SHOME/hooks" \
      VERB_HOST_BUILD_ROOT="$HR" "$STAMPER" --apply 2>&1)"
has "an UNREADABLE git config is refused, not read as unset" "$OB" "not an empty one"
has "a foreign core.hooksPath is refused, not clobbered" "$O" "does not own"
rc "...and the refusal is a finding" 1 "$R"
grep -q "somebody/elses" "$SHOME/gitconfig2" && ok "...and the foreign setting is left exactly as it was" \
                                             || bad "the foreign core.hooksPath was overwritten"

O="$(stamp --retire --apply)"
has "--retire unsets it, verified by re-reading the config" "$O" "re-read"
[ -e "$SHOME/hooks/prepare-commit-msg" ] && bad "--retire left the hook file behind" \
                                         || ok "--retire removes the hook file too"

# ONE READER, with a NAMED exemption list rather than a loose rule.
#
# One script legitimately resolves the pin path because it OWNS the build
# layout. (#49 retired the other, ecosim-sensor-tick.sh, from this repo.)
PIN_OWNERS="install-verb-build.sh"
strays=""
for f in "$REPO"/bin/*.sh; do
  n="$(basename "$f")"
  case " $PIN_OWNERS " in *" $n "*) continue ;; esac
  grep -q 'verb-builds/current' "$f" 2>/dev/null && strays="$strays $n"
done
[ -z "$strays" ] && ok "only the $(echo $PIN_OWNERS | wc -w) layout-owning scripts resolve the pin path directly" \
                 || bad "these read the pin path instead of calling prop_build_trailer():$strays"

# ===========================================================================
echo
echo "-- 7. THE ARGUMENT CONTRACT --------------------------------------------"
# ===========================================================================
"$TICK" --not-a-real-flag >/dev/null 2>&1; rc "unknown flag exits 2" 2 $?
"$TICK" --help >/dev/null 2>&1;            rc "--help exits 0" 0 $?
O="$("$TICK" --help 2>&1)"
has "--help documents the BLIND exit" "$O" "BLIND"
has "--help says --check is the default and writes nothing" "$O" "--check (default)"

# ===========================================================================
echo
echo "-- 9. THE TICK REPAIRS A DRIFTED DECLARED IDENTITY (#1231) -------------"
# ===========================================================================
# An account may declare `test@example.com` in its global ~/.gitconfig while
# committing correctly as <acct>@selfdev.invalid. A drift probe reading commits
# cannot tell those apart, so it grades every real commit foreign and reports
# an account that is behaving -- loudly, and wired to nothing.
# Fixture passwd, fixture homes,
# TICK_SUDO="" -- and D2 below is the one that matters: a suite that writes the
# running user's own ~/.gitconfig is the bug it claims to be testing.

mkdir -p "$T/homes/drifted" "$T/homes/correct" "$T/homes/outofband"
printf 'drifted:x:3001:3001::%s/homes/drifted:/bin/bash\n' "$T" >  "$T/passwd"
printf 'correct:x:3002:3002::%s/homes/correct:/bin/bash\n'  "$T" >> "$T/passwd"
printf 'outofband:x:1001:1001::%s/homes/outofband:/bin/bash\n' "$T" >> "$T/passwd"

# the estate's real defect, in a fixture: declares the test address, commits as itself
HOME="$T/homes/drifted" git config --global user.name  test
HOME="$T/homes/drifted" git config --global user.email test@example.com
HOME="$T/homes/correct" git config --global user.name  correct
HOME="$T/homes/correct" git config --global user.email correct@selfdev.invalid
HOME="$T/homes/outofband" git config --global user.email test@example.com

MINE="$(git config --global --get user.email 2>/dev/null)"   # the runner's own, recorded BEFORE

tick() { TICK_SUDO="" TICK_SURVEY_PASSWD="$T/passwd" TICK_UID_MIN=3000 TICK_UID_MAX=3099 \
         VERB_BUILD_ROOT="$T/builds" bash "$TICK" --identity "$@" 2>&1; }
declared() { HOME="$T/homes/$1" git config --global --get user.email 2>/dev/null; }

section "A. --identity reports drift and changes nothing"
out="$(tick)"; rc "A0 a finding exits 1" 1 $?
has "A1 the drifted account is named with both values" "$out" "drifted declares test <test@example.com>"
has "A2 ...and the repair is spelled out, not described" "$out" "--identity --apply"
has "A3 an account that already declares itself is ok, not silent" "$out" "correct declares itself"
eq  "A4 --check wrote nothing" "$(declared drifted)" "test@example.com"

section "B. --identity --apply REPAIRS, and the witness is a re-read"
out="$(tick --apply)"; rc "B0 a clean repair exits 0" 0 $?
eq  "B1 the declaration now matches what the account commits as" \
  "$(declared drifted)" "drifted@selfdev.invalid"
eq  "B2 ...and the name with it" \
  "$(HOME="$T/homes/drifted" git config --global --get user.name)" "drifted"
has "B3 the repair names what it replaced, so a log reader can see it" "$out" "REPAIRED: was test <test@example.com>"

section "C. the previous value is preserved, once"
eq "C1 the overwritten address is recoverable" \
  "$(HOME="$T/homes/drifted" git config --global --get selfdev.previousUserEmail)" "test@example.com"
tick --apply >/dev/null
eq "C2 a re-run does NOT overwrite the backup with this function's own value" \
  "$(HOME="$T/homes/drifted" git config --global --get selfdev.previousUserEmail)" "test@example.com"

section "D. blast radius"
eq "D1 an account outside the uid band is never touched" \
  "$(declared outofband)" "test@example.com"
eq "D2 and the RUNNING USER's own global identity is untouched -- a test that writes a person's \$HOME config is the bug" \
  "$(git config --global --get user.email 2>/dev/null)" "$MINE"

section "E. it runs on the clock that already runs, not on a new one"
code="$(grep -v '^\s*#' "$TICK")"
has "E1 the host-wide tick calls it beside sync_host_tools" "$code" "reconcile_identities"
case "$code" in
  *'[ "$IDENTITY" = 1 ] || [ "$TICK_LINK" = 1 ] || return 0'*)
    ok "E2 gated to the host-wide tick (TICK_LINK=1) or an explicit --identity" ;;
  *) bad "E2 gated to the host-wide tick or --identity" "a per-account tick would write other accounts' configs" ;;
esac


echo
summary
