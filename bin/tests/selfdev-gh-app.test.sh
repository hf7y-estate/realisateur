#!/usr/bin/env bash
#
# TRAPS (the rest of this header is in the vault):
# The parts of that script that can be wrong SILENTLY are the crypto and the
# config resolution, not the HTTP: a malformed JWT comes back from GitHub as a
# bare 401 that reads exactly like a revoked key, and a config file that is
# read but not honoured looks like the App simply not being installed. So this
# file verifies the JWT against a throwaway keypair with openssl itself, and
# verifies precedence and refusal paths. NOTHING here touches the network --
# every case either stops before the first curl or points $SELFDEV_GH_API at a
# port nothing is listening on.
#

set -uo pipefail
# shellcheck source=bin/tests/lib/harness.sh
. "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib/harness.sh"
SCRIPT="$(cd "$(dirname "$0")/.." && pwd)/selfdev-gh-app.sh"
[ -x "$SCRIPT" ] || { echo "FAIL: $SCRIPT not executable"; exit 1; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
no()  { case "$2" in *"$3"*) bad "$1 (unexpected: $3)" ;; *) ok "$1" ;; esac; }

# A throwaway RSA keypair. Same shape GitHub hands out (PKCS#1), generated
# here so the test carries no key material of its own.
openssl genrsa -traditional -out "$T/app.pem" 2048 2>/dev/null \
  || openssl genrsa -out "$T/app.pem" 2048 2>/dev/null \
  || { echo "FAIL: openssl could not generate a test key"; exit 1; }
chmod 600 "$T/app.pem"
openssl rsa -in "$T/app.pem" -pubout -out "$T/app.pub.pem" 2>/dev/null

# Every case runs with HOME redirected into the sandbox AND $SELFDEV_APP_CONF
# pointed at the fixture conf, so neither a real ~/.config/selfdev nor the
# host-wide /etc/selfdev on the machine running this test can leak in.
#
FIXTURE_CONF="$T/home/.config/selfdev/gh-app.conf"
run() { env HOME="$T/home" XDG_CACHE_HOME="$T/cache" SELFDEV_APP_CONF="$FIXTURE_CONF" "$@"; }
mkdir -p "$T/home/.config/selfdev" "$T/cache"

echo "== selfdev-gh-app.test.sh =="

# --- A: no App ID -------------------------------------------------------------
out="$(run env SELFDEV_APP_CONF="$T/none.conf" "$SCRIPT" --token 2>&1)"; rc=$?
has "A names SELFDEV_APP_ID" "$out" "SELFDEV_APP_ID"
eq  "A exits 5" "$rc" "5"

# --- B: App ID, no key --------------------------------------------------------
out="$(run env SELFDEV_APP_CONF="$T/none.conf" SELFDEV_APP_ID=4520255 \
        SELFDEV_APP_KEY="$T/absent.pem" "$SCRIPT" --token 2>&1)"; rc=$?
has "B names the key path" "$out" "absent.pem"
eq  "B exits 5" "$rc" "5"

# --- C: a file that is not a key ---------------------------------------------
printf 'not a key\n' > "$T/junk.pem"; chmod 600 "$T/junk.pem"
out="$(run env SELFDEV_APP_CONF="$T/none.conf" SELFDEV_APP_ID=4520255 \
        SELFDEV_APP_KEY="$T/junk.pem" "$SCRIPT" --token 2>&1)"; rc=$?
eq  "C exits 5 on an unusable key" "$rc" "5"
no  "C does not print a token-shaped string" "$out" "ghs_"

