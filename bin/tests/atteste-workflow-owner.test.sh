#!/usr/bin/env bash
# atteste-workflow-owner.test.sh -- the daily clock in .github/workflows/atteste.yml
# must search the org (hf7y-estate), not the bare account (hf7y): the account
# has no merged PRs, so that owner silently grades nothing every day (#1696).
set -uo pipefail
. "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib/harness.sh"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WF="$ROOT/../.github/workflows/atteste.yml"
[ -f "$WF" ] || { echo "FAIL: $WF not found"; exit 1; }

echo "atteste-workflow-owner.test.sh"
section "A. the PR search names the org"

LINE="$(grep -n 'gh search prs' "$WF")"
has "A1 the search owner is hf7y-estate" "$LINE" "--owner hf7y-estate"
hasnt "A2 the search does not use the bare account hf7y" "$LINE" "--owner hf7y "

summary
