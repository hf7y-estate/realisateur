#!/usr/bin/env bash
set -uo pipefail  # bin/tests/vault-service.test.sh: witness for provision/dexter/vault (#1164, #742)
. "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib/harness.sh"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SERVER="$ROOT/provision/dexter/vault/vault_server.py"
[ -f "$SERVER" ] || { echo "FAIL: $SERVER not found"; exit 1; }
command -v python3 >/dev/null || { echo "SKIP: no python3"; exit 0; }

harness_tmp

echo "vault-service.test.sh"

V="$T/vault"
mkdir -p "$V/crt"
git init -q "$V"
git -C "$V" config user.email v@localhost
git -C "$V" config user.name v
# A note whose provenance is COMPLETE, and one with none: UNREADABLE is a
# finding in `consigne status`, so the manifest must distinguish them.
printf 'source_repo: hf7y/crt\nsource_path: docs/OLD.md\nsource_sha256: abc123\n\nTHE-SECRET-PROSE-LINE\n' > "$V/crt/OLD.md"
printf 'no frontmatter here\nANOTHER-SECRET-LINE\n' > "$V/crt/BARE.md"
git -C "$V" add -A && git -C "$V" commit -q -m base

PORT="${VAULT_TEST_PORT:-18647}"
VAULT_DIR="$V" VAULT_PORT="$PORT" VAULT_WRITE_TOKEN=tok VAULT_REMOTE="$T/no-remote.git" \
  python3 "$SERVER" >"$T/server.log" 2>&1 &
SRV=$!
trap 'kill "$SRV" 2>/dev/null' EXIT
for _ in $(seq 1 50); do
  curl -fsS "http://127.0.0.1:$PORT/healthz" >/dev/null 2>&1 && break
  sleep 0.2
done

get()  { curl -sS -o "$T/body" -w '%{http_code}' "http://127.0.0.1:$PORT$1" 2>/dev/null; }
post() { curl -sS -o "$T/body" -w '%{http_code}' -X POST -H "Content-Type: application/json" \
           ${2:+-H "X-Vault-Token: $2"} --data "$3" "http://127.0.0.1:$PORT$1" 2>/dev/null; }

section "A. it is alive, and says whether deposits are open"
rc "A1 /healthz answers 200" "200" "$(get /healthz)"
eq "A2 and reports deposits enabled when a token is set" \
  "$(jq -r .writes_enabled < "$T/body")" "true"
eq "A3 and counts the notes it holds" "$(jq -r .notes < "$T/body")" "2"
# A CONTAINER MUST NOT RESTART FOR SOMEONE ELSE'S OUTAGE. compose grades health
# on `ok`, so reading origin/<branch> -- absent on a fresh clone, stale whenever
# the remote is down -- must not decide it, or the restart drops exactly the
# deposits that have not pushed yet.
eq "A4 a vault with no reachable remote is still ok -- health is not the network" \
  "$(jq -r .ok < "$T/body")" "true"
eq "A5 ...and the unmeasured backlog is null, NOT zero (could-not-look is not clean)" \
  "$(jq -r .unpushed < "$T/body")" "null"
has "A6 ...and it says why it could not count" "$(cat "$T/body")" "unpushed_error"

section "B. THE INVARIANT: no endpoint returns prose (#742)"
rc "B1 /manifest answers 200" "200" "$(get /manifest)"
hasnt "B2 the manifest does NOT carry the body of a note" "$(cat "$T/body")" "THE-SECRET-PROSE-LINE"
hasnt "B3 nor of one without frontmatter" "$(cat "$T/body")" "ANOTHER-SECRET-LINE"
has "B4 it DOES carry provenance, which is what the reaping queue compares" \
  "$(cat "$T/body")" "hf7y/crt"
has "B5 and the source hash the deposit was taken at" "$(cat "$T/body")" "abc123"
eq "B6 a note with no frontmatter is reported UNREADABLE, never omitted" \
  "$(jq -r '[.notes[] | select(.readable==false) | .path] | join(",")' < "$T/body")" "crt/BARE.md"

rc "B7 a GET naming a note is 404, not a file" "404" "$(get /crt/OLD.md)"
has "B8 ...and the refusal says WHY, so a reader learns the rule" \
  "$(cat "$T/body")" "never prose"
rc "B9 so is a raw path through the vault dir" "404" "$(get /vault/crt/OLD.md)"

section "C. deposits carry content, because the drainer cannot read the caller's tree"
rc "C1 a deposit with no token is 403" "403" \
  "$(post /deposit '' '{"path":"crt/NEW.md","body":"x","by":"t"}')"
rc "C2 a good deposit is 202 when the remote is unreachable (commit stands, push did not)" \
  "202" "$(post /deposit tok '{"path":"crt/NEW.md","body":"fresh\n","by":"t"}')"
eq "C3 ...and says so rather than reporting a success that holds only on this disk" \
  "$(jq -r .pushed < "$T/body")" "false"
eq "C4 the deposit is committed" "$(jq -r .deposited < "$T/body")" "true"
eq "C5 and it is really in the tree" "$(cat "$V/crt/NEW.md")" "fresh"

rc "C6 the SAME deposit again is 200 and idempotent, so a retry is safe" "200" \
  "$(post /deposit tok '{"path":"crt/NEW.md","body":"fresh\n","by":"t"}')"
eq "C7 ...and reports that it wrote nothing" "$(jq -r .deposited < "$T/body")" "false"

rc "C8 a DIFFERENT note at the same path is refused (409), never silently replaced" "409" \
  "$(post /deposit tok '{"path":"crt/NEW.md","body":"different\n","by":"t"}')"
eq "C9 ...and the annotated original is untouched" "$(cat "$V/crt/NEW.md")" "fresh"

section "D. a path is not a way out of the vault"
for p in '../escape.md' 'crt/../../escape.md' '/etc/passwd.md' 'crt/note.txt'; do
  code="$(post /deposit tok "$(printf '{"path":"%s","body":"x","by":"t"}' "$p")")"
  rc "D: $p is refused (400)" "400" "$code"
done
[ -e "$T/escape.md" ] && bad "D5 something escaped the vault directory" \
                      || ok "D5 nothing was written outside the vault"

summary