# --- D: --check reports the local wiring -------------------------------------
cat > "$T/home/.config/selfdev/gh-app.conf" <<EOF
SELFDEV_APP_ID=4520255
SELFDEV_APP_KEY=$T/app.pem
SELFDEV_GH_OWNER=hf7y
EOF
# API pointed at a closed port: the local checks must still all report, and the
# witness must fail LOUD rather than the script hanging or exiting 0.
out="$(run env SELFDEV_GH_API="http://127.0.0.1:1" "$SCRIPT" --check 2>&1)"; rc=$?
has "D reports the app id"     "$out" "app id 4520255"
has "D reports the key"        "$out" "app.pem (mode 600)"
has "D reports openssl"        "$out" "openssl present"
has "D witness fails loud"     "$out" "WITNESS FAILED"
eq  "D exits 5 when the witness fails" "$rc" "5"
no  "D never claims success"   "$out" "WITNESS: GitHub authenticated"

# --- E: the JWT ---------------------------------------------------------------
# Minted through the script's own --jwt mode rather than reimplementing it --
# a test that recomputes the JWT its own way proves the test, not the script.
jwt="$(run "$SCRIPT" --jwt)"

segs="$(printf '%s' "$jwt" | awk -F. '{print NF}')"
eq "E JWT has three segments" "$segs" "3"

d64() { # base64url -> bytes, padding restored
  local s="${1//-/+}"; s="${s//_//}"
  case $(( ${#s} % 4 )) in 2) s="$s==" ;; 3) s="$s=" ;; esac
  printf '%s' "$s" | openssl base64 -d -A
}
hdr="$(d64 "$(printf '%s' "$jwt" | cut -d. -f1)")"
pay="$(d64 "$(printf '%s' "$jwt" | cut -d. -f2)")"
eq "E header alg is RS256" "$(printf '%s' "$hdr" | jq -r .alg)" "RS256"
eq "E header typ is JWT"   "$(printf '%s' "$hdr" | jq -r .typ)" "JWT"
eq "E payload iss is the App ID" "$(printf '%s' "$pay" | jq -r .iss)" "4520255"

now="$(date +%s)"
iat="$(printf '%s' "$pay" | jq -r .iat)"; exp="$(printf '%s' "$pay" | jq -r .exp)"
[ "$iat" -lt "$now" ] && ok "E iat is in the past (clock-skew margin)" \
                      || bad "E iat is not backdated (iat=$iat now=$now)"
[ $((exp - iat)) -le 600 ] && ok "E exp within GitHub's 10-minute ceiling" \
                           || bad "E exp is $((exp - iat))s after iat, GitHub caps at 600"

# The signature. This is the case that catches a base64url that forgot to
# strip '=' or translate '+/': GitHub would answer 401 and say nothing useful.
printf '%s' "$(printf '%s' "$jwt" | cut -d. -f1-2)" > "$T/signing"
d64 "$(printf '%s' "$jwt" | cut -d. -f3)" > "$T/sig.bin"
if openssl dgst -sha256 -verify "$T/app.pub.pem" -signature "$T/sig.bin" "$T/signing" >/dev/null 2>&1; then
  ok "E signature verifies against the public key"
else
  bad "E signature does NOT verify -- GitHub would answer 401"
fi

# --- F: env beats the config file --------------------------------------------
jwt2="$(run env SELFDEV_APP_ID=999 "$SCRIPT" --jwt)"
eq "F env SELFDEV_APP_ID wins over the conf file" \
   "$(d64 "$(printf '%s' "$jwt2" | cut -d. -f2)" | jq -r .iss)" "999"

# --- G: a world-readable private key is a defect, not a warning ---------------
cp "$T/app.pem" "$T/loose.pem"; chmod 644 "$T/loose.pem"
out="$(run env SELFDEV_APP_CONF="$T/none.conf" SELFDEV_APP_ID=4520255 \
        SELFDEV_APP_KEY="$T/loose.pem" SELFDEV_GH_API="http://127.0.0.1:1" \
        "$SCRIPT" --check 2>&1)"; rc=$?
has "G flags mode 644 as BAD" "$out" "must be 600"
eq  "G exits 5" "$rc" "5"

# --- G2: the host-wide key (mode 640, group selfdev) is not a defect ----------
# realisateur#269: one root:selfdev key is deliberately group-readable so every
# account in the selfdev group can mint tokens from it; chmod 600 would break
# all of them. `id -Gn` covers a caller in the group without needing root.
if id -Gn | tr ' ' '\n' | grep -qx selfdev; then
  cp "$T/app.pem" "$T/shared.pem"; chmod 640 "$T/shared.pem"; chgrp selfdev "$T/shared.pem"
  outG2="$(run env SELFDEV_APP_CONF="$T/none.conf" SELFDEV_APP_ID=4520255 \
          SELFDEV_APP_KEY="$T/shared.pem" SELFDEV_GH_API="http://127.0.0.1:1" \
          "$SCRIPT" --check 2>&1)"
  has "G2 mode 640 group selfdev reports OK, not BAD" "$outG2" "shared.pem (mode 640"
  no  "G2 does not call the host-wide key a defect" "$outG2" "shared.pem is mode"
  # exit code is not asserted here: SELFDEV_GH_API points at a closed port (see
  # file header), so the WITNESS step always fails and --check always exits 5
  # in this offline harness (see D) -- unrelated to the key-mode check under test.
else
  echo "  skip G2 -- caller is not in the selfdev group"
fi

# --- G3: mode 640 outside the selfdev group is still a defect -----------------
cp "$T/app.pem" "$T/other.pem"; chmod 640 "$T/other.pem"
outG3="$(run env SELFDEV_APP_CONF="$T/none.conf" SELFDEV_APP_ID=4520255 \
        SELFDEV_APP_KEY="$T/other.pem" SELFDEV_GH_API="http://127.0.0.1:1" \
        "$SCRIPT" --check 2>&1)"; rcG3=$?
