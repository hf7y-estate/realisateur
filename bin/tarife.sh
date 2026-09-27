#!/usr/bin/env bash
# tarife.sh -- price this tree BEFORE the push, not after it (#1041).
# KIND: verb
set -uo pipefail

CLI_NAME='tarife.sh'
CLI_SUMMARY='what would the estate guards say about this tree, before you push?'
CLI_USAGE='  tarife                every guard; the exit code is the answer
  tarife --gate         only the guards fast enough to run at every turn end
  tarife --refresh      re-fetch the guards even if the cache is warm
  tarife --quiet        print only findings'
CLI_FLAGS='--gate --refresh --quiet'
CLI_POSITIONAL=none
CLI_EXITS='  0  every guard passed
  1  a guard found something (its own output says what, and what to do)
  6  BLIND: a guard could not be fetched and no cached copy exists'
# readlink -f: a verb is a symlink; without this the guard silently misses.
. "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib/cli-guard.sh"
cli_guard "$@"

HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"

REFRESH=0
QUIET=0
GATE=0
for a in "$@"; do
  case "$a" in
    --refresh) REFRESH=1 ;;
    --quiet)   QUIET=1 ;;
    --gate)    GATE=1 ;;
  esac
done

CACHE="${TARIFE_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/etalon-guards}"
TTL_MIN="${TARIFE_TTL_MIN:-720}"
. "$HERE/lib/estate-set.sh"
ETALON_REPO="${TARIFE_ETALON_REPO:-$GH_ESTATE_OWNER/etalon}"

say() { [ "$QUIET" = 1 ] || printf '%s\n' "$*"; }

fetch_guard() {
  local name="$1" dest="$CACHE/$1"
  mkdir -p "$(dirname "$dest")" 2>/dev/null || { printf '%s' ""; return; }
  if [ "$REFRESH" = 0 ] && [ -s "$dest" ] &&
     [ -z "$(find "$dest" -mmin +"$TTL_MIN" 2>/dev/null)" ]; then
    printf '%s' "$dest"; return
  fi
  if command -v gh >/dev/null 2>&1 &&
     gh api "repos/$ETALON_REPO/contents/bin/$name" --jq .content 2>/dev/null |
       base64 -d > "$dest.new" 2>/dev/null && [ -s "$dest.new" ]; then
    mv "$dest.new" "$dest"
    printf '%s' "$dest"; return
  fi
  rm -f "$dest.new" 2>/dev/null
  [ -s "$dest" ] && { printf '%s' "$dest"; return; }
  printf '%s' ""
}

rc_worst=0
blind=0
note_rc() { # note_rc <rc> -- 1 beats 0; BLIND is tracked separately so it never folds into OK
  [ "$1" -gt "$rc_worst" ] && rc_worst="$1"
  return 0
}

run_guard() { # run_guard <label> <script-path> [args...]
  local label="$1" path="$2"; shift 2
  say "-- $label"
  bash "$path" "$@"
  local rc=$?
  [ "$rc" -eq 0 ] || note_rc 1
  return 0
}

# --- skip a tree already priced ----------------------------------------------
FP_FILE="$CACHE/.passed-fingerprint"
fingerprint() {
  { git rev-parse HEAD 2>/dev/null
    git status --porcelain -uall 2>/dev/null
    git diff HEAD 2>/dev/null
  } | sha1sum 2>/dev/null | cut -d' ' -f1
}
FP=""
if [ "$GATE" = 1 ] && git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  FP="$(fingerprint)"
  if [ -n "$FP" ] && [ -s "$FP_FILE" ] && [ "$FP" = "$(cat "$FP_FILE" 2>/dev/null)" ]; then
    exit 0
  fi
fi

# BOTH RATCHETS SEE ONLY TRACKED FILES, so a run before `git add` grades a
# SUBSET and can answer "nothing to pay" about a tree that owes. That is this
# estate's signature defect wearing a guard's clothes: could-not-see reading as
# nothing-wrong. Say what was left out; never silently grade less than the tree.
untracked_prose() {
  git rev-parse --git-dir >/dev/null 2>&1 || return 0
  git ls-files --others --exclude-standard 2>/dev/null \
    | grep -E '\.(sh|py|md|yml|yaml|jq|tsv)$' || true
}
u="$(untracked_prose)"
if [ -n "$u" ]; then
  say "-- UNTRACKED, so NEITHER ratchet below counted them. \`git add\` first or this number is a subset:"
  printf '%s\n' "$u" | sed 's/^/     /'
fi

# --- etalon's guards, by reference --------------------------------------------
for l in exit-codes.sh cli-guard.sh; do fetch_guard "lib/$l" >/dev/null; done

for g in markdown-cost.sh state-prose-lint.sh; do
  p="$(fetch_guard "$g")"
  if [ -z "$p" ]; then
    printf 'tarife: BLIND -- %s could not be fetched and no cached copy exists.\n' "$g" >&2
    printf '        Run once with a network and a `gh` token to warm %s.\n' "$CACHE" >&2
    blind=1
    continue
  fi
  case "$g" in
    markdown-cost.sh)    MARKDOWN_COST_RATCHET="$PWD/.prose-ratchet"    run_guard "prose ratchet ($g)" "$p" --census ;;
    state-prose-lint.sh) STATE_PROSE_RATCHET="$PWD/.state-prose-ratchet" run_guard "state prose ($g)" "$p" ;;
  esac
done

if [ "$GATE" = 1 ]; then
  say "-- shellcheck: skipped under --gate (88s on this tree; run bare \`tarife\` before a push)"
elif [ -x "$HERE/shellcheck-lint.sh" ] && command -v shellcheck >/dev/null 2>&1; then
  run_guard 'shellcheck' "$HERE/shellcheck-lint.sh"
else
  say "-- shellcheck: not installed, skipped"
fi

if [ "$blind" = 1 ] && [ "$rc_worst" -eq 0 ]; then
  exit 6
fi
if [ "$rc_worst" -eq 0 ]; then
  [ -n "$FP" ] && printf '%s' "$FP" > "$FP_FILE" 2>/dev/null   # only a PASS is remembered
  say "tarife: nothing to pay before you push."
fi
exit "$rc_worst"
