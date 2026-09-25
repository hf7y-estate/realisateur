#!/usr/bin/env bash
# registry-standup.sh -- which registered projects no guard has ever run in.
set -uo pipefail

CLI_NAME='registry-standup.sh'
CLI_SUMMARY='which registered projects were never stood up with the guard wiring, so no guard has ever run there'
CLI_USAGE='  registry-standup.sh                 --check (default): report, write nothing
  registry-standup.sh --owner <o>     grade another account'"'"'s registry'
CLI_FLAGS='--check --apply --owner'
CLI_POSITIONAL=any   # flag VALUES (--owner <o>) read as positionals to cli-guard.
CLI_EXITS='  0  every registered project carries the wiring
  1  findings: at least one project is missing a required item
  2  usage error
  6  BLIND -- the registry could not be enumerated, or a row could not be
     graded. NEVER "clean": zero projects graded is not zero findings.
  7  REFUSED -- --apply. The fix is a pull request in the project'"'"'s own repo.'
. "$(dirname "${BASH_SOURCE[0]}")/lib/cli-guard.sh"
cli_guard "$@"

. "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib/estate-set.sh"
OWNER="$GH_ESTATE_OWNER"
GH="${REGISTRY_STANDUP_GH:-gh}"
REGISTRY_GH="$GH"
. "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib/registry-set.sh"
REGISTRY_MARKER="${REGISTRY_MARKER:-.agent-project}"   # bin/cut-verb-build.sh
RUNTIME_PATH="${RUNTIME_PATH:-lib/verb.sh}"            # guard.yml's runtime_path default
GUARD_REF="$OWNER/etalon/.github/workflows/guard.yml"

while [ $# -gt 0 ]; do
  case "$1" in
    --check) ;;
    --apply)
      printf '%s: REFUSED -- nothing here can be applied. Each finding is a pull\n' "$CLI_NAME" >&2
      printf "request in the project's OWN repo (a workflow file it does not carry),\n" >&2
      printf 'or a runner, which senechal provisions on monkey.\n' >&2
      exit 7 ;;
    --owner) OWNER="${2:?--owner needs a value}"; shift ;;
    *) printf '%s: unknown argument: %s\n' "$CLI_NAME" "$1" >&2; exit 2 ;;
  esac
  shift
done

ERR="$(mktemp)"; trap 'rm -f "$ERR"' EXIT
blind() { printf '\n%s: BLIND -- %s\n' "$CLI_NAME" "$*" >&2
          printf '%s: nothing was graded. This is NOT a clean result.\n' "$CLI_NAME" >&2
          exit 6; }

command -v "$GH" >/dev/null 2>&1 || blind "$GH is not on PATH -- the registry cannot be read"

echo "== registry-standup (--check) -- $OWNER, marker $REGISTRY_MARKER =="

# The node fields THIS script needs, spliced into lib/registry-set.sh's marker
# query. name/isArchived/isPrivate/marker come from the lib -- "which repos
# count" is defined once, and only the extra reads are typed here.
Q="$(registry_query '
    hverb:  object(expression:"HEAD:'"$RUNTIME_PATH"'"){ __typename }
    bverb:  object(expression:"bashified:'"$RUNTIME_PATH"'"){ __typename }
    hwf: object(expression:"HEAD:.github/workflows"){ ... on Tree { entries { name object { ... on Blob { text } } } } }
    bwf: object(expression:"bashified:.github/workflows"){ ... on Tree { entries { name object { ... on Blob { text } } } } }
')"

JQ='def wf($t): [($t.entries // [])[] | .object.text // ""];
    def calls: contains("'"$GUARD_REF"'");
    def wires: calls and test("runtime:[ \\t]*true");
    '"$REGISTRY_SELECT"'
    | [ .name, (.isPrivate|tostring),
        (wf(.hwf) | any(calls) | tostring),
        (wf(.hwf) | any(wires) | tostring),
        (wf(.bwf) | any(wires) | tostring),
        (.hverb != null | tostring), (.bverb != null | tostring) ] | @tsv'

rows="$("$GH" api graphql -F owner="$OWNER" -f query="$Q" --jq "$JQ" 2>"$ERR" | sort)" \
  || blind "the marker query failed: $(head -2 "$ERR" | tr '\n' ' ')"
[ -n "$rows" ] || blind "the marker query answered, and no repository carries $REGISTRY_MARKER.
  Absence is 'could not look', never 'there are none' -- a registry of zero
  projects is an instruction to scan nothing and report clean."

PASS=0; GAPS=0
ok()  { printf '  OK      %-16s %s\n' "$1" "$2"; PASS=$((PASS+1)); }
gap() { printf '  MISSING %-16s %s\n' "$1" "$2"; GAPS=$((GAPS+1)); }

has_runner() {
  local n
  n="$("$GH" api "repos/$OWNER/$1/actions/runners" --jq '.runners | length' 2>"$ERR")" || return 2
  [ "${n:-0}" -gt 0 ]
}

while IFS=$'\t' read -r name priv hguard hrt brt hverb bverb; do
  [ -n "$name" ] || continue
  owed=''
  [ "$hguard" = true ] || owed="$owed .github/workflows calling $GUARD_REF;"
  [ "$hverb" != true ] || [ "$hrt" = true ] || owed="$owed runtime: true on the default branch (it carries $RUNTIME_PATH);"
  [ "$bverb" != true ] || [ "$brt" = true ] || owed="$owed runtime: true on bashified (it carries $RUNTIME_PATH);"
  if [ "$priv" = true ]; then
    has_runner "$name"; rc=$?
    case "$rc" in
      0) ;;
      1) owed="$owed a self-hosted runner (private, and hosted minutes are refused);" ;;
      *) printf '  BLIND   %-16s cannot read its runners: %s\n' "$name" "$(head -1 "$ERR")"
         blind "$name's runners could not be read, so this run graded only part of the registry" ;;
    esac
  fi
  if [ -z "$owed" ]; then ok "$name" "stood up"; else gap "$name" "owes:${owed%;}"; fi
done <<< "$rows"

echo
printf '%s: %d of %d registered project(s) stood up, %d owing.\n' \
       "$CLI_NAME" "$PASS" "$((PASS + GAPS))" "$GAPS"
[ "$GAPS" -eq 0 ] && exit 0
echo "Each finding is a pull request in that project's own repo; this writes nothing."
exit 1
