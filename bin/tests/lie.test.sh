#!/usr/bin/env bash
#
# SUBJECT: bin/lie -- the single allowlisted spelling of the DELETE that
# takes back a native blocked-by edge (hf7y-estate/realisateur#1561).
#
# A fake gh, keyed by "METHOD PATH" (the --jq filter and -F value are not
# part of the key -- a test case does not need two fixtures for the same
# call to mean two different things). An unfixtured call is a loud FAIL
# ("no fixture for"), not a silent empty read, so a wrong call shows up here
# rather than three repos away.
set -uo pipefail
# shellcheck source=bin/tests/lib/harness.sh
. "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib/harness.sh"
HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
LIE="$HERE/../lie"
BASH_BIN="$(command -v bash)"

[ -x "$LIE" ] || { echo "FAIL: bin/lie is missing or not executable"; exit 1; }

harness_tmp
mkdir -p "$T/stub" "$T/resp"
cat > "$T/stub/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GH_LOG"
[ "${1:-}" = api ] || { echo "stub: expected 'api', got: $*" >&2; exit 1; }
shift
method=GET; path=''
while [ $# -gt 0 ]; do
  case "$1" in
    -X|--method) method="$2"; shift 2 ;;
    --jq) shift 2 ;;
    -F|--field) shift 2 ;;
    --silent) shift ;;
    -*) shift ;;
    *) path="$1"; shift ;;
  esac
done
key="$(printf '%s %s' "$method" "$path" | tr -c 'A-Za-z0-9' '_')"
f="$GH_RESP_DIR/$key"
if [ ! -e "$f.rc" ] && [ ! -e "$f" ]; then
  echo "stub: no fixture for [$method $path] (key=$key)" >&2
  exit 1
fi
rc=0; [ -e "$f.rc" ] && rc="$(cat "$f.rc")"
[ -e "$f" ] && cat "$f"
exit "$rc"
STUB
chmod +x "$T/stub/gh"

echo "lie.test.sh"

run() { # run <args...> -- fresh gh.log and resp dir are set by the caller first
  GH_LOG="$T/gh.log" GH_RESP_DIR="$T/resp" PATH="$T/stub:$PATH" "$BASH_BIN" "$LIE" "$@"
}
fixture() { # fixture <method> <path> <body>  -- body may be empty
  local key
  key="$(printf '%s %s' "$1" "$2" | tr -c 'A-Za-z0-9' '_')"
  printf '%s' "$3" > "$T/resp/$key"
}
fixture_rc() { # fixture_rc <method> <path> <rc>
  local key
  key="$(printf '%s %s' "$1" "$2" | tr -c 'A-Za-z0-9' '_')"
  printf '%s' "$3" > "$T/resp/$key.rc"
}
reset() { rm -rf "$T/resp"; mkdir -p "$T/resp"; : > "$T/gh.log"; }
logged() { grep -qF -- "$1" "$T/gh.log"; }

section "A. usage"
reset
out="$(run 2>&1)"; rc=$?
rc "A1 no target issue at all: usage (2)" 2 "$rc"
has "A1 message names the missing piece" "$out" "need a target issue"

reset
out="$(run crt#336 2>&1)"; rc=$?
rc "A2 target with no mode flag: usage (2)" 2 "$rc"

reset
out="$(run crt#336 --blocked-by 2>&1)"; rc=$?
rc "A3 --blocked-by with no value: usage (2)" 2 "$rc"

reset
out="$(run notarepo --blocked-by crt#336 2>&1)"; rc=$?
rc "A4 a target with no '#n': usage (2)" 2 "$rc"
has "A4 message says so" "$out" "not a repo#n reference"

reset
out="$(run crt#336 --blocked-by secretaire#38 --wat 2>&1)"; rc=$?
rc "A5 an unrecognised flag: usage (2), via cli_guard" 2 "$rc"

section "B. draws an edge: resolves the OTHER side's id, walks for a cycle, POSTs, reads back"
reset
fixture GET repos/hf7y-estate/secretaire/issues/38 123456
fixture GET repos/hf7y-estate/secretaire/issues/38/dependencies/blocked_by ''
fixture POST repos/hf7y-estate/crt/issues/336/dependencies/blocked_by ''
fixture GET repos/hf7y-estate/crt/issues/336/dependencies/blocked_by 'hf7y-estate/secretaire#38
'
out="$(run crt#336 --blocked-by secretaire#38 2>&1)"; rc=$?
rc "B1 exit 0" 0 "$rc"
has "B2 says it drew the edge, both sides named" "$out" "drew hf7y-estate/crt#336 blocked_by hf7y-estate/secretaire#38"
has "B3 prints the read-back" "$out" "hf7y-estate/crt#336 blocked_by: hf7y-estate/secretaire#38"
logged "api repos/hf7y-estate/secretaire/issues/38 --jq .id" \
  && ok "B4 resolved the OTHER side's id by repo#n, not by trusting a caller-supplied id" \
  || bad "B4 resolved the OTHER side's id by repo#n, not by trusting a caller-supplied id"
