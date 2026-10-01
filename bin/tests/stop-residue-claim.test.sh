#!/usr/bin/env bash
set -uo pipefail  # bin/tests/stop-residue-claim.test.sh: witness for completion_claims() in hooks/stop-residue-gate.sh -- #681's unfiled-finding half, refiled as #752
. "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib/harness.sh"
SCRIPT="$(cd "$(dirname "$0")/.." && pwd)/../hooks/stop-residue-gate.sh"
[ -x "$SCRIPT" ] || { echo "FAIL: $SCRIPT not executable"; exit 1; }

harness_tmp

newrepo() { # a clean tree with an upstream, so only the claim check can speak
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

user_turn() { jq -nc --arg t "$1" '{"type":"user","message":{"content":[{"type":"text","text":$t}]}}'; }
asst_turn() { jq -nc --arg t "$1" '{"type":"assistant","message":{"content":[{"type":"text","text":$t}]}}'; }
bash_act()  { jq -nc --arg c "$1" '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":$c}}]}}'; }
edit_act()  { jq -nc --arg f "$1" '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Edit","input":{"file_path":$f}}]}}'; }
tool_out()  { jq -nc --arg o "$1" '{"type":"user","message":{"content":[{"type":"tool_result","content":[]}]},"toolUseResult":{"stdout":$o}}'; }

run()  { printf '{"cwd":"%s","transcript_path":"%s","stop_hook_active":false}' "$1" "$2" | "$SCRIPT" 2>&1; }
rcof() { printf '{"cwd":"%s","transcript_path":"%s","stop_hook_active":false}' "$1" "$2" | "$SCRIPT" >/dev/null 2>&1; printf '%s' "$?"; }

R="$T/repo"; newrepo "$R"

section "A. a completion claim is graded against this turn's tool calls (#752)"

{ user_turn "file the guard gap"
  asst_turn "Reading the hook now."
  bash_act "gh issue create -R hf7y/realisateur -F /tmp/body"
  tool_out "https://github.com/hf7y/realisateur/issues/900"
  asst_turn "I filed the gap as an issue."; } > "$T/a1.jsonl"
rc "A1 claims to have filed, and did -> exit 0" 0 "$(rcof "$R" "$T/a1.jsonl")"

{ user_turn "file the guard gap"
  asst_turn "I filed the gap as an issue."; } > "$T/a2.jsonl"
A2_OUT="$(run "$R" "$T/a2.jsonl")"
rc  "A2 claims to have filed, and did not -> BLOCKED (2)" 2 "$(rcof "$R" "$T/a2.jsonl")"
has "A2 quotes the claim it could not verify" "$A2_OUT" "I filed the gap as an issue."
has "A2 names the rule, not a policy file"    "$A2_OUT" "Fix it in the turn you found it"

{ user_turn "what does the gate do?"
  asst_turn "It blocks an open non-draft PR and a dirty tree. The unfiled-finding half was never attempted, which is what hooks/stop-residue-gate.sh:2 records."; } > "$T/a3.jsonl"
rc "A3 an ordinary conversational answer, no claim -> exit 0" 0 "$(rcof "$R" "$T/a3.jsonl")"

printf 'not json at all\n{{{\n' > "$T/a4.jsonl"
rc "A4 an unparseable transcript fails OPEN -> exit 0" 0 "$(rcof "$R" "$T/a4.jsonl")"

{ user_turn "fix the unquoted variable"
  edit_act "$R/bin/thing.sh"
  asst_turn "Done."; } > "$T/a5.jsonl"
rc "A5 acted without claiming anything -> exit 0" 0 "$(rcof "$R" "$T/a5.jsonl")"

section "B. citation, promise, and turn scope"

{ user_turn "did you file it?"
  tool_out "https://github.com/hf7y/realisateur/issues/684"
  user_turn "so what happened"
  asst_turn "I filed #684. This is the cleanup."; } > "$T/b1.jsonl"
rc "B1 a recap citing an artifact this transcript has seen -> exit 0" 0 "$(rcof "$R" "$T/b1.jsonl")"

{ user_turn "so what happened"
  asst_turn "I filed it as #781, so that is handled."; } > "$T/b2.jsonl"
B2_OUT="$(run "$R" "$T/b2.jsonl")"
rc  "B2 a cited number the transcript has never seen -> BLOCKED (2)" 2 "$(rcof "$R" "$T/b2.jsonl")"
has "B2 quotes the fabricated citation" "$B2_OUT" "#781"

{ user_turn "anything else broken?"
  asst_turn "The guard scrapes an unexpanded \$HOME. I'll file that as an issue."; } > "$T/b3.jsonl"
B3_OUT="$(run "$R" "$T/b3.jsonl")"
rc  "B3 a promise the ending turn never kept -> BLOCKED (2)" 2 "$(rcof "$R" "$T/b3.jsonl")"
has "B3 quotes the promise" "$B3_OUT" "I'll file that as an issue."

{ user_turn "file it"
  asst_turn "I filed the gap as an issue."
  user_turn "now explain it"
  asst_turn "It refuses a turn whose text outruns its tool calls."; } > "$T/b4.jsonl"
rc "B4 a claim from a PRIOR turn does not block THIS turn" 0 "$(rcof "$R" "$T/b4.jsonl")"

{ user_turn "was it deleted?"
  asst_turn "install-shims.sh was deleted by #511, and the decision landed with it. The remedy parked rather than deleted."; } > "$T/b5.jsonl"
rc "B5 third-person history using the same verbs -> exit 0" 0 "$(rcof "$R" "$T/b5.jsonl")"

section "C. a defect stated with no artifact at all -- the unfiled finding (#752 option 2)"

DEFECT="@bin/lib/propagation-set.sh@ is filed LOCAL today, so it does not exist on any account."
BT=$'\x60'
DEFECT="${DEFECT//@/$BT}"

{ user_turn "have a look at the propagation set"
  asst_turn "$DEFECT"; } > "$T/c1.jsonl"
C1_OUT="$(run "$R" "$T/c1.jsonl")"
rc  "C1 a stated defect with no artifact -> BLOCKED (2)" 2 "$(rcof "$R" "$T/c1.jsonl")"
has "C1 quotes the sentence that carries the finding" "$C1_OUT" "does not exist on any account"
has "C1 names the rule, not a policy file"            "$C1_OUT" "Fix it in the turn you found it"

{ user_turn "have a look at the propagation set"
  bash_act "gh issue create -R hf7y/realisateur -F /tmp/body"
  tool_out "https://github.com/hf7y/realisateur/issues/901"
  asst_turn "$DEFECT"; } > "$T/c2.jsonl"
rc "C2 the same defect, filed in the same turn -> exit 0" 0 "$(rcof "$R" "$T/c2.jsonl")"

{ user_turn "have a look at the propagation set"
  edit_act "$R/bin/lib/propagation-set.sh"
  asst_turn "$DEFECT"; } > "$T/c3.jsonl"
rc "C3 the same defect, fixed in the same turn -> exit 0" 0 "$(rcof "$R" "$T/c3.jsonl")"

{ user_turn "what does the carry ledger key on?"
  asst_turn "${BT}bin/lib/carries.tsv${BT} names the file, never the branch (${BT}carry.sh:10${BT}), and ${BT}reprise.sh${BT} reads the same row."; } > "$T/c4.jsonl"
rc "C4 a descriptive explanation with citations -> exit 0" 0 "$(rcof "$R" "$T/c4.jsonl")"

{ user_turn "what did the issue say?"
  asst_turn "The issue body said:

> ${BT}bin/weight-audit.sh${BT} does not exist.

That is the claim I am checking next."; } > "$T/c5.jsonl"
rc "C5 a defect quoted in a blockquote is not this turn's assertion -> exit 0" 0 "$(rcof "$R" "$T/c5.jsonl")"

{ user_turn "what did the header claim?"
  asst_turn "Its header claims \"${BT}bin/weight-audit.sh${BT} does not exist\" and I have not checked that yet."; } > "$T/c6.jsonl"
rc "C6 a defect inside an inline quotation -> exit 0" 0 "$(rcof "$R" "$T/c6.jsonl")"

{ user_turn "show me the snippet"
  asst_turn "The relevant line is:

${BT}${BT}${BT}
${BT}bin/weight-audit.sh${BT} does not exist
${BT}${BT}${BT}

which is what I am about to test."; } > "$T/c7.jsonl"
rc "C7 a defect inside a fenced block -> exit 0" 0 "$(rcof "$R" "$T/c7.jsonl")"

{ user_turn "anything broken?"
  asst_turn "Nothing is broken: ${BT}bin/crt-stt-speakback.sh${BT} and the debug view are opt-in already."; } > "$T/c8.jsonl"
rc "C8 a sentence whose subject is 'nothing' makes the opposite claim -> exit 0" 0 "$(rcof "$R" "$T/c8.jsonl")"

{ user_turn "did we ever record that?"
  tool_out "https://github.com/hf7y/realisateur/issues/233"
  user_turn "so what is the state"
  asst_turn "${BT}bin/hygiene-lint.sh${BT} never runs its per-project check; that is #233."; } > "$T/c9.jsonl"
rc "C9 a defect citing an artifact this transcript has seen -> exit 0" 0 "$(rcof "$R" "$T/c9.jsonl")"

{ user_turn "anything broken?"
  asst_turn "The per-project check never runs and the whole thing is stale."; } > "$T/c10.jsonl"
rc "C10 a defect that names no artifact -> exit 0 (it must name what it accuses)" 0 "$(rcof "$R" "$T/c10.jsonl")"

printf 'not json at all\n{{{\n' > "$T/c11.jsonl"
rc "C11 an unparseable transcript fails OPEN on the defect path too -> exit 0" 0 "$(rcof "$R" "$T/c11.jsonl")"

NOJQ="$T/nojq"; mkdir -p "$NOJQ"
for c in bash cat dirname git grep sed awk; do ln -s "$(command -v "$c")" "$NOJQ/$c"; done
rc "B6 no jq on PATH -- the claim check is skipped, not an error" 0 \
   "$(printf '{"cwd":"%s","transcript_path":"%s","stop_hook_active":false}' "$R" "$T/a2.jsonl" | PATH="$NOJQ" "$SCRIPT" >/dev/null 2>&1; printf '%s' "$?")"


section "L. a thing named and left unfixed is not a report, it is residue (#1389)"

{ user_turn "check the handoff"
  asst_turn "#1374 still states 117; the real count is 110. I have not edited it."; } > "$T/l1.jsonl"
rc  "L1 names an issue and says it was not edited -> BLOCKED (2)" 2 "$(rcof "$R" "$T/l1.jsonl")"
has "L1 the block quotes the ruling" "$(run "$R" "$T/l1.jsonl")" "You fix when you find"

{ user_turn "check the handoff"
  edit_act "/tmp/memory.md"
  asst_turn "#1374 still states 117; the real count is 110. I have not edited it."; } > "$T/l2.jsonl"
rc "L2 an unrelated act in the same turn does not excuse it -> BLOCKED (2)" 2 "$(rcof "$R" "$T/l2.jsonl")"

{ user_turn "check the handoff"
  asst_turn "The runner registrations were not fixed: I cannot remove them, the permission layer refused."; } > "$T/l3.jsonl"
rc "L3 out of reach, and says so -> exit 0" 0 "$(rcof "$R" "$T/l3.jsonl")"

{ user_turn "check the handoff"
  asst_turn "The page was not updated last night, and nothing here names what."; } > "$T/l4.jsonl"
rc "L4 names no issue and no file -> exit 0" 0 "$(rcof "$R" "$T/l4.jsonl")"

{ user_turn "check the handoff"
  asst_turn "#1374 said 117. I corrected it to 110 and closed it."; } > "$T/l5.jsonl"
rc "L5 found it and fixed it -> exit 0" 0 "$(rcof "$R" "$T/l5.jsonl")"

summary || exit 1
