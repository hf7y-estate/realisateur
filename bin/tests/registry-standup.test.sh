#!/usr/bin/env bash
set -uo pipefail
# shellcheck source=bin/tests/lib/harness.sh
. "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib/harness.sh"
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not on PATH, this suite cannot run"; exit 0; }
SCRIPT="$(cd "$(dirname "$0")/.." && pwd)/registry-standup.sh"
[ -x "$SCRIPT" ] || { echo "FAIL: $SCRIPT not executable"; exit 1; }
harness_tmp

mkdir -p "$T/bin" "$T/runners"
cat > "$T/bin/gh" <<'STUB'
#!/usr/bin/env bash
shift                       # "api"
target="$1"; shift
prog=''
while [ $# -gt 0 ]; do case "$1" in --jq) prog="$2"; shift ;; esac; shift; done
case "$target" in
  graphql) [ -f "$STUB_GRAPHQL" ] || { echo "stub: HTTP 502 upstream" >&2; exit 1; }
           jq -r "$prog" < "$STUB_GRAPHQL" ;;
  */actions/runners) r="${target#repos/*/}"; r="${r%/actions/runners}"
           [ -f "$STUB_RUNNERS/$r.json" ] || { echo "stub: HTTP 403 on $r runners" >&2; exit 1; }
           jq -r "$prog" < "$STUB_RUNNERS/$r.json" ;;
  *) echo "stub: unexpected call: $target" >&2; exit 1 ;;
esac
STUB
chmod +x "$T/bin/gh"

echo '{"runners":[{"name":"monkey-beta"}]}' > "$T/runners/beta.json"
echo '{"runners":[]}'                       > "$T/runners/gamma.json"

node() { # name private hwf bwf hverb bverb [archived] [marker]
  jq -cn --arg n "$1" --argjson p "$2" --argjson h "$3" --argjson b "$4" \
        --argjson hv "$5" --argjson bv "$6" --argjson a "${7:-false}" --argjson m "${8:-true}" \
    '{name:$n, isArchived:$a, isPrivate:$p,
      marker:(if $m then {__typename:"Blob"} else null end),
      hverb:(if $hv then {__typename:"Blob"} else null end),
      bverb:(if $bv then {__typename:"Blob"} else null end),
      hwf:$h, bwf:$b}'
}
wf() { jq -cn --arg t "$2" --arg n "$1" '{entries:[{name:$n, object:{text:$t}}]}'; }
GUARDY="$(wf prose.yml   'jobs:
  prose:
    uses: hf7y-estate/etalon/.github/workflows/guard.yml@main')"
RUNTIMEY="$(wf runtime.yml 'jobs:
  runtime:
    uses: hf7y-estate/etalon/.github/workflows/guard.yml@main
    with:
      runtime: true')"
DECOY="$(wf other.yml 'env:
  runtime: true')"

registry() { jq -s '{data:{user:{repositories:{nodes:.}}}}' > "$1"; }
{ node alpha false "$GUARDY" "$RUNTIMEY" false true
  node beta  true  "$GUARDY" null        false false
  node gamma true  null      null        true  false
  node delta false "$GUARDY" "$DECOY"    false true
  node archived_one false "$GUARDY" null false false true
  node not_a_project false null null false false false false
} | registry "$T/full.json"
{ node alpha false "$GUARDY" "$RUNTIMEY" false true
  node beta  true  "$GUARDY" null        false false
} | registry "$T/clean.json"
{ node not_a_project false null null false false false false; } | registry "$T/empty.json"

run() { STUB_GRAPHQL="$1" STUB_RUNNERS="$T/runners" REGISTRY_STANDUP_GH="$T/bin/gh" \
          "$SCRIPT" --owner fixture "${@:2}" 2>&1; }

section "A. a project that was never stood up is reported, by name and by item"
out="$(run "$T/full.json")"; rc_a=$?
rc  "A1 findings exit 1" 1 "$rc_a"
has "A2 gamma owes the workflow"      "$out" "MISSING gamma"
has "A3 gamma owes the guard call"    "$out" "workflows calling hf7y-estate/etalon/.github/workflows/guard.yml"
has "A4 gamma owes the runtime job"   "$out" "runtime: true on the default branch"
has "A5 gamma owes a runner"          "$out" "a self-hosted runner"
has "A6 a bare input is not a guard"  "$out" "MISSING delta"
has "A7 and delta owes it on bashified" "$out" "runtime: true on bashified"
has "A8 alpha is stood up"            "$out" "OK      alpha"
has "A9 beta is stood up"             "$out" "OK      beta"
hasnt "A10 an archived repo is not graded"  "$out" "archived_one"
hasnt "A11 a repo without the marker is not graded" "$out" "not_a_project"
has "A12 the count is of what was graded"   "$out" "2 of 4 registered project(s) stood up, 2 owing"

section "B. a fully wired registry is clean"
out="$(run "$T/clean.json")"; rc_b=$?
rc  "B1 exit 0" 0 "$rc_b"
has "B2 and says so" "$out" "2 of 2 registered project(s) stood up, 0 owing"

section "C. the enumeration fails -- BLIND, never clean"
out="$(run "$T/no-such-file.json")"; rc_c=$?
rc  "C1 exit 6" 6 "$rc_c"
has "C2 it says BLIND"              "$out" "BLIND"
has "C3 and that nothing was graded" "$out" "NOT a clean result"
hasnt "C4 no project is graded"      "$out" "stood up,"

section "D. zero projects is BLIND, not zero findings"
out="$(run "$T/empty.json")"; rc_d=$?
rc  "D1 exit 6" 6 "$rc_d"
has "D2 absence is could-not-look" "$out" "never 'there are none'"
hasnt "D3 it does not report a clean registry" "$out" "0 owing"

section "E. a row that cannot be graded takes the whole run BLIND"
mv "$T/runners/beta.json" "$T/runners/beta.hidden"
out="$(run "$T/clean.json")"; rc_e=$?
mv "$T/runners/beta.hidden" "$T/runners/beta.json"
rc  "E1 exit 6" 6 "$rc_e"
has "E2 the row is named"          "$out" "BLIND   beta"
hasnt "E3 and the run is not clean" "$out" "0 owing"

section "F. --apply is refused, not silently a no-op"
out="$(run "$T/clean.json" --apply)"; rc_f=$?
rc  "F1 exit 7" 7 "$rc_f"
has "F2 it names where the fix lives" "$out" "senechal provisions on monkey"

summary
