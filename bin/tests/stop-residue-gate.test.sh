#!/usr/bin/env bash
set -uo pipefail  # bin/tests/stop-residue-gate.test.sh: witness for hooks/stop-residue-gate.sh, subagent-closeout.sh's sibling one scope up (#681)
# shellcheck source=bin/tests/lib/harness.sh
. "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib/harness.sh"
SCRIPT="$(cd "$(dirname "$0")/.." && pwd)/../hooks/stop-residue-gate.sh"
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

payload() { # payload <cwd> [<transcript>] [<session_id>]
  local cwd="$1" transcript="${2:-}" sid="${3:-}"
  printf '{"cwd":"%s","transcript_path":"%s","session_id":"%s","stop_hook_active":false}' "$cwd" "$transcript" "$sid"
}

run() { payload "$1" "${2:-}" | "$SCRIPT" 2>&1; }

user_turn()   { jq -nc --arg t "$1" '{"type":"user","message":{"content":[{"type":"text","text":$t}]}}'; } # a real prompt, no toolUseResult
tool_result() { jq -nc '{"type":"user","message":{"content":[{"type":"tool_result","content":[]}]},"toolUseResult":{"stdout":""}}'; } # NOT a turn boundary
asst_turn()   { jq -nc --arg t "$1" '{"type":"assistant","message":{"content":[{"type":"text","text":$t}]}}'; }

