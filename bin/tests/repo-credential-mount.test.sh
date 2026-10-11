#!/usr/bin/env bash
# SUBJECT: agent/repo-credential-mount.sh. Hermetic -- the map, CRED_DIR and
# MOUNT_ROOT are all fixtures under $T, so this suite needs no real
# /etc/selfdev, no dexter, and cannot pass because some host happens to hold
# the right file.
set -uo pipefail
. "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib/harness.sh"
harness_tmp
REPO="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../.." && pwd)"
RESOLVER="$REPO/agent/repo-credential-mount.sh"

echo "repo-credential-mount.test.sh"

mkdir -p "$T/creds"

cat > "$T/map.tsv" <<'TSV'
# comment row, and a blank-cred row must never match
hf7y-estate/baudin	baudin-ha-token
other-org/thing	some-other-key
TSV

run() {  # run(target, cred-dir) -- map and mount-root are fixed to $T's
  REPO_CREDENTIALS_TSV="$T/map.tsv" CRED_DIR="$2" MOUNT_ROOT="$T/run" "$RESOLVER" "$1"
}

section "A. a mapped repo whose credential is on the host gets a mount spec"
printf 'ha-token-value\n' > "$T/creds/baudin-ha-token"
out="$(run hf7y-estate/baudin "$T/creds")"; rc="$?"
rc "exits 0" 0 "$rc"
eq "...SRC:DST:ro, resolved by key, never typed by the caller" "$out" \
  "$T/creds/baudin-ha-token:$T/run/baudin-ha-token:ro"

section "B. the same key resolves against whichever CRED_DIR it is handed"
mkdir -p "$T/creds-b"
printf 'other-host-value\n' > "$T/creds-b/baudin-ha-token"
out="$(run hf7y-estate/baudin "$T/creds-b")"; rc "exits 0" 0 "$?"
has "...the OTHER directory's path, same key" "$out" "$T/creds-b/baudin-ha-token"

section "C. a mapped repo whose credential is NOT yet on this host prints nothing"
rm -f "$T/creds/baudin-ha-token" 2>/dev/null
out="$(run hf7y-estate/baudin "$T/creds")"; rc="$?"
rc "exits 0 anyway -- advisory, not a refusal" 0 "$rc"
eq "...prints nothing" "$out" ""

section "D. an unmapped repo prints nothing, even with a same-named credential file sitting right there"
printf 'ha-token-value\n' > "$T/creds/baudin-ha-token"
out="$(run hf7y-estate/some-other-repo "$T/creds")"; rc "exits 0" 0 "$?"
eq "...no row, no mount" "$out" ""

section "E. no map file at all prints nothing rather than erroring"
out="$(REPO_CREDENTIALS_TSV="$T/no-such-map.tsv" CRED_DIR="$T/creds" MOUNT_ROOT="$T/run" "$RESOLVER" hf7y-estate/baudin)"
rc "exits 0" 0 "$?"
eq "...prints nothing" "$out" ""

section "G. a credential directory the caller cannot read is asked through sudo -- dexter's /etc/selfdev is 700 root and run-agent.sh runs as zach (baudin#189)"
mkdir -p "$T/bin" "$T/locked"
printf 'ha-token-value\n' > "$T/locked/baudin-ha-token"
chmod 000 "$T/locked"
printf '#!/bin/sh\n[ "$1" = -n ] && shift\n[ "$1 $2" = "test -f" ] && [ "$3" = "%s" ]\n' "$T/locked/baudin-ha-token" > "$T/bin/sudo"
chmod +x "$T/bin/sudo"
out="$(PATH="$T/bin:$PATH" run hf7y-estate/baudin "$T/locked")"; rc "exits 0" 0 "$?"
eq "...the mount spec, though [ -f ] alone says no" "$out" \
  "$T/locked/baudin-ha-token:$T/run/baudin-ha-token:ro"
out="$(PATH="$T/bin:$PATH" run hf7y-estate/baudin "$T/creds-nowhere")"; rc "exits 0" 0 "$?"
eq "...and still nothing when sudo says no too" "$out" ""
chmod 700 "$T/locked"

section "F. the target argument is required"
out="$("$RESOLVER" 2>&1)"; rc="$?"
rc "exits nonzero" 1 "$rc"
has "...says so" "$out" "usage: repo-credential-mount.sh"

summary
