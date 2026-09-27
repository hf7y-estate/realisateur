#!/usr/bin/env bash
set -uo pipefail
. "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib/harness.sh"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT/branch-protection-provision.sh"
[ -x "$SCRIPT" ] || { echo "FAIL: $SCRIPT not executable"; exit 1; }

harness_tmp
echo "branch-protection-provision.test.sh"

FIX="$T/fix"; mkdir -p "$FIX"
GH="$T/gh"
cat > "$GH" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GH_LOG"
[ "${1:-}" = api ] || exit 0
shift
if [ "${1:-}" = -X ]; then
  key="$(printf '%s' "$3" | tr -c 'A-Za-z0-9' '_')"
  if [ -n "${PUT_BODY_DIR:-}" ]; then cat > "$PUT_BODY_DIR/$key"; else cat >/dev/null; fi
  [ -f "$FIX/$key.after" ] && cp "$FIX/$key.after" "$FIX/$key"
  exit 0
fi
key="$(printf '%s' "$1" | tr -c 'A-Za-z0-9' '_')"
[ -f "$FIX/$key" ] || exit 1
cat "$FIX/$key"
STUB
chmod +x "$GH"

put() { local k; k="$(printf '%s' "$1" | tr -c 'A-Za-z0-9' '_')"; shift; cat > "$FIX/$k"; }

repo() {   # <name>; default branch, one workflow path, and the workflow body on stdin
  local n="$1"
  put "repos/hf7y-estate/$n" <<<'{"default_branch":"main"}'
  put "repos/hf7y-estate/$n/git/trees/main?recursive=1" \
    <<<'{"truncated":false,"tree":[{"path":".github/workflows/ci.yml"}]}'
  jq -Rs '{content: (. | @base64)}' > "$FIX/$(printf '%s' "repos/hf7y-estate/$n/contents/.github/workflows/ci.yml?ref=main" | tr -c 'A-Za-z0-9' '_')"
}

checks() {   # <name> <sha> <name-that-reached-a-conclusion>... -- one PR run and its conclusive checks
  local n="$1" sha="$2"; shift 2
  put "repos/hf7y-estate/$n/actions/runs?event=pull_request&per_page=50" \
    <<<"{\"workflow_runs\":[{\"id\":9,\"head_sha\":\"$sha\"}]}"
  printf '%s\n' "$@" | jq -R . | jq -s \
    '{check_runs: [.[] | {name: ., conclusion: "success", details_url: "https://x/actions/runs/9/job/1"}]}' \
    > "$FIX/$(printf '%s' "repos/hf7y-estate/$n/commits/$sha/check-runs?per_page=100" | tr -c 'A-Za-z0-9' '_')"
}

wf_one_job() { printf 'name: ci\non:\n  pull_request:\njobs:\n  %s:\n    runs-on: ubuntu-latest\n' "$1"; }

put graphql <<<'tidy
runsmore
wedged
advised'

repo tidy      < <(wf_one_job suites)
checks tidy aaa suites
put "repos/hf7y-estate/tidy/branches/main/protection" \
  <<<'{"required_status_checks":{"strict":false,"contexts":["suites"]},"enforce_admins":{"enabled":true}}'

repo runsmore  < <(printf 'name: ci\non:\n  pull_request:\njobs:\n  suites:\n    runs-on: x\n  lint:\n    runs-on: x\n')
checks runsmore bbb suites lint
put "repos/hf7y-estate/runsmore/branches/main/protection" \
  <<<'{"required_status_checks":{"strict":false,"contexts":["suites"]},"enforce_admins":{"enabled":false}}'
cp "$FIX/$(printf '%s' 'repos/hf7y-estate/runsmore/branches/main/protection' | tr -c 'A-Za-z0-9' '_')" \
   "$FIX/$(printf '%s' 'repos/hf7y-estate/runsmore/branches/main/protection' | tr -c 'A-Za-z0-9' '_').after"
