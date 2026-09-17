#!/usr/bin/env bash
# defere-body.test.sh -- the body `defere` composes must pass the grammar
# `gh-sign` enforces at the write. It did not on any route -- DEFERRED emitted,
# DELIVERS never -- so EVERY filing was refused (#568, #554's shape). A comment
# in defere.sh asserted otherwise; this binds the claim instead.
#
# HERMETIC. Stubs `gh` on PATH; touches nothing outside $T.
#

set -uo pipefail
# shellcheck source=bin/tests/lib/harness.sh
. "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib/harness.sh"

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$ROOT/bin/defere.sh"
[ -x "$SCRIPT" ] || { echo "FAIL: $SCRIPT not executable"; exit 1; }
# shellcheck source=bin/lib/body-grammar.sh
. "$ROOT/bin/lib/body-grammar.sh"

echo "defere-body.test.sh"
harness_tmp

# `defere --project` PROBES the destination before composing. Stub it so the
# suite neither needs the network nor believes a repo exists because it does.
mkdir -p "$T/bin"
cat > "$T/bin/gh" <<'EOF'
#!/usr/bin/env bash
case "$1 $2" in
  'repo view') printf 'realisateur\n'; exit 0 ;;
esac
[ "$1" = api ] && printf '%s' "${STUB_MILESTONE:-}"
exit 0
EOF
chmod +x "$T/bin/gh"

# --dry-run indents the body four spaces, which body-grammar.sh reads as an
# EXAMPLE marker -- un-indenting is not cosmetic; indented parses as no block.
composed() {
  PATH="$T/bin:$PATH" bash "$SCRIPT" "$@" --dry-run 2>&1 \
    | sed '1,/^  body:$/d; s/^    //'
}

check() {
  local name="$1" body="$2" out n
  out="$(grammar_check "$body" 2>&1)"; n=$?
  if [ "$n" -eq 0 ]; then ok "$name"; else bad "$name" "$n finding(s): $out"; fi
}

section "A. every route composes a body the grammar accepts"

check '--project'    "$(composed 'a thing' --project realisateur --body 'why')"
check '--human'      "$(composed 'a thing' --human 'needs a call' --repo hf7y/realisateur --default-after '14d: do the reversible thing')"
check '--unroutable' "$(composed 'a thing' --unroutable 'no repo owns it' --repo hf7y/realisateur --default-after '0d: block -- irreversible, no default')"

# #680: defere is the front door for a DECISION, so it refuses the same
# omission gh-sign refuses rather than composing a body gh-sign will reject.
PATH="$T/bin:$PATH" bash "$SCRIPT" 'a thing' --human 'needs a call' --repo hf7y/realisateur --dry-run >/dev/null 2>&1 \
  && bad "--human with no --default-after is refused" "it composed a body gh-sign would reject" \
  || ok "--human with no --default-after is refused, at the door rather than at the write"

section "B. the block that was missing is actually there"

body="$(composed 'a thing' --project realisateur --body 'why')"
has 'DELIVERS opens'  "$body" '<!-- DELIVERS -->'
has 'DELIVERS closes' "$body" '<!-- /DELIVERS -->'

section "C. no milestone is no queue (hf7y/musc-2300#103)"

out="$(STUB_MILESTONE='Queue A' PATH="$T/bin:$PATH" bash "$SCRIPT" 'a thing' --project realisateur --dry-run 2>&1)"
has 'unnamed, the first open milestone is taken' "$out" 'milestone: Queue A'
has '...and the body says it was guessed'        "$out" 'was chosen by `defere`'
check '...and still passes the grammar' "$(STUB_MILESTONE='Queue A' composed 'a thing' --project realisateur)"
out="$(STUB_MILESTONE='Queue A' PATH="$T/bin:$PATH" bash "$SCRIPT" 'a thing' --project realisateur --milestone 'Queue B' --dry-run 2>&1)"
has '--milestone wins over the guess' "$out" 'milestone: Queue B'
case "$out" in *'was chosen by'*) bad '...with no guess note' "$out" ;; *) ok '...with no guess note' ;; esac
out="$(PATH="$T/bin:$PATH" bash "$SCRIPT" 'a thing' --project realisateur --dry-run 2>&1)"
has 'none open: said out loud, not silent' "$out" 'has no open milestone'

summary
