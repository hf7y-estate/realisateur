#!/usr/bin/env bash
# SUBJECT: agent/edges.sh. Hermetic -- `gh` is a stub on PATH, so this suite
# draws and removes nothing on GitHub.
set -uo pipefail
. "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib/harness.sh"
harness_tmp
REPO="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../.." && pwd)"
SUT="$REPO/agent/edges.sh"

echo "edges.test.sh"

mkdir -p "$T/bin"

# The stub is a tiny issue graph. $T/issues holds `owner/repo#n id state`;
# $T/edges/<owner_repo#n> holds that issue's blocker ids, one per line. POST
# appends, DELETE removes, so a read-back sees what the SUT really wrote. The
# real `--jq` filter runs through jq. Every call lands in $T/calls, and a call
# matching the pattern in $T/fail exits 1.
cat > "$T/bin/gh" <<'STUB'
#!/usr/bin/env bash
shift; m=GET; ep=""; jqf=.; id=""
while [ $# -gt 0 ]; do
  case "$1" in
    -X|--method) m="$2"; shift ;;
    -F) id="${2#issue_id=}"; shift ;;
    --jq) jqf="$2"; shift ;;
    repos/*) ep="$1" ;;
  esac
  shift
done
printf '%s %s\n' "$m" "$ep" >> "$T/calls"
if [ -f "$T/fail" ] && grep -qf "$T/fail" <<< "$m $ep"; then echo "gh: HTTP 500" >&2; exit 1; fi
rest="${ep#repos/}"; tail="${rest#*/issues/}"; n="${tail%%/*}"
key="${rest%%/issues/*}#${n}"; edges="$T/edges/${key//\//_}"
case "$m $tail" in
  "GET $n")
    row="$(awk -v k="$key" '$1 == k' "$T/issues")"; [ -n "$row" ] || exit 1
    awk '{ print "{\"id\":" $2 "}" }' <<< "$row" | jq -r "$jqf" ;;
  "GET $n/dependencies/blocked_by")
    while read -r bid; do
      awk -v i="$bid" '$2 == i { split($1, p, "#")
        print "{\"number\":" p[2] ",\"id\":" $2 ",\"state\":\"" $3 "\",\"repository_url\":\"https://api.github.com/repos/" p[1] "\"}" }' "$T/issues"
    done < <(cat "$edges" 2>/dev/null) | jq -s . | jq -r "$jqf" ;;
  "POST $n/dependencies/blocked_by") printf '%s\n' "$id" >> "$edges" ;;
  "DELETE $n/dependencies/blocked_by/"*) sed -i "/^${tail##*/}\$/d" "$edges" ;;
  *) exit 1 ;;
esac
STUB
chmod +x "$T/bin/gh"

run() {
  # shellcheck disable=SC2097,SC2098  # T="$T" passes the harness dir the stub reads
  PATH="$T/bin:$PATH" T="$T" bash "$SUT" "$@" 2>&1
}
reset() { rm -rf "$T/edges" "$T/calls" "$T/fail"; mkdir -p "$T/edges"; : > "$T/calls"; }
edge()  { printf '%s\n' "$2" >> "$T/edges/${1//\//_}"; }   # edge(target key, blocker id)
writes() { grep -cE '^(POST|DELETE) ' "$T/calls"; }

cat > "$T/issues" <<'EOF'
hf7y-estate/secretaire#38 1038 open
hf7y-estate/crt#336 1336 open
hf7y-estate/senechal#1119 2119 open
hf7y-estate/secretaire#83 1083 closed
other/place#5 5005 open
EOF

section "A. the argument contract"
reset
for args in "" "list" "add crt#336" "rm crt#336" "bogus crt#336" "list crt336" "add crt#336 secretaire#x" "list crt#336 extra"; do
  # shellcheck disable=SC2086  # the split is the test
  out="$(run $args)"; rc "[$args] exits 2" 2 "$?"
  has "...with the usage line" "$out" "usage: edges.sh"
done
eq "...and gh was never called" "$(cat "$T/calls")" ""

section "B. add draws the edge by repo#n and reads it back"
reset
out="$(run add secretaire#38 crt#336)"; rc "exits 0" 0 "$?"
has "says what it drew" "$out" "added   hf7y-estate/secretaire#38 <- hf7y-estate/crt#336"
has "...and prints the resulting blocker with its state" "$out" "hf7y-estate/crt#336 open"
has "...POSTed to the TARGET" "$(cat "$T/calls")" "POST repos/hf7y-estate/secretaire/issues/38/dependencies/blocked_by"
eq  "...with the BLOCKER's numeric id" "$(cat "$T/edges/hf7y-estate_secretaire#38")" "1336"