has "G3 mode 640 outside selfdev group is flagged BAD" "$outG3" "must be 600"
eq  "G3 exits 5" "$rcG3" "5"

# --- H: --adopt refuses a bad key BEFORE it moves anything ---------------------
# Ordering is the assertion. Validating after the install would leave a junk
# file sitting where the next --check expects a key, and the operator would be
# debugging GitHub instead of their download.
outH="$(run "$SCRIPT" --adopt --account acct1 --key "$T/junk.pem" --app-id 123 2>&1)"; rcH=$?
has "H names the bad key" "$outH" "not a valid RSA private key"
eq  "H exits 5" "$rcH" "5"
[ -e "$T/home/.config/selfdev/acct1" ] && bad "H wrote nothing" || ok "H wrote nothing"

outH2="$(run "$SCRIPT" --adopt --account acct1 --key "$T/app.pem" 2>&1)"; rcH2=$?
has "H2 refuses without --app-id" "$outH2" "app-id"
eq  "H2 exits 5" "$rcH2" "5"

# --- I: --adopt no longer invents a per-account path ---------------------------
outI="$(run env SELFDEV_GH_API="http://127.0.0.1:1" "$SCRIPT" --adopt \
        --account acct2 --key "$T/app.pem" --app-id 4520255 2>&1)"; rcI=$?
has "I prints the fingerprint"  "$outI" "fingerprint:"
has "I mentions the settings page" "$outI" "SHA256:"
want="$(openssl rsa -in "$T/app.pem" -pubout -outform DER 2>/dev/null | openssl sha256 -binary | openssl base64)"
has "I fingerprint matches openssl" "$outI" "$want"
if [ "$(id -u)" -eq 0 ]; then
  ok "I skipped the refusal case: running as root"
else
  has "I refuses to place the key without root" "$outI" "needs root"
  has "I names the script that owns placement"  "$outI" "selfdev-app-key.sh --apply"
  eq  "I exits 5 rather than half-installing"   "$rcI" "5"
fi
no  "I writes no per-account key directory" "$(ls -A "$T/home/.config/selfdev" 2>/dev/null)" "acct2"

