#!/usr/bin/env bash
# lib/arming.sh -- DOES ANYTHING DISPATCH TO THIS REPO? Read-only, one call.
# Authority: the roster service on dexter. `dose <project> --arm|--park` is the
# only supported writer and refuses a uid 3000-3099 self-dev caller -- not "a
# human edits it", which misled an agent twice (hf7y/scheduler#521).
# Read-only HERE is enforced by arming.test.sh, not prose.
# NOT lib/roster-set.sh, which is the SWEEP set. BLIND classifies NOTHING.

[ -n "${ARMING_LIB:-}" ] && return 0
ARMING_LIB=1

. "${BASH_SOURCE[0]%/*}/estate-set.sh"
ARMING_ROSTER_URL="${ARMING_ROSTER_URL:-$GH_ESTATE_ROSTER_URL/roster}"

ARMING_ROSTER=''   # project<TAB>state, one per line
ARMING_BLIND=1     # until a load succeeds

arming_load() {
  [ "$ARMING_BLIND" = 0 ] && return 0
  local raw
  command -v curl >/dev/null && command -v jq >/dev/null || return 6
  # NO FALLBACK: unreachable is BLIND, and BLIND classifies nothing.
  raw="$(curl -fsS --max-time 10 "$ARMING_ROSTER_URL" 2>/dev/null)" || return 6
  ARMING_ROSTER="$(printf '%s' "$raw" | jq -r '.rows[] | "\(.project)\t\(.state)"' 2>/dev/null)"
  [ -n "$ARMING_ROSTER" ] || return 6
  ARMING_BLIND=0
  return 0
}

# arming_state <project> -- live|parked|absent; empty while BLIND, so a
# forgetful caller cannot read a guess as an answer.
arming_state() {
  [ "$ARMING_BLIND" = 0 ] || { printf ''; return 6; }
  local s
  s="$(printf '%s\n' "$ARMING_ROSTER" | awk -F'\t' -v p="$1" '$1 == p { print $2; exit }')"
  printf '%s' "${s:-absent}"
}
