#!/usr/bin/env bash
# SUBJECT: bin/monkey-status-collect.py. Hermetic -- fixture home root, fixture
# sudoers dir, `find` stubbed: it cannot pass because the estate happened clean.
set -uo pipefail
. "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib/harness.sh"
harness_tmp
REPO="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../.." && pwd)"
COLLECTOR="$REPO/bin/monkey-status-collect.py"

echo "monkey-status-collect.test.sh"

mkdir -p "$T/homes/acct/.local/state" "$T/sudoers.d" "$T/stub"
STATUS="$T/homes/acct/.local/state/selfdev-release-tick.status"
printf '2026-08-13T05:49:02Z pin=2026-08-12T183347Z adopted\n' > "$STATUS"

cat > "$T/stub/find" <<'STUB'   # a case says what the sweep saw and its rc
#!/usr/bin/env bash
# ONE sweep answers every account now, so it prints `%U\t%p`: a case gives bare
# paths in FIND_OUT (all owned by FIND_UID) or uid-owned rows in FIND_ROWS.
[ -n "${FIND_OUT:-}" ] && printf '%s\n' "$FIND_OUT" | sed "s|^|${FIND_UID:-4242}\t|"
[ -n "${FIND_ROWS:-}" ] && printf '%s\n' "$FIND_ROWS"
exit "${FIND_RC:-0}"
STUB
chmod +x "$T/stub/find"

cat > "$T/probe.py" <<'PY'
import importlib.util, json, sys
spec = importlib.util.spec_from_file_location("collect", sys.argv[1])
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)                    # __name__ != "__main__": no sweep
if sys.argv[2] == "containment":
    print(json.dumps(m.containment("acct", 4242)))
elif sys.argv[2] == "dispatch_line":
    print(json.dumps(m.dispatch_line(json.loads(sys.argv[3]))))
elif sys.argv[2] == "armed":
    states = json.loads(sys.argv[4])
    print(json.dumps(m.armed(json.loads(sys.argv[3]), states, sys.argv[5])))
elif sys.argv[2] == "milestone_self_fed":
    print(json.dumps(m.milestone_self_fed(sys.argv[3])))
elif sys.argv[2] == "last_runs":
    print(json.dumps(m.last_runs(sys.argv[3])))
else:
    print(json.dumps(m.release_tick("acct", json.loads(sys.argv[3]))))
PY

probe() {
  PATH="$T/stub:$PATH" SELFDEV_HOME_ROOT="$T/homes" SELFDEV_SUDOERS_D="$T/sudoers.d" \
    PYTHONDONTWRITEBYTECODE=1 \
    python3 "$T/probe.py" "$COLLECTOR" "$@"
}

section "A. containment: an unreadable tree is not an empty one"
out="$(FIND_RC=1 FIND_OUT="/srv/thing" probe containment)"
eq "a failing find is null (BLIND), not a containment record" "$out" "null"

out="$(FIND_RC=1 FIND_OUT="" probe containment)"
eq "...and that holds when it also printed nothing -- the silent zero" "$out" "null"

section "B. containment: every path, not the first one find happened to reach"
out="$(FIND_RC=0 FIND_OUT="/srv/a
/var/backups/b
/etc/c" probe containment)"
eq "three files outside the home report three paths, not one" \
  "$(printf '%s' "$out" | jq '.outside_home | length')" "3"
has "and the hit behind the first is no longer masked" "$out" "/etc/c"
eq "every element is a plain string -- the page maps over them" \
  "$(printf '%s' "$out" | jq -r '[.outside_home[] | type] | unique | join(",")')" "string"

many="$(seq -f '/srv/f%g' 1 25)"
out="$(FIND_RC=0 FIND_OUT="$many" probe containment)"
eq "25 hits are capped at 20 plus one line naming the rest" \
  "$(printf '%s' "$out" | jq '.outside_home | length')" "21"
eq "and the remainder is counted honestly" \
  "$(printf '%s' "$out" | jq -r '.outside_home[-1]')" "... and 5 more"

section "D2. containment: one sweep, and each account gets only its own rows"
out="$(FIND_ROWS="$(printf '4242\t/srv/mine\n4243\t/srv/theirs')" probe containment)"
eq "a path owned by another account is not attributed to this one" \
  "$(printf '%s' "$out" | jq -r '.outside_home | join(",")')" "/srv/mine"

