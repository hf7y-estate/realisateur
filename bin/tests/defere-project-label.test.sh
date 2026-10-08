#!/usr/bin/env bash
# defere-project-label.test.sh -- `defere --project` stamped every filing
# `deferred`, and a project's own dispatcher excludes that label as "blocked
# on another delivery" (scheduler/bin/route-deliveries.sh:17). An unblocked
# --project filing was invisible to the destination's run until someone
# removed the label by hand (#1375, hf7y/bibliothecaire#115,
# hf7y/realisateur#1373, hf7y/musc-2300#173, all on 2026-10-01).
#
# HERMETIC. Stubs `gh` on PATH; touches nothing outside $T.

set -uo pipefail
# shellcheck source=bin/tests/lib/harness.sh
. "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib/harness.sh"

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$ROOT/bin/defere.sh"
[ -x "$SCRIPT" ] || { echo "FAIL: $SCRIPT not executable"; exit 1; }

echo "defere-project-label.test.sh"
harness_tmp

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

dry() { PATH="$T/bin:$PATH" bash "$SCRIPT" "$@" --dry-run 2>&1; }

section "A. --project with no blocker named: unlabelled, the dispatch query would see it"

out="$(dry 'a thing nobody is waiting on' --project realisateur --body 'just left behind')"
has  "A1 files unlabelled" "$out" 'label:  (unlabelled)'
hasnt "A2 never stamps deferred" "$out" 'label:  deferred'

section "B. --blocked-on names the blocker and labels deferred"

out="$(dry 'a thing' --project realisateur --body 'why' --blocked-on 'bibliothecaire#9')"
has "B1 labelled deferred" "$out" 'label:  deferred'
has "B2 the blocker is written into the body" "$out" 'Blocked on: bibliothecaire#9'

section "C. a --body that already names the blocker in prose is also labelled"

out="$(dry 'a thing' --project realisateur --body 'blocked on bibliothecaire#9 landing first')"
has "C1 labelled deferred from prose alone" "$out" 'label:  deferred'

section "D. --blocked-on is refused on --human/--unroutable (not a deferral)"

PATH="$T/bin:$PATH" bash "$SCRIPT" 'a thing' --human 'needs a call' --repo hf7y/realisateur \
  --default-after '14d: do the reversible thing' --policy 'none yet' --blocked-on 'x' --dry-run \
  >/dev/null 2>&1 && bad "D1 refused" "it accepted --blocked-on on --human" \
  || ok "D1 refused, --blocked-on only applies to --project"

summary