section "C. cross-repo, explicit owner, EDGES_OWNER"
out="$(run add other/place#5 secretaire#83)"; rc "an owner/repo target exits 0" 0 "$?"
has "...and reads back a closed blocker in another owner" "$out" "hf7y-estate/secretaire#83 closed"
out="$(EDGES_OWNER=other run list place#5)"; rc "EDGES_OWNER fills a bare name" 0 "$?"
eq  "...and list prints exactly the blockers" "$out" "hf7y-estate/secretaire#83 closed"
out="$(run list crt#336)"; rc "an issue with no blockers lists clean" 0 "$?"
eq  "...as nothing" "$out" ""

section "D. rm removes the edge and reads back what is left"
reset; edge hf7y-estate/secretaire#38 1336; edge hf7y-estate/secretaire#38 1083
out="$(run rm secretaire#38 crt#336)"; rc "exits 0" 0 "$?"
has "says what it removed" "$out" "removed hf7y-estate/secretaire#38 <- hf7y-estate/crt#336"
has "...DELETEd the blocker's id on the target" "$(cat "$T/calls")" "DELETE repos/hf7y-estate/secretaire/issues/38/dependencies/blocked_by/1336"
has "...the other blocker is still listed" "$out" "hf7y-estate/secretaire#83 closed"
hasnt "...the removed one is not" "$out" "crt#336 open"

section "E. rm of an edge that is not there"
reset; edge hf7y-estate/secretaire#38 1083
out="$(run rm secretaire#38 crt#336)"; rc "exits 4" 4 "$?"
has "says so" "$out" "is not blocked by hf7y-estate/crt#336, nothing removed"
hasnt "...claims no removal" "$out" "removed "
eq  "...and wrote nothing" "$(writes)" "0"

section "F. a three-issue cycle is refused, printed, and never written"
reset; edge hf7y-estate/crt#336 2119; edge hf7y-estate/senechal#1119 1038
out="$(run add secretaire#38 crt#336)"; rc "exits 7" 7 "$?"
has "prints the cycle" "$out" "hf7y-estate/secretaire#38 <- hf7y-estate/crt#336 <- hf7y-estate/senechal#1119 <- hf7y-estate/secretaire#38"
hasnt "...claims no edge" "$out" "added "
eq  "...and made no POST" "$(writes)" "0"
out="$(run add crt#336 crt#336)"; rc "an issue blocking itself also exits 7" 7 "$?"
eq  "...and made no POST" "$(writes)" "0"

section "G. a failing gh surfaces, never reads as no blockers"
reset; edge hf7y-estate/secretaire#38 1336; echo 'GET .*/38/dependencies' > "$T/fail"
out="$(run list secretaire#38)"; rc "a failed list exits 5" 5 "$?"
has "...naming the call" "$out" "FAILED gh api repos/hf7y-estate/secretaire/issues/38/dependencies/blocked_by"
out="$(run rm secretaire#38 crt#336)"; rc "rm on an unreadable list exits 5, not 4" 5 "$?"
hasnt "...and does not call the edge absent" "$out" "not blocked by"
reset; echo 'GET .*/336/dependencies' > "$T/fail"
out="$(run add secretaire#38 crt#336)"; rc "a walk that cannot read exits 5" 5 "$?"
eq  "...and made no POST" "$(writes)" "0"
reset; echo '^POST ' > "$T/fail"
out="$(run add secretaire#38 crt#336)"; rc "a refused POST exits 5" 5 "$?"
hasnt "...with no success line" "$out" "added "
reset; edge hf7y-estate/secretaire#38 1336; echo '^DELETE ' > "$T/fail"
out="$(run rm secretaire#38 crt#336)"; rc "a refused DELETE exits 5" 5 "$?"
hasnt "...with no success line" "$out" "removed "
reset
out="$(run add secretaire#38 crt#999)"; rc "a blocker that does not exist exits 5" 5 "$?"
eq  "...and made no POST" "$(writes)" "0"

section "H. a walk past the bound is could-not-look, not a pass"
reset; cp "$T/issues" "$T/issues.keep"
for i in $(seq 1 205); do
  echo "hf7y-estate/long#$i $((9000 + i)) open" >> "$T/issues"
  edge "hf7y-estate/long#$i" "$((9001 + i))"
done
out="$(run add secretaire#38 long#1)"; rc "exits 6" 6 "$?"
has "says it could not look" "$out" "could not look"
eq  "...and made no POST" "$(writes)" "0"
mv "$T/issues.keep" "$T/issues"

summary
