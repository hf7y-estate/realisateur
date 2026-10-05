#!/usr/bin/env bash
# arming.test.sh -- witness for bin/lib/arming.sh's one invariant: READ-ONLY.
#
# Carved out of decision-rot.test.sh's I14 when bin/decision-rot.sh was
# retired (#1435) -- decision-rot.sh was arming.sh's only caller with a test,
# but not its only caller (bin/gh-sign.sh sources it too, #1435), so the
# invariant arming.sh's own header promises ("Read-only HERE is enforced by
# ... not prose") needed a home that outlives any one caller.
set -uo pipefail
# shellcheck source=bin/tests/lib/harness.sh
. "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib/harness.sh"
LIB="$(cd "$(dirname "$0")/.." && pwd)/lib/arming.sh"
[ -f "$LIB" ] || { echo "FAIL: $LIB missing"; exit 1; }

echo "arming.test.sh"

section "A. lib/arming.sh holds no write path"
if grep -qE '\-X (PUT|POST|PATCH|DELETE)|--method|--field|-f ' "$LIB"; then
  bad "A1 lib/arming.sh holds no write path" "a write verb appeared in it"
else
  ok "A1 lib/arming.sh holds no write path -- an agent cannot edit the ROSTER through it"
fi

echo
summary
[ "$fail" -eq 0 ] || exit 1
