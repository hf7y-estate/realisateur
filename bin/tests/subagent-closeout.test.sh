#!/usr/bin/env bash
#
# Witness for hooks/subagent-closeout.sh, including #363's tree discovery.

set -uo pipefail
# shellcheck source=bin/tests/lib/harness.sh
. "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib/harness.sh"
SCRIPT="$(cd "$(dirname "$0")/.." && pwd)/../hooks/subagent-closeout.sh"
[ -x "$SCRIPT" ] || { echo "FAIL: $SCRIPT not executable"; exit 1; }

harness_tmp

newrepo() { # newrepo <path> -- pushed to a bare remote, so no host-only-branch flag.
  local bare="$1.git"
  git init -q --bare "$bare"
  git clone -q "$bare" "$1" 2>/dev/null
  git -C "$1" config user.email t@test
  git -C "$1" config user.name T
  git -C "$1" checkout -q -B main
  git -C "$1" commit -q --allow-empty -m init
  git -C "$1" push -q origin main
  git -C "$1" branch -q --set-upstream-to=origin/main
}

transcript_writing() { # transcript_writing <path> <file...>
  local out="$1"; shift
  : > "$out"
  for f in "$@"; do
    printf '{"message":{"content":[{"type":"tool_use","name":"Write","input":{"file_path":"%s"}}]}}\n' "$f" >> "$out"
  done
}

payload() { # payload <cwd> [<transcript>] [<session_id>] [<agent_id>]
  local cwd="$1" transcript="${2:-}" sid="${3:-}" aid="${4:-}"
  printf '{"cwd":"%s","agent_transcript_path":"%s","session_id":"%s","agent_id":"%s","stop_hook_active":false}' \
    "$cwd" "$transcript" "$sid" "$aid"
}

run() { payload "$1" "${2:-}" | "$SCRIPT" 2>&1; }