out="$(FIND_UID=4243 FIND_OUT="/srv/only-theirs" probe containment)"
eq "an account with no rows of its own reports none -- and is not null" \
  "$(printf '%s' "$out" | jq -r '.outside_home | length')" "0"

section "E. containment: foreign_clones exempts the account's own repo and the one universal bootstrap clone"
mkdir -p "$T/homes/acct2/Documents/Projects/acct2" \
         "$T/homes/acct2/Documents/Projects/realisateur" \
         "$T/homes/acct2/Documents/Projects/scheduler" \
         "$T/homes/acct2/Documents/Projects/stray"
mkrepo() { # mkrepo <dir> <origin-url>
  git init -q "$1"
  git -C "$1" remote add origin "$2"
}
mkrepo "$T/homes/acct2/Documents/Projects/acct2"       "https://github.com/hf7y/acct2.git"
mkrepo "$T/homes/acct2/Documents/Projects/realisateur" "https://github.com/hf7y/realisateur.git"
mkrepo "$T/homes/acct2/Documents/Projects/scheduler"   "https://github.com/hf7y/scheduler.git"
mkrepo "$T/homes/acct2/Documents/Projects/stray"       "https://github.com/hf7y/some-other-project.git"

cat > "$T/probe2.py" <<'PY'
import importlib.util, json, sys
spec = importlib.util.spec_from_file_location("collect", sys.argv[1])
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
print(json.dumps(m.containment("acct2", 4242)))
PY
out="$(PATH="$T/stub:$PATH" SELFDEV_HOME_ROOT="$T/homes" SELFDEV_SUDOERS_D="$T/sudoers.d" \
  PYTHONDONTWRITEBYTECODE=1 FIND_RC=0 FIND_OUT="" \
  python3 "$T/probe2.py" "$COLLECTOR")"
eq "the account's own repo and the scheduler bootstrap clone are NOT foreign" \
  "$(printf '%s' "$out" | jq '.foreign_clones | length')" "2"
has "the one real foreign clone is named" "$out" "/Projects/stray"
# jq, not a substring: the old spelling matched '"path":"' which json.dumps
# never emits (it writes '"path": "'), so it passed no matter what.
eq "realisateur IS foreign now that #134 stopped minting it per account" \
  "$(printf '%s' "$out" | jq '[.foreign_clones[] | select(.path | endswith("/Documents/Projects/realisateur"))] | length')" "1"
eq "scheduler is never reported foreign" \
  "$(printf '%s' "$out" | jq '[.foreign_clones[] | select(.path | endswith("/Documents/Projects/scheduler"))] | length')" "0"

mkdir -p "$T/homes/acct2/Documents/Projects/scheduler/schedule" \
         "$T/homes/acct2/Documents/Projects/renamed"
mkrepo "$T/homes/acct2/Documents/Projects/renamed" "https://github.com/hf7y/renamed-1234.git"
printf 'REPO_URL="https://github.com/hf7y/renamed-1234.git"\n' \
  > "$T/homes/acct2/Documents/Projects/scheduler/schedule/renamed.conf"
out="$(PATH="$T/stub:$PATH" SELFDEV_HOME_ROOT="$T/homes" SELFDEV_SUDOERS_D="$T/sudoers.d" \
  PYTHONDONTWRITEBYTECODE=1 FIND_RC=0 FIND_OUT="" \
  python3 "$T/probe2.py" "$COLLECTOR")"
eq "a clone whose conf DECLARES its differently-named repo is not foreign" \
  "$(printf '%s' "$out" | jq '[.foreign_clones[] | select(.path | endswith("/Documents/Projects/renamed"))] | length')" "0"
eq "and the genuinely stray clone is still reported" \
  "$(printf '%s' "$out" | jq '[.foreign_clones[] | select(.path | endswith("/Documents/Projects/stray"))] | length')" "1"