python3 - "$FIX/$(printf '%s' 'repos/hf7y-estate/runsmore/branches/main/protection' | tr -c 'A-Za-z0-9' '_').after" <<'PY'
import json,sys
f=sys.argv[1]; d=json.load(open(f))
d["required_status_checks"]["contexts"]=["suites","lint"]
json.dump(d,open(f,"w"))
PY

repo wedged    < <(wf_one_job suites)
checks wedged ccc suites
put "repos/hf7y-estate/wedged/branches/main/protection" \
  <<<'{"required_status_checks":{"strict":false,"contexts":["ghost"]},"enforce_admins":{"enabled":false}}'

# advised: suites is already required; deploy-drift carries an ADVISORY
# marker directly above its job key and must never be proposed; lint carries
# no marker and must still be proposed, exactly like runsmore's.
repo advised   < <(printf 'name: ci\non:\n  pull_request:\njobs:\n  suites:\n    runs-on: ubuntu-latest\n  # ADVISORY: reads another repo; a required check a third party can break is a wedge\n  deploy-drift:\n    runs-on: ubuntu-latest\n  lint:\n    runs-on: ubuntu-latest\n')
checks advised ddd suites deploy-drift lint
put "repos/hf7y-estate/advised/branches/main/protection" \
  <<<'{"required_status_checks":{"strict":false,"contexts":["suites"]},"enforce_admins":{"enabled":false}}'
cp "$FIX/$(printf '%s' 'repos/hf7y-estate/advised/branches/main/protection' | tr -c 'A-Za-z0-9' '_')" \
   "$FIX/$(printf '%s' 'repos/hf7y-estate/advised/branches/main/protection' | tr -c 'A-Za-z0-9' '_').after"
python3 - "$FIX/$(printf '%s' 'repos/hf7y-estate/advised/branches/main/protection' | tr -c 'A-Za-z0-9' '_').after" <<'PY'
import json,sys
f=sys.argv[1]; d=json.load(open(f))
d["required_status_checks"]["contexts"]=["suites","lint"]
json.dump(d,open(f,"w"))
PY

run() { GH_LOG="$T/log" GH_BIN="$GH" FIX="$FIX" PUT_BODY_DIR="${PUT_BODY_DIR:-}" bash "$SCRIPT" "$@" 2>&1; }

section "A. the argument contract"
run --not-a-real-flag >/dev/null 2>&1; eq "A1 unknown flag exits 2" "$?" "2"
OUT="$(run --help)"; eq "A2 --help exits 0" "$?" "0"
has "A3 --help documents BLIND"   "$OUT" "BLIND"
has "A4 --help documents REFUSED" "$OUT" "REFUSED"
has "A5 --help says removal is out of scope" "$OUT" "OUT OF SCOPE"

section "B. a repo whose protection matches what it runs is clean"
: > "$T/log"; OUT="$(run tidy)"; RC=$?
eq  "B1 exits 0" "$RC" "0"
has "B2 says ok" "$OUT" "requires exactly what it runs"
hasnt "B3 proposes nothing" "$OUT" "MISSING"
hasnt "B4 wrote nothing" "$(cat "$T/log")" "-X PUT"

section "C. a repo missing a check it runs is a finding, with the remedy named"
: > "$T/log"; OUT="$(run runsmore)"; RC=$?
eq  "C1 exits 1" "$RC" "1"
has "C2 names the check it runs and does not require" "$OUT" "MISSING runs and does not require: lint"
has "C3 names the remedy" "$OUT" "remedy  require [suites,lint] on hf7y-estate/runsmore@main"
hasnt "C4 still wrote nothing" "$(cat "$T/log")" "-X PUT"

