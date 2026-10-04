#!/usr/bin/env bash
# defere-ruling.test.sh -- #1407 (#132/#139 shape): `defere --human` must not
# file a fresh `needs-human` DECISION when the question it is about to ask
# already has its answer quoted, verbatim, in a closed issue in the same repo.
#
# HERMETIC. Stubs `gh` on PATH; touches nothing outside $T.
#
set -uo pipefail
# shellcheck source=bin/tests/lib/harness.sh
. "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib/harness.sh"

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$ROOT/bin/defere.sh"
[ -x "$SCRIPT" ] || { echo "FAIL: $SCRIPT not executable"; exit 1; }

echo "defere-ruling.test.sh"
harness_tmp

# One CLOSED issue, #132, carrying the #132-shape ruling quoted the way this
# estate's bodies already quote Zach: `Zach ruled ... ("text")`.
mkdir -p "$T/bin"
cat > "$T/bin/gh" <<'EOF'
#!/usr/bin/env bash
case "$1 $2" in
  'repo view') printf 'realisateur\n'; exit 0 ;;
  'issue list')
    printf '[{"number":132,"body":"NO-DECISION: @hf7y -- Zach ruled 2026-09-23 (\\"presentations 10/7 is better, use that\\").","comments":[]}]\n'
    exit 0 ;;
esac
[ "$1" = api ] && printf '%s' "${STUB_MILESTONE:-}"
exit 0
EOF
chmod +x "$T/bin/gh"

run() {
  PATH="$T/bin:$PATH" bash "$SCRIPT" "$@" --repo hf7y/realisateur --default-after '14d: block' --dry-run
}

section "A. #132/#139 shape: the question restates an already-quoted ruling"

out="$(run 'presentations 10/7 is better, use that' --human 'need a call' 2>&1)"; n=$?
rc 'A1 refused, not filed' 1 "$n"
has 'A2 names the closed issue carrying the ruling' "$out" 'hf7y/realisateur#132'
has 'A3 quotes the ruling it matched' "$out" 'presentations 10/7 is better, use that'
has 'A4 points at #1434 rather than inventing a rewrite here' "$out" '1434'

section "B. an unrelated question still files normally"

out="$(run 'rotate the deploy key' --human 'need a call' 2>&1)"; n=$?
rc 'B1 not refused' 0 "$n"
hasnt 'B2 no false match printed' "$out" 'already quotes a ruling'

summary