section "E1. own_repo_url: the account's own clone's remote, never a guess (#927, #928)"
cat > "$T/probe2b.py" <<'PY'
import importlib.util, json, sys
spec = importlib.util.spec_from_file_location("collect", sys.argv[1])
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
print(json.dumps(m.own_repo_url(sys.argv[2])))
PY
orp() { PATH="$T/stub:$PATH" SELFDEV_HOME_ROOT="$T/homes" PYTHONDONTWRITEBYTECODE=1 \
  python3 "$T/probe2b.py" "$COLLECTOR" "$1"; }
out="$(orp acct2)"
eq "acct2's own clone reports its real origin" "$out" '"https://github.com/hf7y/acct2.git"'
out="$(orp nosuchaccount)"
eq "an account with no clone by its own name reports null, not a guessed URL" "$out" "null"

section "C. release_tick: a retired clock is an absence, not a reading"
[ -s "$STATUS" ] && ok "the fixture account HAS a status file to be tempted by" \
  || bad "fixture status file" "missing, so the case below proves nothing"

out="$(probe release_tick '["17 * * * * /usr/local/bin/selfdev-runner batch"]')"
eq "a crontab with no TICK line reads null, however fresh the file looks" "$out" "null"

out="$(probe release_tick '[]')"
eq "an empty crontab reads null too" "$out" "null"

out="$(probe release_tick '["47 5 * * * tick.sh --apply # realisateur:selfdev-release:TICK"]')"
has "an account that still HAS a tick still publishes its last line" "$out" "pin=2026-08-12T183347Z"

section "D. dispatch_line: the cron tag, not a word anywhere in the crontab"
RUN='["*/5 * * * * PACED_MAX_PER_TICK=16 /home/zach/.local/bin/usage-paced-runner.sh # scheduler:scheduler-paced-runner:RUNNER (usage-paced dispatch)"]'
out="$(probe dispatch_line "$RUN")"
eq "a line carrying the RUNNER tag IS a dispatch line" "$out" "true"

out="$(probe dispatch_line '["*/15 * * * * /home/zach/.local/bin/sync-crontab.sh # scheduler:sync-crontab:SYNC"]')"
eq "a sync-only line that merely mentions scheduler is NOT one" "$out" "false"

out="$(probe dispatch_line '["17 * * * * /usr/local/bin/some-runner-script.sh"]')"
eq "a line that happens to contain the word runner is NOT one" "$out" "false"

out="$(probe dispatch_line '[]')"
eq "an empty crontab is not one" "$out" "false"

section "E. armed: BOTH halves -- the line AND schedule/ROSTER (scheduler#364)"
out="$(probe armed "$RUN" '{"acct":"parked"}' acct)"
eq "PARKED row + dispatch line is NOT armed -- 18 of these read armed 2026-08-31, fleet dark 39h" "$out" "false"

out="$(probe armed "$RUN" '{"acct":"live"}' acct)"
eq "a dispatch line whose ROSTER row is LIVE is armed" "$out" "true"

out="$(probe armed '[]' '{"acct":"live"}' acct)"
eq "a live ROSTER row with no dispatch line is not armed" "$out" "false"

section "H. last_runs: a negative-offset started_at republishes as UTC Z (#919)"
mkdir -p "$T/homes/tzuser/.local/share/scheduler-runs"
cat > "$T/homes/tzuser/.local/share/scheduler-runs/2026-09-01.jsonl" <<'JSONL'
{"run_id":"r1","job":"batch","started_at":"2026-09-01T00:30:45-05:00","ended_at":"2026-09-01T00:45:00-05:00","rc":0}
{"run_id":"r0","job":"batch","started_at":"garbage","rc":1}
JSONL
out="$(probe last_runs tzuser)"
eq "-05:00 converts to the same instant in Z, not a naive suffix swap" \
  "$(printf '%s' "$out" | jq -r '.[] | select(.run_id == "r1") | .started_at')" "2026-09-01T05:30:45Z"
eq "ended_at is normalised too, not just the field ausculte's arming probe reads" \
  "$(printf '%s' "$out" | jq -r '.[] | select(.run_id == "r1") | .ended_at')" "2026-09-01T05:45:00Z"
eq "a value that isn't a timestamp is passed through, not guessed at" \
  "$(printf '%s' "$out" | jq -r '.[] | select(.run_id == "r0") | .started_at')" "garbage"

out="$(probe armed "$RUN" '{}' acct)"
eq "a roster that names no row for this account is not armed" "$out" "false"