section "D. a required context no workflow produces is a WEDGE, never a proposal"
: > "$T/log"; OUT="$(run wedged)"; RC=$?
eq  "D1 exits 1" "$RC" "1"
has "D2 flagged as a wedge"        "$OUT" "WEDGE   required, and NO workflow produces it: ghost"
has "D3 says why it is unmergeable" "$OUT" "unmergeable"
has "D4 says it will not remove it" "$OUT" "will not remove it"
: > "$T/log"; OUT="$(run --apply wedged)"; RC=$?
eq  "D5 --apply on a wedged repo exits 7 REFUSED" "$RC" "7"
has "D6 and says removal is out of scope" "$OUT" "removal is out of scope"
hasnt "D7 and wrote nothing" "$(cat "$T/log")" "-X PUT"

section "E. --apply is the only path that writes"
: > "$T/log"; OUT="$(run runsmore)"
has "E1 without the flag it refuses the write in words" "$OUT" "no write: --apply was not given"
hasnt "E2 and made no PUT" "$(cat "$T/log")" "-X PUT"
: > "$T/log"; OUT="$(run --apply runsmore)"; RC=$?
has "E3 with the flag it PUTs" "$(cat "$T/log")" "-X PUT repos/hf7y-estate/runsmore/branches/main/protection"
has "E4 and re-reads to confirm" "$OUT" "applied now requires [suites,lint]"
eq  "E5 exits 0 once the delta is closed" "$RC" "0"

section "H. a job with its own ADVISORY marker is witnessed but never proposed as required (hf7y-estate/realisateur#949)"
: > "$T/log"; OUT="$(run advised)"; RC=$?
eq  "H1 exits 1 (lint is still a genuine finding)" "$RC" "1"
has "H2 still proposes the unmarked job" "$OUT" "MISSING runs and does not require: lint"
hasnt "H3 never folds the marked job into MISSING" "$OUT" "does not require: deploy-drift"
hasnt "H4 never folds it in alongside lint either" "$OUT" "does not require: lint,deploy-drift"
has "H5 reports it distinctly, by name" "$OUT" "ADVISORY deploy-drift"
has "H6 names the file the marker lives in" "$OUT" "per .github/workflows/ci.yml"
has "H7 the remedy proposed excludes it" "$OUT" "remedy  require [suites,lint] on hf7y-estate/advised@main"
PUT_BODY_DIR="$T/put"; mkdir -p "$PUT_BODY_DIR"
: > "$T/log"; OUT="$(run --apply advised)"; RC=$?
eq  "H8 --apply exits 0 once the delta (lint only) is closed" "$RC" "0"
BODY="$T/put/$(printf '%s' 'repos/hf7y-estate/advised/branches/main/protection' | tr -c 'A-Za-z0-9' '_')"
[ -f "$BODY" ] || { bad "H9 the PUT body was captured" "no file at $BODY"; }
hasnt "H10 the write itself never carries the marked job"  "$(cat "$BODY" 2>/dev/null)" "deploy-drift"
has   "H11 the write does carry the unmarked one"          "$(cat "$BODY" 2>/dev/null)" "lint"
unset PUT_BODY_DIR

section "F. could-not-look is BLIND, never clean"
: > "$T/log"; rm -f "$FIX/graphql"
OUT="$(run)"; RC=$?
eq  "F1 an unenumerable registry exits 6" "$RC" "6"
has "F2 and says BLIND"                   "$OUT" "BLIND"
hasnt "F3 and reports no repo as clean"   "$OUT" "requires exactly what it runs"
put graphql <<<'tidy
gone'
: > "$T/log"; OUT="$(run)"; RC=$?
eq  "F4 a repo that will not answer exits 6" "$RC" "6"
has "F5 and is named BLIND, not NOCI"        "$OUT" "BLIND   gone: the repo would not answer"
has "F6 and the counts are called untrustworthy" "$OUT" "NOT trustworthy"

section "G. it is declared, so it reaches a host by a named channel"
. "$ROOT/lib/propagation-set.sh"
ch="$(prop_channel branch-protection-provision.sh 2>/dev/null)" || ch=""
eq "G1 prop_channel says local -- its subject is the FLEET and it needs admin on someone else's repo" "$ch" "local"

echo
summary