logged "api -X POST repos/hf7y-estate/crt/issues/336/dependencies/blocked_by -F issue_id=123456 --silent" \
  && ok "B5 POSTed the resolved id to the TARGET's own path" \
  || bad "B5 POSTed the resolved id to the TARGET's own path"

section "C. bare repo defaults to hf7y-estate; owner/repo form is honoured as given"
reset
fixture GET repos/hf7y-estate/secretaire/issues/38 1
fixture GET repos/hf7y-estate/secretaire/issues/38/dependencies/blocked_by ''
fixture POST repos/other-org/crt/issues/336/dependencies/blocked_by ''
fixture GET repos/other-org/crt/issues/336/dependencies/blocked_by ''
out="$(run other-org/crt#336 --blocked-by secretaire#38 2>&1)"; rc=$?
rc "C1 exit 0 with a mixed bare/owner pair" 0 "$rc"
logged "api repos/other-org/crt/issues/336/dependencies/blocked_by --jq .[]" \
  && ok "C2 the owner/repo#n form was not defaulted away" \
  || bad "C2 the owner/repo#n form was not defaulted away"

section "D. refuses a cycle of depth 3, prints it, and never POSTs"
reset
fixture GET repos/hf7y-estate/crt/issues/336 999
fixture GET repos/hf7y-estate/crt/issues/336/dependencies/blocked_by 'hf7y-estate/senechal#1119
'
fixture GET repos/hf7y-estate/senechal/issues/1119/dependencies/blocked_by 'hf7y-estate/secretaire#38
'
out="$(run secretaire#38 --blocked-by crt#336 2>&1)"; rc=$?
rc "D1 exit 5" 5 "$rc"
has "D2 names both sides" "$out" "hf7y-estate/secretaire#38 blocked_by hf7y-estate/crt#336"
has "D3 prints the whole cycle, not just the new edge" "$out" \
  "hf7y-estate/secretaire#38 <- hf7y-estate/crt#336 <- hf7y-estate/senechal#1119 <- hf7y-estate/secretaire#38"
if grep -q POST "$T/gh.log"; then bad "D4 no POST reached the API"; else ok "D4 no POST reached the API"; fi

section "E. a direct self-edge is a 1-cycle, refused the same way"
reset
fixture GET repos/hf7y-estate/crt/issues/336 1
out="$(run crt#336 --blocked-by crt#336 2>&1)"; rc=$?
rc "E1 exit 5" 5 "$rc"
has "E2 the printed cycle names the issue once at each end" "$out" \
  "hf7y-estate/crt#336 <- hf7y-estate/crt#336"

section "F. a read failing mid-walk is BLIND, not a silent pass"
reset
fixture GET repos/hf7y-estate/crt/issues/426 888
fixture GET repos/hf7y-estate/crt/issues/426/dependencies/blocked_by 'hf7y-estate/secretaire#83
'
fixture_rc GET repos/hf7y-estate/secretaire/issues/83/dependencies/blocked_by 1
out="$(run secretaire#38 --blocked-by crt#426 2>&1)"; rc=$?
rc "F1 exit 6, not 0 and not 5" 6 "$rc"
has "F2 names which read failed" "$out" "secretaire#83"
if grep -q POST "$T/gh.log"; then bad "F3 no POST reached the API"; else ok "F3 no POST reached the API"; fi

section "G. removes an edge: resolves the id, DELETEs the one path, never walks for a cycle"
reset
fixture GET repos/hf7y-estate/crt/issues/336 777
fixture DELETE repos/hf7y-estate/secretaire/issues/38/dependencies/blocked_by/777 ''
fixture GET repos/hf7y-estate/secretaire/issues/38/dependencies/blocked_by ''
out="$(run secretaire#38 --not-blocked-by crt#336 2>&1)"; rc=$?
rc "G1 exit 0" 0 "$rc"
has "G2 says it removed the edge, both sides named" "$out" "removed hf7y-estate/secretaire#38 blocked_by hf7y-estate/crt#336"
has "G3 prints the read-back" "$out" "hf7y-estate/secretaire#38 blocked_by: (none)"
logged "api -X DELETE repos/hf7y-estate/secretaire/issues/38/dependencies/blocked_by/777 --silent" \
  && ok "G4 DELETEd the one resolved path" \
  || bad "G4 DELETEd the one resolved path"
n_blocked_by_reads="$(grep -c 'dependencies/blocked_by --jq' "$T/gh.log")"
eq "G5 only the final read-back touched blocked_by (no cycle walk on removal)" "$n_blocked_by_reads" 1

section "H. the gh write itself failing is reported, not swallowed as success"
reset
fixture GET repos/hf7y-estate/crt/issues/336 777
fixture_rc DELETE repos/hf7y-estate/secretaire/issues/38/dependencies/blocked_by/777 1
out="$(run secretaire#38 --not-blocked-by crt#336 2>&1)"; rc=$?
rc "H1 exit 1, not 0" 1 "$rc"
has "H2 says the write failed" "$out" "FAILED"

summary
