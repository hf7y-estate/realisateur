#!/usr/bin/env bash
# estate-set.test.sh -- the estate's own names have one home (#673, #672).

. "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib/harness.sh"
HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../.." && pwd)"
LIB="$HERE/bin/lib/estate-set.sh"
val() { bash -c "${2:+export $2; }. '$LIB'; printf '%s' \"\$$1\""; }

section "A. the one home"
if [ -r "$LIB" ]; then ok "A1 bin/lib/estate-set.sh exists"; else bad "A1 bin/lib/estate-set.sh is missing"; fi
eq "A2 owner defaults"        "$(val GH_ESTATE_OWNER)"     "hf7y-estate"
# The 54 repos moved to the hf7y-estate ORG 2026-09-24 (#672). hf7y.github.io
# did NOT -- it is a USER Pages repo serving hf7y.com from a CNAME in its tree,
# and a transfer can drop the Pages domain config. Hence a separate owner.
eq "A2b the Pages repo keeps its own owner" "$(val GH_ESTATE_SITE_OWNER)" "hf7y"
eq "A2c and it overrides"      "$(val GH_ESTATE_SITE_OWNER GH_ESTATE_SITE_OWNER=neworg)" "neworg"
eq "A3 site defaults"         "$(val GH_ESTATE_SITE)"      "hf7y.com"
eq "A4 site repo defaults"    "$(val GH_ESTATE_SITE_REPO)" "hf7y.github.io"
eq "A5 owner overrides"       "$(val GH_ESTATE_OWNER GH_ESTATE_OWNER=neworg)" "neworg"
eq "A6 site overrides"        "$(val GH_ESTATE_SITE  GH_ESTATE_SITE=new.example)" "new.example"
eq "A7 sourcing twice is a no-op" "$(bash -c ". '$LIB'; . '$LIB'; printf '%s' \"\$GH_ESTATE_SITE\"")" "hf7y.com"

section "B. no script re-spells a name the estate owns"
# The quote class is ['"], not "?: `GUARD_REF='hf7y/etalon/...'` in
# registry-standup.sh was a live MATCHING literal that this scanner read as
# clean for 26 days, because a single-quoted assignment has no double quote.
OWNER_RE='(:-|:=|=)['"'"'"]?hf7y([/"'"'"']|$)|github\.com/hf7y'
SITE_RE='hf7y\.com|hf7y\.github\.io'
offenders=""
while IFS= read -r f; do
  case "$f" in */lib/estate-set.sh|*/tests/*) continue ;; esac
  hits="$(grep -nE "$OWNER_RE" "$f" || true)"
  hits="$hits$(sed 's/#.*//' "$f" | grep -nE "$SITE_RE" || true)"
  if [ -n "$hits" ]; then offenders="$offenders
$f:
$hits"; fi
done <<<"$(find "$HERE/bin" "$HERE/hooks" -name '*.sh' -type f | sort)"
if [ -z "$offenders" ]; then
  ok "B1 no owner or host literal in an ADDRESSING position outside lib/estate-set.sh (prose and citations are exempt)"
else
  bad "B1 read the name from lib/estate-set.sh, do not re-spell it" "$offenders"
fi

section "C. the callers resolve through it"
src() { bash -c "${2:+export $2; }. '$HERE/bin/lib/$3' >/dev/null 2>&1; printf '%s' \"\$$1\""; }
eq "C1 answered.sh"        "$(src ANSWERED_OWNER     '' answered.sh)"        "hf7y-estate"
eq "C2 roster-set.sh"      "$(src SWEEP_OWNER        '' roster-set.sh)"       "hf7y-estate"
eq "C3 arming.sh"          "$(src ARMING_ROSTER_URL  '' arming.sh)"          "http://100.107.253.56:8646/roster"
eq "C4 propagation-set.sh" "$(src PROP_RELEASE_REPO  '' propagation-set.sh)" "hf7y-estate/verbs"
eq "C5 a new address reaches the caller" \
   "$(src ARMING_ROSTER_URL GH_ESTATE_ROSTER_URL=http://h:1 arming.sh)" "http://h:1/roster"
eq "C6 a new owner reaches the release channel" \
   "$(src PROP_RELEASE_REMOTE GH_ESTATE_OWNER=neworg propagation-set.sh)" "https://github.com/neworg/verbs.git"

section "D. a new host reaches every published URL"
for f in ausculte.sh publish-release-verdict.sh selfdev-release-tick.sh monkey-watch.sh; do
  out="$(GH_ESTATE_SITE=new.example bash -c "sed 's/#.*//' '$HERE/bin/$f' | grep -c 'hf7y\.com'" 2>/dev/null)"
  eq "D1 $f names no host literal in code" "$out" "0"
done
has "D2 monkey-watch's bare URL now reads the variable" \
    "$(sed 's/#.*//' "$HERE/bin/monkey-watch.sh")" 'https://$GH_ESTATE_SITE/$PUBLISH_DIR/'
has "D3 ...and so does the commit author it writes under" \
    "$(sed 's/#.*//' "$HERE/bin/monkey-watch.sh")" 'noreply@$GH_ESTATE_SITE'
has "D4 the Pages repo composes from the SITE owner, not the estate owner" \
    "$(sed 's/#.*//' "$HERE/bin/publish-release-verdict.sh")" '$GH_ESTATE_SITE_OWNER/$GH_ESTATE_SITE_REPO'

section "E. the lib stays POSIX-sourceable"
SH="$(command -v dash || echo sh)"
OUT="$($SH -c ". '$LIB'; . '$HERE/bin/lib/propagation-set.sh'; printf '%s' \"\$PROP_RELEASE_REPO\"" 2>&1)"
eq "E1 propagation-set.sh sources under $SH -- stamp-verb-build.sh's hook is /bin/sh and FAILS OPEN, so a bash-only line here ends the Verb-Build trailer estate-wide" "$OUT" "hf7y-estate/verbs"
has "E2 the generated hook pre-sources the lib" "$(cat "$HERE/bin/stamp-verb-build.sh")" '. "$ESTATE_SET_SH" || exit 0'

summary
