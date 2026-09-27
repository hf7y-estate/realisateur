#!/usr/bin/env bash
#
# SUBJECT: bin/lib/cron-lock.sh -- the guard that stops a clock from stacking.
#
# THE DEFECT THIS PINS. A watcher ran from a crontab every ten minutes with
# ConnectTimeout and no lock. Its target wedged mid-auth -- TCP up, banner
# sent, never authenticated -- so ConnectTimeout, which bounds the CONNECT and
# not the session, expired on nothing. Every run hung, one per tick, and they
# stacked until a human looked. A timeout on the wrong phase is not a lock.
#
# So: B is the ratchet. A script that declares a cron cadence declares
# CRON_TAG, and this suite fails if such a script does not take the lock --
# which makes the next clock arrive locked instead of arriving hopeful.
#
# HERMETICITY: no network, no ssh, no crontab. A only flocks a file in $T;
# B greps the tree.

set -uo pipefail
. "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib/harness.sh"
REPO="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../.." && pwd)"
LIB="$REPO/bin/lib/cron-lock.sh"
harness_tmp

echo "cron-lock.test.sh"

section "A. a second tick leaves rather than stacking"
[ -f "$LIB" ] && ok "bin/lib/cron-lock.sh is present" \
  || { bad "bin/lib/cron-lock.sh is present" "the shared guard is gone"; summary; exit 1; }

# A runner that takes the lock, then reports whether it got to do work.
cat > "$T/tick.sh" <<'INNER'
#!/usr/bin/env bash
set -uo pipefail
. "$1"
cron_lock probe
echo "WORKED"
[ -n "${2:-}" ] && sleep "$2"
exit 0
INNER
chmod +x "$T/tick.sh"
export CRON_LOCK_FILE="$T/probe.lock"

out="$(bash "$T/tick.sh" "$LIB" 2>&1)"; r=$?
rc  "A1 an uncontended tick runs" 0 "$r"
has "A2 ...and reaches its work" "$out" "WORKED"

# Hold the lock in the background, then fire a second tick into it.
bash "$T/tick.sh" "$LIB" 3 >"$T/held.out" 2>&1 &
held=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do grep -q WORKED "$T/held.out" 2>/dev/null && break; done
out="$(bash "$T/tick.sh" "$LIB" 2>&1)"; r=$?
rc    "A3 the contended tick exits 0 -- a skipped tick is not a failure" 0 "$r"
hasnt "A4 ...and never reaches its work" "$out" "WORKED"
has   "A5 ...and says why, so the log is not silent" "$out" "already in flight"
kill "$held" 2>/dev/null; wait "$held" 2>/dev/null

has "A6 the lock path carries the uid -- 13 accounts share /tmp and one would deny twelve" \
  "$(grep -v '^#' "$LIB")" 'id -u'

section "B. every clock cron actually invokes takes the lock"
# Population comes from bin/lib/cron-invoked.tsv, not from a grep of this tree.
# A crontab line on another machine is not visible from here, and the one clock
# that stacked is exactly the one no derivation could have found.
REG="$REPO/bin/lib/cron-invoked.tsv"
[ -f "$REG" ] && ok "bin/lib/cron-invoked.tsv is present" \
  || { bad "bin/lib/cron-invoked.tsv is present" "the population is unknown; this suite would pass by scanning nothing"; summary; exit 1; }

rows=0
while IFS=$'\t' read -r script host cadence caller; do
  case "$script" in ''|'#'*) continue ;; esac
  rows=$((rows + 1))
  f="$REPO/bin/$script"
  [ -f "$f" ] && ok "$script exists -- $host, $cadence" \
    || { bad "$script exists" "cron on $host fires $cadence into a path this repo no longer has ($caller)"; continue; }
  body="$(grep -v '^[[:space:]]*#' "$f")"
  case "$body" in
    # NARROWED to cron_lock (#632). The `flock -n` spelling was accepted only
    # so #629's inline block and this library could land in either order; both
    # have, and monkey-watch.sh was the last inline copy. Accepting two
    # spellings from here on is how the second implementation comes back.
    *"cron_lock "*) ok "$script takes the shared non-blocking lock" ;;
    *"flock -n"*) bad "$script takes the SHARED non-blocking lock" \
         "it locks inline instead of calling cron_lock -- one implementation, per lib/cron-lock.sh; caller: $caller" ;;
    *) bad "$script takes a non-blocking lock" \
         "cron fires it every $cadence on $host and a run that outlives that becomes a pile; caller: $caller" ;;
  esac
done < "$REG"
[ "$rows" -gt 0 ] && ok "the registry named $rows clock(s)" \
  || bad "the registry names at least one clock" "cron-invoked.tsv has no rows -- this suite graded nothing"

section "C. a clock that declares itself cannot skip the registry"
for f in "$REPO"/bin/*.sh; do
  grep -q '^CRON_TAG=' "$f" || continue
  n="${f##*/}"
  if grep -q "^$n"$'\t' "$REG"; then ok "$n declares a CRON_TAG and has a registry row"
  else bad "$n has a registry row" \
         "it installs its own cron cadence and is not in bin/lib/cron-invoked.tsv, so B never graded it"; fi
done

summary