# --- J: the credential helper, INVOKED THE WAY GIT INVOKES IT ------------------
# THE BUG THIS CASE EXISTS FOR, reproduced 2026-08-07:
#
#   $ bin/selfdev-gh-app.sh --credential get </dev/null
#   exit 2
#
# `git config credential.helper "!<cmd>"` makes git run `<cmd> <operation>`,
# appending `get`, `store` or `erase`. The parser had no case for a bare
# operation word, so it fell through to `*)` and printed usage. The helper had
# NEVER worked -- from the day it was written to the day this was found.
#
# The suite above already exercised `--credential`, and passed, because it
# passed the mode with no operation -- a shape git never produces. So the
# assertion is deliberately written as the LITERAL argv git builds, not as a
# convenient paraphrase of it. Same failure class as the `$HOME`-fixture
# guards and as `--build-id -` in this same PR.
echo
echo "-- J: the git credential protocol --------------------------------------"

# `get` must reach the minting path. With no App configured that path FATALs
# on the missing key (exit 5) -- which is the proof it got there: a usage
# error (exit 2) would mean the parser rejected git's own invocation, and a
# hermetic test cannot mint a real token to see any further.
outJ="$(run env SELFDEV_APP_CONF="$T/none.conf" SELFDEV_APP_ID=4520255 \
        SELFDEV_APP_KEY="$T/absent.pem" "$SCRIPT" --credential get </dev/null 2>&1)"; rcJ=$?
[ "$rcJ" != 2 ] && ok "J '--credential get' is not a usage error (git's real invocation is parsed)" \
                || bad "J '--credential get' exited 2 -- git's own invocation is rejected"
no  "J it does not print the usage banner" "$outJ" "usage: "
has "J it reached the minting path (FATAL on the absent key)" "$outJ" "absent.pem"
eq  "J it exits 5, the missing-credential code, not 2" "$rcJ" "5"

# store/erase are no-ops and MUST exit 0. Git ignores their output but notices
# a non-zero exit, so a loud refusal here would put a spurious failure in
# front of every push. Note there is no key configured at all: these must not
# even try to mint.
for op in store erase; do
  outK="$(printf 'protocol=https\nhost=github.com\n\n' | \
          run env SELFDEV_APP_CONF="$T/none.conf" "$SCRIPT" --credential "$op" 2>&1)"; rcK=$?
  eq "J '--credential $op' is a silent no-op, exit 0" "$rcK" "0"
  no "J '--credential $op' mints nothing"   "$outK" "password="
  no "J '--credential $op' prints no usage" "$outK" "usage: "
done

# It drains git's request without dying on a closed pipe -- the reason the
# read loop exists at all.
printf 'protocol=https\nhost=github.com\nusername=x\n\n' | \
  run env SELFDEV_APP_CONF="$T/none.conf" SELFDEV_APP_ID=4520255 \
      SELFDEV_APP_KEY="$T/absent.pem" "$SCRIPT" --credential get >/dev/null 2>&1
[ "$?" = 5 ] && ok "J it consumes git's key=value request before answering" \
             || bad "J it did not survive being handed a real git credential request"

# A bare operation word with no --credential is NOT a git invocation, and must
# not be silently treated as one -- otherwise a typo mints a token.
outL="$(run "$SCRIPT" get </dev/null 2>&1)"; rcL=$?
eq  "J a bare 'get' with no --credential exits 2" "$rcL" "2"
has "J ...and says why"  "$outL" "only accepted after --credential"

# The wiring and the parser have to agree about the flag name, or --wire
# writes a helper line the parser rejects -- which is how this shipped.
# Read the VALUE --wire writes: it unsets the key first, so the first line
# mentioning the key is that unset.
outW="$(grep -o 'want_helper=.*' "$SCRIPT" | head -1)"
has "J --wire writes a helper git will call as '<self> --credential <op>'" "$outW" "--credential"
has "J --wire clears the key first, or a second value silently wins" "$(cat "$SCRIPT")" "--unset-all credential"
has "J --wire reads the helper back out of git rather than trusting the write" "$(cat "$SCRIPT")" "got_helper"

# --- K: --wire writes the ACCOUNT as author, never the App bot -----------------
# THE BUG THIS CASE EXISTS FOR, found live on ecosim@monkey 2026-08-07:
#
echo
echo "-- K: --wire sets AUTHOR=account, PUSHER=App -----------------------------"