# Hermetic PR half: $T/pr-state is what the tracker says.
mkdir -p "$T/bin"
cat > "$T/bin/gh" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *pulls/*) cat "$STUB_PR" 2>/dev/null || exit 1 ;;
esac
EOF
chmod +x "$T/bin/gh"
# The env prefixes bind to the SCRIPT, not `payload`: it is across the pipe.
runpr() { payload "$1" "${2:-}" | STUB_PR="$T/pr-state" PATH="$T/bin:$PATH" "$SCRIPT" 2>&1; }
rcof()  { payload "$1" "${2:-}" | STUB_PR="$T/pr-state" PATH="$T/bin:$PATH" "$SCRIPT" >/dev/null 2>&1; printf '%s' "$?"; }
transcript_pr() {
  printf '%s\n' \
    '{"message":{"content":[{"type":"tool_use","id":"tu1","name":"Bash","input":{"command":"gh pr create --fill"}}]}}' \
    '{"message":{"content":[{"type":"tool_result","tool_use_id":"tu1","content":"https://github.com/hf7y/widget/pull/7"}]}}' \
    > "$1"
}
transcript_pr_quoted() {
  printf '%s\n' \
    '{"message":{"content":[{"type":"tool_use","id":"tu1","name":"Bash","input":{"command":"cat bin/tests/subagent-closeout.test.sh"}}]}}' \
    '{"message":{"content":[{"type":"tool_result","tool_use_id":"tu1","content":"transcript_pr() { printf https://github.com/hf7y/widget/pull/7 ; }"}]}}' \
    > "$1"
}

section "A. baseline behavior is unchanged"

newrepo "$T/clean"
A1_OUT="$(run "$T/clean")"; A1_RC=$?
rc "A1 clean cwd, no transcript -> exit 0" 0 "$A1_RC"

# A2 CHANGED 2026-08-29: an unattributable change is not one to demand back.
newrepo "$T/dirty"
echo scratch > "$T/dirty/f.txt"
A2_OUT="$(run "$T/dirty")"; A2_RC=$?
rc  "A2 dirty cwd, no baseline, no transcript -> warns, does not block (0)" 0 "$A2_RC"
has "A2 names cwd as the tree it cannot attribute" "$A2_OUT" "$T/dirty"
has "A2 says the ambiguity out loud" "$A2_OUT" "UNATTRIBUTED"
hasnt "A2 does not accuse" "$A2_OUT" "BLOCKED"

A3_OUT="$(printf '{"cwd":"%s","stop_hook_active":true}' "$T/dirty" | "$SCRIPT" 2>&1)"; A3_RC=$?
rc "A3 stop_hook_active loop guard still exits 0 on a dirty tree" 0 "$A3_RC"

section "B. #363 -- trees the subagent actually wrote to"

newrepo "$T/cwdrepo"
newrepo "$T/writtenrepo"
echo scratch > "$T/writtenrepo/w.txt"
transcript_writing "$T/t1.jsonl" "$T/writtenrepo/w.txt"
B1_OUT="$(run "$T/cwdrepo" "$T/t1.jsonl")"; B1_RC=$?
rc  "B1 clean cwd, transcript wrote elsewhere -> BLOCKED (2)" 2 "$B1_RC"
has "B1 names the WRITTEN tree, not just cwd"   "$B1_OUT" "$T/writtenrepo"

newrepo "$T/cwdrepo2"
newrepo "$T/cleanwritten"
transcript_writing "$T/t2.jsonl" "$T/cleanwritten/nope.txt"
B2_OUT="$(run "$T/cwdrepo2" "$T/t2.jsonl")"; B2_RC=$?
rc "B2 clean cwd, transcript wrote to a tree that is ALSO clean -> exit 0" 0 "$B2_RC"

: > "$T/empty.jsonl"
newrepo "$T/cwdrepo3"
B3_OUT="$(run "$T/cwdrepo3" "$T/empty.jsonl")"; B3_RC=$?
rc "B3 empty transcript behaves like no transcript -> exit 0" 0 "$B3_RC"

B4_OUT="$(run "$T/cwdrepo3" "$T/does-not-exist.jsonl")"; B4_RC=$?
rc "B4 unreadable transcript path does not error -- falls back to cwd only" 0 "$B4_RC"

newrepo "$T/cwdrepo4"
echo scratch > "$T/cwdrepo4/dirty.txt"
transcript_writing "$T/t5.jsonl" "$T/cwdrepo4/dirty.txt"
B5_OUT="$(run "$T/cwdrepo4" "$T/t5.jsonl")"; B5_RC=$?
rc "B5 transcript re-naming cwd itself does not double-report" 2 "$B5_RC"
# space-or-EOL, not EOL alone: the fallback path (no closeout-lint on PATH,
# CI's case) appends " (N uncommitted change(s))" after the tree.
B5_COUNT="$(printf '%s\n' "$B5_OUT" | grep -cE "tree: $T/cwdrepo4( |\$)")"
eq "B5 cwd listed exactly once" "$B5_COUNT" "1"

echo
section "G. a PR this run opened, still open, is not a finished run"
G="$T/g"; newrepo "$G"
TR="$T/g-transcript"; transcript_pr "$TR"

printf 'open\tfalse\tfalse\tclean\tNO-DECISION: x\n\n<!-- DELIVERS -->\n- none\n<!-- /DELIVERS -->' > "$T/pr-state"
OUT="$(runpr "$G" "$TR")"; RC="$(rcof "$G" "$TR")"
rc  "G1 an open non-draft PR blocks the stop" 2 "$RC"
has "G2 and names the PR" "$OUT" "pull/7"
has "G3 and says a draft is the honest way to stop" "$OUT" "convert it to a DRAFT"

printf 'open\ttrue\tfalse\tclean\tNO-DECISION: x\n\n<!-- DELIVERS -->\n- none\n<!-- /DELIVERS -->' > "$T/pr-state"
RC="$(rcof "$G" "$TR")"
rc "G4 a DRAFT claims nothing, so it does not block" 0 "$RC"

printf 'closed\tfalse\tfalse\tclean\tNO-DECISION: x' > "$T/pr-state"
RC="$(rcof "$G" "$TR")"
rc "G5 a merged or closed PR does not block" 0 "$RC"

printf 'open\tfalse\ttrue\tclean\tNO-DECISION: x\n\n<!-- DELIVERS -->\n- none\n<!-- /DELIVERS -->' > "$T/pr-state"
OUT="$(runpr "$G" "$TR")"; RC="$(rcof "$G" "$TR")"
rc  "G5a an armed, mergeable PR does not block" 0 "$RC"
has "G5b and says so" "$OUT" "AUTO-MERGE ARMED"

# ARMED AND CONFLICTED NEVER LANDS (#1155).
printf 'open\tfalse\ttrue\tdirty\tNO-DECISION: x\n\n<!-- DELIVERS -->\n- none\n<!-- /DELIVERS -->' > "$T/pr-state"
OUT="$(runpr "$G" "$TR")"; RC="$(rcof "$G" "$TR")"
rc    "G5c armed but mergeable_state=dirty blocks -- it will never land" 2 "$RC"
has   "G5d and names the conflict" "$OUT" "mergeable_state=DIRTY"
hasnt "G5e does not claim it lands when its checks pass" "$OUT" "it lands when its required checks pass"

printf 'open\tfalse\ttrue\tunknown\tNO-DECISION: x\n\n<!-- DELIVERS -->\n- none\n<!-- /DELIVERS -->' > "$T/pr-state"
RC="$(rcof "$G" "$TR")"
rc "G5f armed with mergeable_state=unknown (a cold read) does not block" 0 "$RC"

printf 'open\tfalse\tfalse\tclean\tNO-DECISION: no ledger here' > "$T/pr-state"
OUT="$(runpr "$G" "$TR")"
has "G6 an open PR with no DELIVERS block says nothing can check it" "$OUT" "no DELIVERS block"

: > "$T/pr-state"
RC="$(rcof "$G" "$TR")"
rc "G7 an unreadable tracker reports but does not block" 0 "$RC"

# CI has no closeout-lint and takes the fallback path; the check runs on both.
printf 'open\tfalse\tfalse\tclean\tNO-DECISION: x' > "$T/pr-state"
RC="$(payload "$G" "$TR" | STUB_PR="$T/pr-state" PATH="$T/bin:/usr/bin:/bin" "$SCRIPT" >/dev/null 2>&1; printf '%s' "$?")"
rc "G8 it blocks even with no closeout-lint on PATH (the fallback path)" 2 "$RC"

printf 'open\tfalse\tfalse\tclean\tNO-DECISION: x' > "$T/pr-state"
QTR="$T/g-quoted"; transcript_pr_quoted "$QTR"
OUT="$(runpr "$G" "$QTR")"; RC="$(rcof "$G" "$QTR")"
rc  "G9 a PR URL the agent only READ does not block" 0 "$RC"
hasnt "G10 and is not reported at all" "$OUT" "pull/7"

section "H. scoped to THIS agent's changes (the 2026-08-29 shared-checkout bug)"

JOB="$T/job"; mkdir -p "$JOB/tmp"   # SubagentStart is the same script, --baseline
mark()  { payload "$1" "" "$2" "${3:-}" | CLAUDE_JOB_DIR="$JOB" "$SCRIPT" --baseline >/dev/null 2>&1; printf '%s' "$?"; }
runb()  { payload "$1" "${4:-}" "$2" "${3:-}" | CLAUDE_JOB_DIR="$JOB" "$SCRIPT" 2>&1; }
rcb()   { payload "$1" "${4:-}" "$2" "${3:-}" | CLAUDE_JOB_DIR="$JOB" "$SCRIPT" >/dev/null 2>&1; printf '%s' "$?"; }

newrepo "$T/own"
RC="$(mark "$T/own" sess-a agent-a)"
rc "H1a --baseline exits 0" 0 "$RC"
echo mine > "$T/own/mine.txt"
H1="$(runb "$T/own" sess-a agent-a)"; H1_RC="$(rcb "$T/own" sess-a agent-a)"
rc  "H1 own change after the baseline -> BLOCKED (2)" 2 "$H1_RC"
has "H1 names it as YOURS" "$H1" "YOURS"
has "H1 names the file"    "$H1" "mine.txt"

newrepo "$T/foreign"
echo theirs > "$T/foreign/vmhost.sh"
echo theirs > "$T/foreign/repose.sh"
mark "$T/foreign" sess-b agent-b >/dev/null
H2="$(runb "$T/foreign" sess-b agent-b)"; H2_RC="$(rcb "$T/foreign" sess-b agent-b)"
rc    "H2 pre-existing foreign dirt alone -> does NOT block (0)" 0 "$H2_RC"
has   "H2 reports it as context"           "$H2" "NOT YOURS"
has   "H2 names the foreign file"          "$H2" "vmhost.sh"
hasnt "H2 does not accuse"                 "$H2" "BLOCKED"
hasnt "H2 never tells it to revert them"   "$H2" "git restore"
hasnt "H2 never tells it to commit them"   "$H2" "git commit"

newrepo "$T/both"
echo theirs > "$T/both/theirs.txt"
mark "$T/both" sess-c agent-c >/dev/null
echo mine > "$T/both/mine.txt"
H3="$(runb "$T/both" sess-c agent-c)"; H3_RC="$(rcb "$T/both" sess-c agent-c)"
rc  "H3 own + foreign -> BLOCKED (2)" 2 "$H3_RC"
has "H3 counts ONLY the agent's own change" "$H3" "leaving 1 uncommitted change(s) of your own"
H3_YOURS="$(printf '%s\n' "$H3" | sed -n '/^YOURS/,/^$/p')"
has   "H3 YOURS lists the agent's file"     "$H3_YOURS" "mine.txt"
hasnt "H3 YOURS does not list the foreign file" "$H3_YOURS" "theirs.txt"
has   "H3 the foreign file is context"      "$H3" "NOT YOURS"
has   "H3 says to leave the foreign work alone" "$H3" "Leave these exactly as they are"

newrepo "$T/nobase"
echo whoever > "$T/nobase/x.txt"
H4="$(runb "$T/nobase" sess-d agent-d)"; H4_RC="$(rcb "$T/nobase" sess-d agent-d)"
rc    "H4 no baseline -> warns, does not block (0)" 0 "$H4_RC"
has   "H4 names the ambiguity" "$H4" "UNATTRIBUTED"
hasnt "H4 does not accuse"     "$H4" "YOURS -- new since"

newrepo "$T/stale"
mark "$T/stale" sess-e agent-e >/dev/null
echo whoever > "$T/stale/x.txt"
touch -d '2 days ago' "$JOB/tmp/subagent-closeout-baselines/sess-e.agent-e"
H5_RC="$(rcb "$T/stale" sess-e agent-e)"
rc "H5 a baseline older than the max age is treated as no baseline" 0 "$H5_RC"

RC="$(mark "$T/dirty" sess-f agent-f)"
rc "H6 --baseline on a dirty tree still exits 0" 0 "$RC"
RC="$(mark "$T" sess-g agent-g)"
rc "H7 --baseline outside a repo still exits 0" 0 "$RC"

section "I. closeout-lint's findings are scoped the same way"
# The lint path sees what git status cannot; #511 deleted it, so this stubs it.
mkdir -p "$T/lintbin"
cat > "$T/lintbin/closeout-lint" <<'EOF'
#!/usr/bin/env bash
case "$*" in *--help*) echo "usage: closeout-lint --strict --allow-blind --repo <path>"; exit 0 ;; esac
cat "$STUB_LINT"; exit 1
EOF
chmod +x "$T/lintbin/closeout-lint"
markl() { payload "$1" "" "$2" "$3" | CLAUDE_JOB_DIR="$JOB" STUB_LINT="$T/lint-state" PATH="$T/lintbin:$PATH" "$SCRIPT" --baseline >/dev/null 2>&1; }
runl()  { payload "$1" "" "$2" "$3" | CLAUDE_JOB_DIR="$JOB" STUB_LINT="$T/lint-state" PATH="$T/lintbin:$PATH" "$SCRIPT" 2>&1; }
rcl()   { payload "$1" "" "$2" "$3" | CLAUDE_JOB_DIR="$JOB" STUB_LINT="$T/lint-state" PATH="$T/lintbin:$PATH" "$SCRIPT" >/dev/null 2>&1; printf '%s' "$?"; }

newrepo "$T/lintrepo"
printf '  FLAG [host-only-branch] wip/theirs exists on this host only\n' > "$T/lint-state"
markl "$T/lintrepo" sess-h agent-h
I1_OUT="$(runl "$T/lintrepo" sess-h agent-h)"; I1_RC="$(rcl "$T/lintrepo" sess-h agent-h)"
rc  "I1 a finding that was ALREADY there does not block" 0 "$I1_RC"
has "I1 and is reported as context"                      "$I1_OUT" "NOT YOURS"

printf '  FLAG [host-only-branch] wip/theirs exists on this host only\n  FLAG [unpushed] 2 commits ahead of origin/main\n' > "$T/lint-state"
I2_OUT="$(runl "$T/lintrepo" sess-h agent-h)"; I2_RC="$(rcl "$T/lintrepo" sess-h agent-h)"
rc    "I2 a NEW unpushed-commit finding still blocks" 2 "$I2_RC"
has   "I2 names the new finding"                      "$I2_OUT" "unpushed"
I2_YOURS="$(printf '%s\n' "$I2_OUT" | sed -n '/^YOURS/,/^$/p')"
hasnt "I2 does not charge it with the pre-existing one" "$I2_YOURS" "host-only-branch"

I3_RC="$(payload "$T/lintrepo" "" nosess "" | CLAUDE_JOB_DIR="$JOB" STUB_LINT="$T/lint-state" PATH="$T/lintbin:$PATH" "$SCRIPT" >/dev/null 2>&1; printf '%s' "$?")"
rc "I3 lint findings with no baseline warn, they do not block" 0 "$I3_RC"


summary
[ "$fail" -eq 0 ] || exit 1