out="$(probe armed "$RUN" 'null' acct)"
eq "an UNREADABLE roster is null, not false -- could-not-look is not not-armed" "$out" "null"

out="$(probe armed '[]' 'null' acct)"
eq "...but with no dispatch line the answer is knowable: false" "$out" "false"

section "E2. milestone_self_fed: the row after MILESTONE-SELF-FED is the real outcome (#575/#614)"
LEDGER_DIR="$T/homes/fed/.local/share/scheduler-paced-runner"
mkdir -p "$LEDGER_DIR"
LEDGER="$LEDGER_DIR/ledger.tsv"
row() { printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$1" host acct proj batch - "$2" "$3" >> "$LEDGER"; }

out="$(probe milestone_self_fed fed)"
eq "no ledger at all is null, not a verdict" "$out" "null"

: > "$LEDGER"
row 2026-09-01T00:00:00+00:00 WORKED "did work"
out="$(probe milestone_self_fed fed)"
eq "a real dispatch never preceded by MILESTONE-SELF-FED is not self-fed" \
  "$(printf '%s' "$out" | jq -r .current)" "false"
eq "...streak is 0" "$(printf '%s' "$out" | jq .streak)" "0"

: > "$LEDGER"
row 2026-09-01T00:00:00+00:00 WORKED "did work"
row 2026-09-02T00:00:00+00:00 MILESTONE-SELF-FED "agent-filed only"
row 2026-09-02T00:05:00+00:00 IDLE "nothing landed"
out="$(probe milestone_self_fed fed)"
eq "the row right after MILESTONE-SELF-FED is read as that tick's self-fed outcome" \
  "$(printf '%s' "$out" | jq -r .current)" "true"
eq "one such tick is a streak of 1" "$(printf '%s' "$out" | jq .streak)" "1"
eq "since names the MILESTONE-SELF-FED row's own timestamp" \
  "$(printf '%s' "$out" | jq -r .since)" "2026-09-02T00:00:00+00:00"

row 2026-09-03T00:00:00+00:00 MILESTONE-SELF-FED "agent-filed only"
row 2026-09-03T00:05:00+00:00 WORKED "landed something"
out="$(probe milestone_self_fed fed)"
eq "a second consecutive self-fed tick extends the streak" "$(printf '%s' "$out" | jq .streak)" "2"
eq "since still points at the OLDEST row of the current streak" \
  "$(printf '%s' "$out" | jq -r .since)" "2026-09-02T00:00:00+00:00"

row 2026-09-04T00:00:00+00:00 WORKED "a human-fed tick, no MILESTONE-SELF-FED row before it"
out="$(probe milestone_self_fed fed)"
eq "a human-fed tick breaks the streak" "$(printf '%s' "$out" | jq -r .current)" "false"
eq "streak resets to 0, but history is not lost -- still object, not null" \
  "$(printf '%s' "$out" | jq .streak)" "0"

: > "$LEDGER"
row 2026-09-01T00:00:00+00:00 COOLDOWN "held after DONE"
row 2026-09-01T00:20:00+00:00 MILESTONE-HELD "empty milestone"
row 2026-09-01T00:40:00+00:00 MILESTONE-SELF-FED "agent-filed only"
row 2026-09-01T00:45:00+00:00 WORKED "landed"
out="$(probe milestone_self_fed fed)"
eq "hold rows (COOLDOWN, MILESTONE-HELD) are never mistaken for a dispatch" \
  "$(printf '%s' "$out" | jq .streak)" "1"

section "F. identity_drift: an account that did not commit as itself (#841)"
IH="$T/homes/ident"
mkdir -p "$IH/Documents/Projects"
printf '[user]\n\temail = ident@selfdev.invalid\n' > "$IH/.gitconfig"
UP="$T/upstream.git"; git init -q --bare "$UP"

mkclone() { # mkclone <name>; leaves a clone with an origin and one pushed commit
  local d="$IH/Documents/Projects/$1"
  git clone -q "$UP" "$d" 2>/dev/null || { git init -q "$d"; git -C "$d" remote add origin "$UP"; }
  git -C "$d" -c user.email=ident@selfdev.invalid -c user.name=ident \
    commit -q --allow-empty -m base
  git -C "$d" push -q origin HEAD:refs/heads/main 2>/dev/null
  git -C "$d" fetch -q origin 2>/dev/null
}

cat > "$T/probe3.py" <<'PY3'
import importlib.util, json, sys
spec = importlib.util.spec_from_file_location("collect", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
print(json.dumps(m.identity_drift("ident")))
PY3
iprobe() { SELFDEV_HOME_ROOT="$T/homes" PYTHONDONTWRITEBYTECODE=1 \
  python3 "$T/probe3.py" "$COLLECTOR"; }

out="$(iprobe)"
eq "an account whose clones all commit as itself has nothing to report" \
  "$(printf '%s' "$out" | jq '.clones | length')" "0"
eq "...and it is a MEASUREMENT, not a null" \
  "$(printf '%s' "$out" | jq -r 'type')" "object"

mkclone clean
out="$(iprobe)"
eq "a clone whose only commit is pushed and its own is clean" \
  "$(printf '%s' "$out" | jq '.clones | length')" "0"

mkclone forged
git -C "$IH/Documents/Projects/forged" -c user.name="t" -c user.email="dangerpine@gmail.com" \
  commit -q --no-verify --allow-empty -m "remove the .idea residue already deleted upstream"
out="$(iprobe)"
eq "an unpushed commit typed in under a human's identity is caught" \
  "$(printf '%s' "$out" | jq '[.clones[] | select(.path | endswith("/forged"))] | length')" "1"
eq "and it is counted, not merely noticed" \
  "$(printf '%s' "$out" | jq '.clones[] | select(.path | endswith("/forged")) | .count')" "1"
has "the offending identity is named, so the finding is actionable" "$out" "dangerpine@gmail.com"
eq "nothing on disk explains it -- local_identity is null, which is the point" \
  "$(printf '%s' "$out" | jq -r '.clones[] | select(.path | endswith("/forged")) | .local_identity')" "null"

mkclone fetched
FD="$IH/Documents/Projects/fetched"
git -C "$FD" -c user.name=zach -c user.email=dangerpine@gmail.com \
  commit -q --allow-empty -m "a human's commit, pushed"
git -C "$FD" push -q origin HEAD:refs/heads/human
git -C "$FD" fetch -q origin
out="$(iprobe)"
eq "a foreign-committed commit that IS on a remote ref is not a finding" \
  "$(printf '%s' "$out" | jq '[.clones[] | select(.path | endswith("/fetched"))] | length')" "0"

mkclone overridden
OD="$IH/Documents/Projects/overridden"
git -C "$OD" config user.email hf7y@example.invalid
for i in 1 2 3; do git -C "$OD" commit -q --allow-empty -m "local $i"; done
out="$(iprobe)"
eq "a clone configured to commit as someone else is one finding" \
  "$(printf '%s' "$out" | jq '.clones[] | select(.path | endswith("/overridden")) | .local_identity')" \
  '"hf7y@example.invalid"'
eq "...and its own commits are not counted a second time against it" \
  "$(printf '%s' "$out" | jq '.clones[] | select(.path | endswith("/overridden")) | .count')" "0"

section "G. identity_drift: could-not-look is not clean"
mkdir -p "$T/homes/noident/Documents/Projects"
cat > "$T/probe4.py" <<'PY4'
import importlib.util, json, sys
spec = importlib.util.spec_from_file_location("collect", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
print(json.dumps(m.identity_drift(sys.argv[2])))
PY4
out="$(SELFDEV_HOME_ROOT="$T/homes" PYTHONDONTWRITEBYTECODE=1 python3 "$T/probe4.py" "$COLLECTOR" noident)"
eq "an account with no readable identity of its own is BLIND, not clean" "$out" "null"

cat > "$T/stub/git" <<'STUB'
#!/usr/bin/env bash
for a in "$@"; do [ "$a" = log ] && exit 128; done
exec /usr/bin/git "$@"
STUB
chmod +x "$T/stub/git"
out="$(PATH="$T/stub:$PATH" SELFDEV_HOME_ROOT="$T/homes" PYTHONDONTWRITEBYTECODE=1 \
  python3 "$T/probe4.py" "$COLLECTOR" ident)"
eq "a git log that refuses (dubious ownership prints NOTHING) is null, not zero" "$out" "null"

summary