# --wire writes GLOBAL git config, so it needs its own HOME *and* its own
# GIT_CONFIG_GLOBAL -- $HOME alone is not enough if the environment carries one.
WHOME="$T/wire-home"; mkdir -p "$WHOME"
GC="$WHOME/.gitconfig"
wire() { env HOME="$WHOME" XDG_CACHE_HOME="$T/cache" GIT_CONFIG_GLOBAL="$GC" \
             SELFDEV_APP_CONF="$T/none.conf" SELFDEV_GH_API="http://127.0.0.1:1" \
             "$SCRIPT" --wire "$@" 2>&1; }
gcfg() { git config --file "$GC" --get "$1" 2>/dev/null || true; }

ACCT="$(id -un)"
: > "$GC"
outK="$(wire)"

eq "K user.name is this ACCOUNT"  "$(gcfg user.name)"  "$ACCT"
eq "K user.email is the account at the reserved domain" \
   "$(gcfg user.email)" "$ACCT@selfdev.invalid"
# The negative assertion, which is the one that actually encodes the bug.
case "$(gcfg user.name)$(gcfg user.email)" in
  *'[bot]'*) bad "K the author is an App bot slug -- every account would author identically" ;;
  *)         ok  "K the author is NOT an App bot slug" ;;
esac
case "$(gcfg user.email)" in
  *users.noreply.github.com*) bad "K the author email claims a GitHub identity that did not act" ;;
  *)                          ok  "K the author email does not impersonate a GitHub profile" ;;
esac
has "K it names the author as the account, and says why" "$outK" "which agent"
has "K it names the pusher as a separate layer"          "$outK" "PUSHER"
# The credential helper half of --wire is correct and must survive the change.
has "K the credential helper is still wired" "$(gcfg 'credential.https://github.com.helper')" "--credential"

# The email domain is a decision, not a hardcode -- overridable for anyone who
# weighs the linkability tradeoff the other way.
: > "$GC"
env HOME="$WHOME" XDG_CACHE_HOME="$T/cache" GIT_CONFIG_GLOBAL="$GC" \
    SELFDEV_APP_CONF="$T/none.conf" SELFDEV_GH_API="http://127.0.0.1:1" \
    SELFDEV_EMAIL_DOMAIN="example.test" "$SCRIPT" --wire >/dev/null 2>&1
eq "K the email domain is overridable" "$(gcfg user.email)" "$ACCT@example.test"

# --- K2: an existing identity is preserved and reported, never silently lost ---
# It already cost real information: the value --wire overwrote on ecosim was
# never captured and cannot be restored, because nothing read it before writing.
: > "$GC"
git config --file "$GC" user.name  "A Human"
git config --file "$GC" user.email "human@example.com"
outK2="$(wire)"

eq "K2 the previous name is preserved in git's own config" \
   "$(gcfg selfdev.previousUserName)"  "A Human"
eq "K2 the previous email is preserved too" \
   "$(gcfg selfdev.previousUserEmail)" "human@example.com"
[ -n "$(gcfg selfdev.previousUserSavedAt)" ] \
  && ok "K2 the backup is dated" || bad "K2 the backup is dated"
has "K2 the replacement is announced, not silent" "$outK2" "REPLACING the global git identity"
has "K2 ...naming the value it replaced"          "$outK2" "A Human"
has "K2 ...and the value it wrote"                "$outK2" "$ACCT@selfdev.invalid"
has "K2 ...and how to restore it"                 "$outK2" "selfdev.previousUserName"
eq  "K2 the new identity is still the account"    "$(gcfg user.name)" "$ACCT"

# Re-running must NOT overwrite the backup with a value --wire itself wrote.
# Without this, one extra --wire destroys the only copy of the original.
wire >/dev/null
eq "K2 a second --wire does not clobber the preserved original" \
   "$(gcfg selfdev.previousUserName)" "A Human"