mkdir -p "$T/bin"
cat > "$T/bin/gh" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *check-runs*) printf '%s\n' "${STUB_FAILING:-0}" ;;
  *pulls/*)     cat "$STUB_PR" 2>/dev/null || exit 1 ;;
  *issues/*)    [ -n "${STUB_ISSUE:-}" ] || exit 1; printf '%s\n' "$STUB_ISSUE" ;;
esac
EOF
chmod +x "$T/bin/gh"
runpr() { payload "$1" "${2:-}" | STUB_PR="$T/pr-state" PATH="$T/bin:$PATH" "$SCRIPT" 2>&1; }
rcof()  { payload "$1" "${2:-}" | STUB_PR="$T/pr-state" PATH="$T/bin:$PATH" "$SCRIPT" >/dev/null 2>&1; printf '%s' "$?"; }
cmd_result() { # cmd_result <command> <stdout> -- a Bash call and its paired result
  jq -nc --arg c "$1" '{"type":"assistant","message":{"content":[{"type":"tool_use","id":"tu1","name":"Bash","input":{"command":$c}}]}}'
  jq -nc --arg o "$2" '{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"tu1","content":$o}]},"toolUseResult":{"stdout":$o}}'
}
transcript_pr() { cmd_result 'gh pr create --fill' 'https://github.com/hf7y/widget/pull/7' > "$1"; }

section "A. baseline behavior"

newrepo "$T/clean"
A1_OUT="$(run "$T/clean")"; A1_RC=$?
rc "A1 clean cwd, no transcript -> exit 0" 0 "$A1_RC"

newrepo "$T/dirty"
echo scratch > "$T/dirty/f.txt"
A2_OUT="$(run "$T/dirty")"; A2_RC=$?
rc    "A2 dirty cwd, no baseline -> warns, does not block (#773)" 0 "$A2_RC"
has   "A2 still names cwd as the dirty tree" "$A2_OUT" "$T/dirty"
has   "A2 names the ambiguity instead"       "$A2_OUT" "UNATTRIBUTED"
hasnt "A2 does not accuse"                   "$A2_OUT" "BLOCKED"

A3_OUT="$(printf '{"cwd":"%s","stop_hook_active":true}' "$T/dirty" | "$SCRIPT" 2>&1)"; A3_RC=$?
rc "A3 stop_hook_active loop guard still exits 0 on a dirty tree" 0 "$A3_RC"

section "B. a turn that wrote outside cwd (worktree isolation)"

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

echo
section "C. a PR this turn opened, still open, is not a finished run"
G="$T/g"; newrepo "$G"
TR="$T/g-transcript"; transcript_pr "$TR"

# These run WITH a baseline, and pr-state carries a created_at after it. Fixed
# dates, never `date`: a suite that drifts with the clock is worse than one
# that fails.
CJOB="$T/cjob"; mkdir -p "$CJOB/tmp"
CSID="c-session"
payload "$G" "" "$CSID" | CLAUDE_JOB_DIR="$CJOB" "$SCRIPT" --baseline >/dev/null 2>&1
touch -d '2026-09-07T12:00:00Z' "$CJOB/tmp/stop-residue-baselines/$CSID" 2>/dev/null
AFTER='2026-09-07T18:00:00Z'   # opened during the session
BEFORE='2026-09-06T09:00:00Z'  # somebody else's, still in flight
runpr() { payload "$1" "${2:-}" "$CSID" | STUB_PR="$T/pr-state" CLAUDE_JOB_DIR="$CJOB" PATH="$T/bin:$PATH" "$SCRIPT" 2>&1; }
rcof()  { payload "$1" "${2:-}" "$CSID" | STUB_PR="$T/pr-state" CLAUDE_JOB_DIR="$CJOB" PATH="$T/bin:$PATH" "$SCRIPT" >/dev/null 2>&1; printf '%s' "$?"; }

printf 'open\tfalse\tfalse\t%s\tdeadbee\tclean\tNO-DECISION: x\n\n<!-- DELIVERS -->\n- none\n<!-- /DELIVERS -->' "$AFTER" > "$T/pr-state"
OUT="$(runpr "$G" "$TR")"; RC="$(rcof "$G" "$TR")"
rc  "C1 an open non-draft PR blocks the stop" 2 "$RC"
has "C2 and names the PR" "$OUT" "pull/7"

printf 'open\ttrue\tfalse\t%s\tdeadbee\tclean\tNO-DECISION: x\n\n<!-- DELIVERS -->\n- none\n<!-- /DELIVERS -->' "$AFTER" > "$T/pr-state"
RC="$(rcof "$G" "$TR")"
rc "C3 a DRAFT claims nothing, so it does not block" 0 "$RC"

printf 'closed\tfalse\tfalse\t%s\tdeadbee\tclean\tNO-DECISION: x' "$AFTER" > "$T/pr-state"
RC="$(rcof "$G" "$TR")"
rc "C4 a merged or closed PR does not block" 0 "$RC"

printf 'open\tfalse\ttrue\t%s\tdeadbee\tclean\tNO-DECISION: x\n\n<!-- DELIVERS -->\n- none\n<!-- /DELIVERS -->' "$AFTER" > "$T/pr-state"
OUT="$(runpr "$G" "$TR")"; RC="$(rcof "$G" "$TR")"
rc  "C5 an open PR with AUTO-MERGE ARMED does not block" 0 "$RC"
has "C6 and says so, rather than passing silently" "$OUT" "AUTO-MERGE ARMED"

# ARMED IS NOT LANDING. The fixture above is armed AND green; these three are
# armed and RED, which merges never and which only the agent can fix.
OUT="$(STUB_FAILING=1 runpr "$G" "$TR")"; RC="$(STUB_FAILING=1 rcof "$G" "$TR")"
rc  "C5a armed but FAILING blocks -- it will never land" 2 "$RC"
has "C5b and says arming is not landing"        "$OUT" "armed is not landing"
has "C5c and counts the failing checks"         "$OUT" "1 required check(s) FAILING"
OUT="$(STUB_FAILING=BLIND runpr "$G" "$TR")"; RC="$(STUB_FAILING=BLIND rcof "$G" "$TR")"
rc  "C5d checks it cannot read fail OPEN -- a stop guard must not block on BLIND" 0 "$RC"
has "C5e and says the checks could not be read" "$OUT" "could not be read"

# NOTHING FAILING IS NOT NOTHING BLOCKING (#1260): zero required checks and
# mergeable_state=blocked means a required review holds it, not a check.
printf 'open\tfalse\ttrue\t%s\tdeadbee\tblocked\tNO-DECISION: x\n\n<!-- DELIVERS -->\n- none\n<!-- /DELIVERS -->' "$AFTER" > "$T/pr-state"
OUT="$(runpr "$G" "$TR")"; RC="$(rcof "$G" "$TR")"
rc  "C5f armed, nothing failing, but mergeable_state=BLOCKED still blocks" 2 "$RC"
has "C5g and names BLOCKED rather than claiming checks will land it" "$OUT" "mergeable_state=BLOCKED"
hasnt "C5h does not claim it lands when its checks pass" "$OUT" "it lands when its checks pass"

# ARMED AND CONFLICTED NEVER LANDS (#1155): its checks are stale passes.
printf 'open\tfalse\ttrue\t%s\tdeadbee\tdirty\tNO-DECISION: x\n\n<!-- DELIVERS -->\n- none\n<!-- /DELIVERS -->' "$AFTER" > "$T/pr-state"
OUT="$(runpr "$G" "$TR")"; RC="$(rcof "$G" "$TR")"
rc    "C5i armed, nothing failing, but mergeable_state=DIRTY blocks" 2 "$RC"
has   "C5j and names the conflict" "$OUT" "mergeable_state=DIRTY"
hasnt "C5k does not claim it lands when its checks pass" "$OUT" "it lands when its checks pass"

printf 'open\tfalse\ttrue\t%s\tdeadbee\tunknown\tNO-DECISION: x\n\n<!-- DELIVERS -->\n- none\n<!-- /DELIVERS -->' "$AFTER" > "$T/pr-state"
RC="$(rcof "$G" "$TR")"
rc "C5l armed with mergeable_state=unknown (a cold read) does not block" 0 "$RC"

printf 'open\tfalse\tfalse\t%s\tdeadbee\tclean\tNO-DECISION: x\n\n<!-- DELIVERS -->\n- none\n<!-- /DELIVERS -->' "$AFTER" > "$T/pr-state"
OUT="$(runpr "$G" "$TR")"
has "C7 the refusal names arming auto-merge as the preferred exit" "$OUT" "--auto"

# A PR a `gh pr list` only SHOWED is not one this turn opened (#1172).
cmd_result 'gh pr list' '7  fix  https://github.com/hf7y/widget/pull/7' > "$T/g-listed"
OUT="$(runpr "$G" "$T/g-listed")"; RC="$(rcof "$G" "$T/g-listed")"
rc    "C7a a PR URL in a gh pr list result, no gh pr create -> does not block" 0 "$RC"
hasnt "C7b and is not reported at all" "$OUT" "pull/7"

# `gh pr comment` prints .../pull/N#issuecomment-ID, which read as a PR this
# turn opened.
printf 'open\tfalse\tfalse\t%s\tdeadbee\tclean\tNO-DECISION: x\n\n<!-- DELIVERS -->\n- none\n<!-- /DELIVERS -->' "$BEFORE" > "$T/pr-state"
OUT="$(runpr "$G" "$TR")"; RC="$(rcof "$G" "$TR")"
rc  "C8 a PR opened before this session does not block" 0 "$RC"
has "C9 and it says mentioned, not opened here"         "$OUT" "predates this session"

# No baseline: it cannot tell whose PR is whose and BLOCKS anyway. A
# no-baseline pass is indistinguishable from disabling the check.
printf 'open\tfalse\tfalse\t%s\tdeadbee\tclean\tNO-DECISION: x\n\n<!-- DELIVERS -->\n- none\n<!-- /DELIVERS -->' "$AFTER" > "$T/pr-state"
NB="$T/nb"; mkdir -p "$NB/tmp"
nb_run() { payload "$G" "$TR" "no-baseline-sid" | STUB_PR="$T/pr-state" CLAUDE_JOB_DIR="$NB" PATH="$T/bin:$PATH" "$SCRIPT"; }
OUT="$(nb_run 2>&1)"
nb_run >/dev/null 2>&1; NBRC=$?
rc  "C10 no baseline still blocks on an open PR" 2 "$NBRC"
has "C11 and admits it cannot tell whose it is" "$OUT" "cannot tell whether you opened it"

# What makes blocking safe rather than a wall.
OUT2="$(printf '{"cwd":"%s","transcript_path":"%s","session_id":"nb2","stop_hook_active":true}' "$G" "$TR" \
        | STUB_PR="$T/pr-state" CLAUDE_JOB_DIR="$NB" PATH="$T/bin:$PATH" "$SCRIPT" 2>&1)"
printf '{"cwd":"%s","transcript_path":"%s","session_id":"nb2","stop_hook_active":true}' "$G" "$TR" \
  | STUB_PR="$T/pr-state" CLAUDE_JOB_DIR="$NB" PATH="$T/bin:$PATH" "$SCRIPT" >/dev/null 2>&1
rc "C12 a re-fired Stop exits 0, so the block surfaces once" 0 "$?"

# A stopping state is one whoever opened the PR.
printf 'open\tfalse\ttrue\t%s\tdeadbee\tclean\tNO-DECISION: x\n\n<!-- DELIVERS -->\n- none\n<!-- /DELIVERS -->' "$AFTER" > "$T/pr-state"
OUT="$(nb_run 2>&1)"; nb_run >/dev/null 2>&1
rc  "C13 auto-merge wins even with no baseline" 0 "$?"
has "C14 and says so"                           "$OUT" "AUTO-MERGE ARMED"

printf 'open\ttrue\tfalse\t%s\tdeadbee\tclean\tNO-DECISION: x\n\n<!-- DELIVERS -->\n- none\n<!-- /DELIVERS -->' "$AFTER" > "$T/pr-state"
nb_run >/dev/null 2>&1
rc "C15 a draft wins even with no baseline" 0 "$?"

echo
section "D. a HUMAN-STEP block this turn asked a human to run, without verified: (#714 Rule 2)"

newrepo "$T/d"

BAD_STEP='before the ask.

HUMAN-STEP
  what:     add a CNAME head.dcpgateway.com -> dcpgateway-head.netlify.app
  where:    Namecheap, dcpgateway.com, Advanced DNS
  verified:
  undo:     delete the record

after the ask.'

GOOD_STEP='before the ask.

HUMAN-STEP
  what:     add a CNAME head.dcpgateway.com -> dcpgateway-head.netlify.app
  where:    Namecheap, dcpgateway.com, Advanced DNS
  verified: dig'"'"'d dcpgateway-head.netlify.app, target CNAME resolves
  undo:     delete the record

after the ask.'

{ user_turn "set up the netlify subdomain"; asst_turn "$BAD_STEP"; } > "$T/d1.jsonl"
D1_OUT="$(run "$T/d" "$T/d1.jsonl")"; D1_RC=$?
rc  "D1 empty verified: -> BLOCKED (2)" 2 "$D1_RC"
has "D1 names the missing field" "$D1_OUT" "verified:"
has "D1 names which step, from its what:" "$D1_OUT" "add a CNAME"

{ user_turn "set up the netlify subdomain"; asst_turn "$GOOD_STEP"; } > "$T/d2.jsonl"
D2_OUT="$(run "$T/d" "$T/d2.jsonl")"; D2_RC=$?
rc "D2 a filled verified: does not block" 0 "$D2_RC"

{ asst_turn "$BAD_STEP"; user_turn "ok now do the next thing"; asst_turn "no HUMAN-STEP here, all done."; } > "$T/d3.jsonl"  # the bad block is from a PRIOR turn -- must not block THIS turn
D3_RC=$(run "$T/d" "$T/d3.jsonl" >/dev/null 2>&1; echo $?)
rc "D3 an unverified block from a PRIOR turn does not block THIS turn" 0 "$D3_RC"

{ user_turn "set up the netlify subdomain"; tool_result; asst_turn "$BAD_STEP"; } > "$T/d4.jsonl"  # tool_result is type=user too, but not a turn boundary
D4_RC=$(run "$T/d" "$T/d4.jsonl" >/dev/null 2>&1; echo $?)
rc "D4 a tool_result in between is not mistaken for a new turn" 2 "$D4_RC"

{ user_turn "just chatting"; asst_turn "no manual steps needed here."; } > "$T/d5.jsonl"
D5_RC=$(run "$T/d" "$T/d5.jsonl" >/dev/null 2>&1; echo $?)
rc "D5 no HUMAN-STEP block at all -> exit 0" 0 "$D5_RC"

echo "-- F. a turn that defers its own remaining work"

asst_act() { jq -nc --arg n "$1" '{"type":"assistant","message":{"content":[{"type":"tool_use","name":$n,"input":{}}]}}'; }
newrepo "$T/f" >/dev/null 2>&1 || mkdir -p "$T/f"

{ user_turn "finish the three items"; asst_turn "Two are done. Say the word and I'll continue, or I'll pick them up on the next pass."; } > "$T/f1.jsonl"
F1_OUT="$(run "$T/f" "$T/f1.jsonl")"; F1_RC=$?
rc  "F1 deferring to a later turn -> BLOCKED (2)"        2 "$F1_RC"
has "F1 names the deferral"                              "$F1_OUT" "puts its own remaining work off"
has "F1 offers the two ways out"                         "$F1_OUT" "Do it NOW, or give it a URL"

# THE ONE THAT MATTERS: the turn DID things. An act elsewhere used to skip the
# whole check, which is how four deferrals shipped in turns that merged PRs.
{ user_turn "finish it"; asst_act Write; asst_turn "Merged. I'll pick them up on the next pass."; } > "$T/f2.jsonl"
F2_RC=$(run "$T/f" "$T/f2.jsonl" >/dev/null 2>&1; echo $?)
rc  "F2 an act elsewhere in the turn does NOT excuse the deferral" 2 "$F2_RC"

# A turn that QUOTES a deferral is discussing one, not making one. This gate
# blocked its own author for quoting the sentence it was built to catch.
{ user_turn "explain the fix"; asst_turn "The old text was **\"Say the word and I'll continue, or I'll pick them up on the next pass\"**, which slipped through."; } > "$T/f6.jsonl"
F6_RC=$(run "$T/f" "$T/f6.jsonl" >/dev/null 2>&1; echo $?)
rc  "F6 quoting a deferral is not making one"            0 "$F6_RC"

{ user_turn "explain"; printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"text","text":"Here is what it caught:\n\n```\nI will pick them up on the next pass\n```\n\nThat is the shape."}]}}'; } > "$T/f7.jsonl"
F7_RC=$(run "$T/f" "$T/f7.jsonl" >/dev/null 2>&1; echo $?)
rc  "F7 a deferral inside a fenced block is quoted material" 0 "$F7_RC"

{ user_turn "status"; asst_turn "The next pass should check whether the cut landed."; } > "$T/f8.jsonl"
F8_RC=$(run "$T/f" "$T/f8.jsonl" >/dev/null 2>&1; echo $?)
rc  "F8 naming a next pass without promising anything is not a deferral" 0 "$F8_RC"

{ user_turn "finish it"; asst_turn "All three landed. Nothing is outstanding."; } > "$T/f3.jsonl"
F3_RC=$(run "$T/f" "$T/f3.jsonl" >/dev/null 2>&1; echo $?)
rc  "F3 a turn that defers nothing does not block"       0 "$F3_RC"

# Saying the number is not enough -- cited_already reads NON-assistant lines, so
# the artifact must actually have been created in this transcript.
url_result() { jq -nc --arg u "$1" '{"type":"user","message":{"content":[{"type":"tool_result","content":[]}]},"toolUseResult":{"stdout":$u}}'; }

{ user_turn "finish it"; asst_turn "I will file the rest as hf7y/realisateur#1120 rather than leave them."; } > "$T/f4.jsonl"
F4_RC=$(run "$T/f" "$T/f4.jsonl" >/dev/null 2>&1; echo $?)
rc  "F4 typing an issue number, having filed nothing, is still a deferral" 2 "$F4_RC"

{ user_turn "finish it"; url_result "https://github.com/hf7y/realisateur/issues/1120"; asst_turn "I will pick the rest up under hf7y/realisateur#1120."; } > "$T/f5.jsonl"
F5_RC=$(run "$T/f" "$T/f5.jsonl" >/dev/null 2>&1; echo $?)
rc  "F5 a deferral whose issue this transcript actually created is a citation" 0 "$F5_RC"

D6DIR="$T/nojq"; mkdir -p "$D6DIR"
for c in bash cat dirname git grep sed; do ln -s "$(command -v "$c")" "$D6DIR/$c"; done
D6_RC=$(payload "$T/d" "$T/d1.jsonl" | PATH="$D6DIR" "$SCRIPT" >/dev/null 2>&1; echo $?)
rc "D6 no jq on PATH -- Rule 2 check is skipped, not an error" 0 "$D6_RC"

echo
section "E. scoped to THIS session's changes (#773; the twin's #764 fix, at Stop scope)"

JOB="$T/job"; mkdir -p "$JOB/tmp"   # SessionStart is the same script, --baseline
markb() { payload "$1" "" "$2" | CLAUDE_JOB_DIR="$JOB" "$SCRIPT" --baseline >/dev/null 2>&1; printf '%s' "$?"; }
runb()  { payload "$1" "${3:-}" "$2" | CLAUDE_JOB_DIR="$JOB" "$SCRIPT" 2>&1; }
rcb()   { payload "$1" "${3:-}" "$2" | CLAUDE_JOB_DIR="$JOB" "$SCRIPT" >/dev/null 2>&1; printf '%s' "$?"; }

newrepo "$T/e-own"
RC="$(markb "$T/e-own" sess-a)"
rc "E0 --baseline exits 0" 0 "$RC"
echo mine > "$T/e-own/mine.txt"
E1="$(runb "$T/e-own" sess-a)"; E1_RC="$(rcb "$T/e-own" sess-a)"
rc  "E1 own change after the baseline -> BLOCKED (2)" 2 "$E1_RC"
has "E1 names it as YOURS" "$E1" "YOURS"
has "E1 offers committing it as the user's" "$E1" "--author="
has "E1 names the file"    "$E1" "mine.txt"

newrepo "$T/e-foreign"
echo theirs > "$T/e-foreign/vmhost.sh"
echo theirs > "$T/e-foreign/repose.sh"
markb "$T/e-foreign" sess-b >/dev/null
E2="$(runb "$T/e-foreign" sess-b)"; E2_RC="$(rcb "$T/e-foreign" sess-b)"
rc    "E2 pre-existing foreign dirt alone -> does NOT block (0)" 0 "$E2_RC"
has   "E2 reports it as context"         "$E2" "NOT YOURS"
has   "E2 names the foreign file"        "$E2" "vmhost.sh"
hasnt "E2 does not accuse"               "$E2" "BLOCKED"
hasnt "E2 never tells it to revert them" "$E2" "git restore"
hasnt "E2 never tells it to commit them" "$E2" "git commit"

newrepo "$T/e-both"
echo theirs > "$T/e-both/theirs.txt"
markb "$T/e-both" sess-c >/dev/null
echo mine > "$T/e-both/mine.txt"
E3="$(runb "$T/e-both" sess-c)"; E3_RC="$(rcb "$T/e-both" sess-c)"
rc  "E3 own + foreign -> BLOCKED (2)" 2 "$E3_RC"
has "E3 counts ONLY the session's own change" "$E3" "leaving 1 uncommitted change(s) of your own"
E3_YOURS="$(printf '%s\n' "$E3" | sed -n '/^YOURS/,/^$/p')"
has   "E3 YOURS lists the session's file"       "$E3_YOURS" "mine.txt"
hasnt "E3 YOURS does not list the foreign file" "$E3_YOURS" "theirs.txt"
has   "E3 the foreign file is context"          "$E3" "NOT YOURS"
has   "E3 says to leave the foreign work alone" "$E3" "Leave these exactly as they are"

newrepo "$T/e-nobase"
echo whoever > "$T/e-nobase/x.txt"
E4="$(runb "$T/e-nobase" sess-d)"; E4_RC="$(rcb "$T/e-nobase" sess-d)"
rc    "E4 no baseline -> warns, does not block (0)" 0 "$E4_RC"
has   "E4 names the ambiguity" "$E4" "UNATTRIBUTED"
hasnt "E4 does not accuse"     "$E4" "YOURS -- new since"

newrepo "$T/e-resume"  # Stop fires EVERY turn and SessionStart re-fires on resume/compact: a second mark mid-session would relabel the session's own work as pre-existing
markb "$T/e-resume" sess-e >/dev/null
echo mine > "$T/e-resume/mine.txt"
markb "$T/e-resume" sess-e >/dev/null
E5_RC="$(rcb "$T/e-resume" sess-e)"
rc "E5 a re-fired SessionStart does not re-baseline mid-session" 2 "$E5_RC"

newrepo "$T/e-stale"
markb "$T/e-stale" sess-f >/dev/null
echo whoever > "$T/e-stale/x.txt"
touch -d '2 days ago' "$JOB/tmp/stop-residue-baselines/sess-f"
E6_RC="$(rcb "$T/e-stale" sess-f)"
rc "E6 a baseline older than the max age is treated as no baseline" 0 "$E6_RC"

RC="$(markb "$T/dirty" sess-g)"
rc "E7 --baseline on a dirty tree still exits 0" 0 "$RC"
RC="$(markb "$T" sess-h)"
rc "E8 --baseline outside a repo still exits 0" 0 "$RC"

section "M. an issue nothing dispatches to (#1141)"

asst_cmd() { jq -nc --arg c "$1" '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":$c}}]}}'; }
runms() { payload "$1" "$2" | STUB_ISSUE="$3" PATH="$T/bin:$PATH" "$SCRIPT" 2>&1; }
rcms()  { payload "$1" "$2" | STUB_ISSUE="$3" PATH="$T/bin:$PATH" "$SCRIPT" >/dev/null 2>&1; printf '%s' "$?"; }

newrepo "$T/m"
ISSUE_URL="https://github.com/hf7y/realisateur/issues/1141"
{ user_turn "file it"; asst_cmd "gh issue create -R hf7y/realisateur --title x"; url_result "$ISSUE_URL"
  asst_turn "Filed it."; } > "$T/m1.jsonl"

OUT="$(runms "$T/m" "$T/m1.jsonl" "$(printf 'open\t')")"
has "M1 an open issue this turn filed with no milestone blocks" "$OUT" "OPEN and in no milestone"
rc  "M2 and exits 2" 2 "$(rcms "$T/m" "$T/m1.jsonl" "$(printf 'open\t')")"
has "M3 and it names the issue, not just the rule" "$OUT" "$ISSUE_URL"

rc  "M4 the same issue in a milestone does not block" 0 \
    "$(rcms "$T/m" "$T/m1.jsonl" "$(printf 'open\tEvery witness fails loudly')")"

rc  "M5 a closed issue with no milestone does not block" 0 \
    "$(rcms "$T/m" "$T/m1.jsonl" "$(printf 'closed\t')")"

{ user_turn "what does it say"; asst_cmd "gh issue view 1141 --json body"; url_result "$ISSUE_URL"
  asst_turn "It says nothing new."; } > "$T/m2.jsonl"
rc  "M6 a turn that only READ an issue does not block" 0 \
    "$(rcms "$T/m" "$T/m2.jsonl" "$(printf 'open\t')")"

OUT="$(payload "$T/m" "$T/m1.jsonl" | STUB_ISSUE="" PATH="$T/bin:$PATH" "$SCRIPT" 2>&1)"
has "M7 an unreadable issue says BLIND rather than passing quietly" "$OUT" "BLIND"
rc  "M8 and BLIND alone does not block the turn" 0 \
    "$(payload "$T/m" "$T/m1.jsonl" | STUB_ISSUE="" PATH="$T/bin:$PATH" "$SCRIPT" >/dev/null 2>&1; printf '%s' "$?")"

summary
[ "$fail" -eq 0 ] || exit 1