# The bot-slug case gets its own sentence, because that is the live wrong state
# on the fleet right now and an operator needs to recognise it in the output.
: > "$GC"
git config --file "$GC" user.name  "unattended-monkey[bot]"
git config --file "$GC" user.email "314444911+unattended-monkey[bot]@users.noreply.github.com"
outK3="$(wire)"
has "K3 an App bot slug is named as the fleet-identity bug" "$outK3" "fleet-identity"
eq  "K3 ...and it is corrected to the account"              "$(gcfg user.name)" "$ACCT"
eq  "K3 ...with the bot value preserved"                    "$(gcfg selfdev.previousUserName)" "unattended-monkey[bot]"

echo
echo "-- M: --wire bakes --repos into the helper -------------------------------"

MHOME="$T/scope-home"; mkdir -p "$MHOME"
MGC="$MHOME/.gitconfig"
mwire() { env HOME="$MHOME" XDG_CACHE_HOME="$T/cache" GIT_CONFIG_GLOBAL="$MGC" \
              SELFDEV_APP_CONF="$T/none.conf" SELFDEV_GH_API="http://127.0.0.1:1" \
              "$SCRIPT" --wire "$@" 2>&1; }
mhelper() { git config --file "$MGC" --get credential."https://github.com".helper 2>/dev/null || true; }

outM1="$(mwire --repos wtul,senechal)"
has "M1 the helper git will call carries the scope" "$(mhelper)" "--repos 'wtul,senechal'"
has "M1 ...and still ends in the mode git appends its operation to" "$(mhelper)" "--credential"
has "M1 ...and --wire says which repos it scoped to" "$outM1" "scoped to: wtul,senechal"

outM2="$(run "$SCRIPT" --repos wtul,senechal --credential get </dev/null 2>&1)"; rcM2=$?
no  "M2 a scoped helper is not rejected by its own parser" "$outM2" "only accepted after --credential"
eq  "M2 ...and does not exit on a usage error"             "$([ "$rcM2" -eq 2 ] && echo usage || echo ok)" "ok"

: > "$MGC"
outM3="$(mwire)"
no  "M3 no --repos means no scope is invented" "$(mhelper)" "--repos"
has "M3 ...and the unscoped posture is stated, not silent" "$outM3" "UNSCOPED"

echo
echo "-- M: the caller that must supply the list --------------------------------"
BINDIR="$(cd "$(dirname "$0")/.." && pwd)"
# OWN repo and nothing else: realisateur reaches an account through the verb
# build (#134) and each clones only its own REPO_URL (scheduler#307).
# The re-wire caller, bin/selfdev-credentials.sh, was removed in #1134 (its
# credential-audit check moved to hf7y-estate/etalon); this is the one caller left.
has "M4 the provisioning caller scopes to the project itself" \
    "$(cat "$BINDIR/setup-selfdev-project.sh")" "--wire --repos '\$PROJECT'"

echo
echo "-- N: an owner-qualified --repos entry is refused, not sent to GitHub -----"

outN1="$(mwire --repos hf7y-estate/dog 2>&1)"; rcN1=$?
has "N1 the qualified form is refused before any request" "$outN1" "owner-qualified"
has "N1 ...naming the fix"                                "$outN1" "drop the 'hf7y-estate/' prefix"
has "N1 ...and the bare form to use"                       "$outN1" "'dog'"
eq  "N1 ...exits 5 like the script's other refusals"       "$rcN1" "5"
no  "N1 ...never bakes the bad value into the helper"       "$(mhelper)" "hf7y-estate/dog"

outN2="$(mwire --repos wtul,hf7y-estate/senechal 2>&1)"; rcN2=$?
has "N2 a mixed list is still caught" "$outN2" "hf7y-estate/senechal' is owner-qualified"
eq  "N2 ...exits 5"                   "$rcN2" "5"

outN3="$(mwire --repos WTUL 2>&1)"; rcN3=$?
no  "N3 a bare name that merely shares a case with the owner is not caught" \
    "$outN3" "owner-qualified"

echo
summary
[ "$fail" -eq 0 ] || exit 1
exit 0
