#!/usr/bin/env bash
set -uo pipefail  # stop-residue-gate.sh: Stop guard one scope up from SubagentStop (#681 SS1), same CONTRACT as hooks/subagent-closeout.sh; #681's unfiled-finding half is completion_claims() + stated_defects(), refiled as #752; SCOPED TO THIS SESSION'S OWN CHANGES (#773) as #764 scoped the twin -- same contract, different anchor, because a main session has no SubagentStart, so the baseline is taken at SessionStart and spans the session. NO BASELINE IS NOT "IT IS ALL YOURS": it warns, since losing a block beats destroying what another session is still writing

log() { printf 'stop-residue-gate: %s\n' "$*" >&2; }

payload="$(cat 2>/dev/null)" || { log "could not read hook payload from stdin"; exit 1; }

if grep -qE '"stop_hook_active"[[:space:]]*:[[:space:]]*true' <<<"$payload"; then  # herestring: pipefail+SIGPIPE misreports a piped `grep -q` (subagent-closeout.sh)
  exit 0
fi

cwd="$(sed -n 's/.*"cwd"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p;q' <<<"$payload")"
[ -n "$cwd" ] || cwd="$PWD"
[ -d "$cwd" ] || { log "cwd from payload is not a directory: $cwd"; exit 1; }

BASELINE_DIR="${CLAUDE_JOB_DIR:+$CLAUDE_JOB_DIR/tmp}"  # what was already dirty when this SESSION started. Keyed by session and read only while fresh ($CLAUDE_JOB_DIR/tmp is LONG-LIVED ACROSS SESSIONS), in its OWN dir: the twin's baselines mark a different moment and must not be read as this one
BASELINE_DIR="${BASELINE_DIR:-${TMPDIR:-/tmp}}/stop-residue-baselines"
BASELINE_MAX_AGE_MIN="${STOP_RESIDUE_BASELINE_MAX_AGE_MIN:-1440}"

json_field() { sed -n "s/.*\"$1\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p;q" <<<"$2"; }

porcelain_paths() {  # PATHS, not porcelain lines: " M f" then and "MM f" now is one foreign file
  sed -e 's/^...//' | while IFS= read -r pp; do
    case "$pp" in
      *" -> "*) printf '%s\n%s\n' "${pp%% -> *}" "${pp#* -> }" ;;
      *)        printf '%s\n' "$pp" ;;
    esac
  done
}

session_id="$(json_field session_id "$payload")"
BASELINE_FILE="${session_id:+$BASELINE_DIR/${session_id//[^A-Za-z0-9._-]/_}}"

if [ "${1:-}" = "--baseline" ]; then  # SessionStart. Records and ALWAYS exits 0 -- a hook that cannot mark the start must not stop a session from starting
  [ -n "$BASELINE_FILE" ] || { log "SessionStart payload carries no session_id -- no baseline recorded"; exit 0; }
  command -v git >/dev/null 2>&1 || { log "git not on PATH -- no baseline recorded"; exit 0; }
  mkdir -p "$BASELINE_DIR" 2>/dev/null || { log "cannot write $BASELINE_DIR -- no baseline recorded"; exit 0; }
  find "$BASELINE_DIR" -maxdepth 1 -type f -mmin +"$BASELINE_MAX_AGE_MIN" -delete 2>/dev/null
  [ -e "$BASELINE_FILE" ] && exit 0  # FIRST CAPTURE WINS: resume and compact re-fire SessionStart, and a second mark would relabel this session's own work as pre-existing
  : > "$BASELINE_FILE" || { log "cannot write $BASELINE_FILE -- no baseline recorded"; exit 0; }
  if git -C "$cwd" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    {
      printf 'HEAD\t%s\t%s\n' "$cwd" "$(git -C "$cwd" rev-parse HEAD 2>/dev/null || echo unknown)"
      git -C "$cwd" status --porcelain 2>/dev/null | porcelain_paths |
        while IFS= read -r bp; do printf 'DIRTY\t%s\t%s\n' "$cwd" "$bp"; done
    } >> "$BASELINE_FILE"
  fi
  exit 0
fi

transcript="$(sed -n 's/.*"transcript_path"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p;q' <<<"$payload")"  # not agent_transcript_path -- that's SubagentStop's field

human_step_violations() { # <this-turn's assistant text> -> one line per HUMAN-STEP block with no verified: field (#714 Rule 2)
  awk '
    /^[[:space:]]*HUMAN-STEP[[:space:]]*$/ {
      if (inblock && !sawverified) print "HUMAN-STEP block with no verified: field" (what == "" ? "" : " (" what ")")
      inblock = 1; sawverified = 0; what = ""; next
    }
    inblock && /^[[:space:]]*what:/ { line = $0; sub(/^[[:space:]]*what:[[:space:]]*/, "", line); what = line }
    inblock && /^[[:space:]]*verified:/ {
      line = $0; sub(/^[[:space:]]*verified:[[:space:]]*/, "", line); gsub(/[[:space:]]+$/, "", line)
      if (line != "") sawverified = 1
      next
    }
    inblock && /^[[:space:]]*$/ {
      if (!sawverified) print "HUMAN-STEP block with no verified: field" (what == "" ? "" : " (" what ")")
      inblock = 0
    }
    END { if (inblock && !sawverified) print "HUMAN-STEP block with no verified: field" (what == "" ? "" : " (" what ")") }
  '
}

completion_claims() { # <this turn's assistant text> -> one tagged line per act the turn CLAIMS; P=done, F=promised (#752, #681 2.1)
  awk '
    /^[[:space:]]*```/ { fence = !fence; next }                       # a fenced block is quoted material, not a claim
    fence { next }
    /^[[:space:]]*>/ { next }                                        # so is a blockquote
    { raw = $0; line = $0
      gsub(/\*?"[^"]*"\*?/, " ", line)                               # a quoted span is words being DISCUSSED -- including my own, quoted back
      s = tolower(line); gsub(/\047/, "", s); sub(/^[[:space:]]*([-*]|[0-9]+\.)[[:space:]]+/, "", s)
      if (s ~ /(^|[.!?] )i( ?ve| have)? (just |now )?(filed|committed|pushed|merged|landed|fixed|patched|deleted|removed)([ ,.]|$)/ ||
          s ~ /(^|[.!?] )i( ?ve| have)? (just |now )?(opened|created|raised)[^.!?]*(issue|pull request|pr[ .,]|#[0-9])/ ||
          s ~ /(^|[.!?] )(filed|landed) (it |this )?as #[0-9]/)
        print "P" substr(raw, 1, 140)
      else if (s ~ /(^|[^a-z])i( ?ll| will) (also |then |next |now )?(file|open|commit|push|create|fix|land|delete|remove|continue|resume|carry on|pick (it|them|this|those) up|follow up|get to (it|them)|do (it|them|that))([ ,.]|$)/ ||
               s ~ /(^|[^a-z])i( ?ll| will) [^.!?]*(next (pass|session|turn|time)|another pass|a future (pass|session|turn))/)
        print "F" substr(raw, 1, 140) }
  '
}

stated_defects() { # <this turn's assistant text> -> one line per sentence asserting a NAMED artifact is broken (#752 option 2, #681 2.1)
  awk '
    /^[[:space:]]*```/ { fence = !fence; next }                       # a fenced block is quoted material, not an assertion
    fence { next }
    /^[[:space:]]*>/ { next }                                        # so is a blockquote
    /^[[:space:]]*[-*][[:space:]]*\[[ xX]\]/ { next }                 # a checklist line reports work done, it does not assert a defect
    { line = $0; gsub(/\*?"[^"]*"\*?/, " ", line)                    # an inline quotation is someone else s words
      n = split(line, sent, /[.!?] +/)
      for (i = 1; i <= n; i++) {
        s = tolower(sent[i]); gsub(/\047/, "", s)
        if (s !~ /`[a-z0-9_./-]+\.(sh|py|tsv|conf|yml|yaml|json|jq|awk|md)(:[0-9]+)?`/) continue   # must name the artifact it accuses
        if (s ~ /(nothing|no one|nobody) (is|was|are|were)/) continue                              # "nothing is broken" is the opposite claim
        if (s ~ /(is|are|was|were|remains|remain|stays|stay) (still )?(wrong|false|stale|dead|broken|inert|a no-?op|a noop|vacuous|out of date|not true|never true)/ ||
            s ~ /never (fires|fired|runs|ran|looks|looked|checks|checked|reads|read|evaluates|evaluated|executed)/ ||
            s ~ /(does|do) not exist|no longer exists/ ||
            s ~ /nothing (reads|calls|checks|enforces|evaluates|holds|watches|bounds|flags|limits|guards|defends|catches|refuses)/ ||
            s ~ /(^|[^a-z])no (bound|check|validator|guard|test|limit|witness) (in|on|for|covers|exists)/)   # #1465: "no bound in `types.yml`" is the same finding in a noun
          { print substr(sent[i], 1, 140); next }
      }
    }
  '
}

left_unfixed() { # <this turn's assistant text> -> one line per sentence that NAMES a thing and says the turn left it unfixed (#1389)
  awk '
    /^[[:space:]]*```/ { fence = !fence; next }
    fence { next }
    /^[[:space:]]*>/ { next }
    { line = $0; gsub(/\*?"[^"]*"\*?/, " ", line)
      n = split(line, sent, /[.!?] +/)
      for (i = 1; i <= n; i++) {
        s = tolower(sent[i]); gsub(/\047/, "", s)
        if (s !~ /(have|has|had|did|was|were|is|are) not (been |yet )?(edit|edited|fix|fixed|patch|patched|correct|corrected|update|updated|touch|touched)/) continue
        if (line !~ /#[0-9]+|`[^`]+`/) continue                        # the LINE must name what was left: an issue, a PR, a file
        if (s ~ /cannot|can not|cant|refused|denied|not mine|\?$/) continue   # out of reach, or put as a question, is a different statement
        print substr(sent[i], 1, 140)
      }
    }
  '
}

incantations() { # <this turn's assistant text> -> one line per shell command handed to the human that is long or chained (#1379)
  awk '
    /^[[:space:]]*!?[[:space:]]*(ssh|sudo|docker|systemd-run|systemctl|curl|gh api) / || /^[[:space:]]*! / {
      c = $0; sub(/^[[:space:]]*/, "", c)
      if (c !~ /^! /) next                                 # only what the turn asks the HUMAN to type: the `! <command>` form
      n = gsub(/;|&&|\|\|/, "&", c)
      if (length(c) > 160 || n >= 3) print substr(c, 1, 100) "..."
    }
  '
}

ACT_RE='^(Write|Edit|NotebookEdit)$|git +commit|git +push|gh +(issue|pr) +(create|comment)|gh +api.*(issues|pulls)|notify-senechal'

# AN ISSUE NOTHING DISPATCHES TO IS RESIDUE (#1141). Why, in the message below.
TURN_SLICE='. as $all |
  ([range(0; length) | select($all[.].type == "user" and ($all[.] | has("toolUseResult") | not))] | last) as $b |
  if $b == null then [] else $all[($b + 1):] end'

milestone_gaps() { # <transcript> -> one line per OPEN issue this turn wrote to with no milestone
  local wrote urls u slug num meta ms st n=0
  wrote="$(jq -rs "$TURN_SLICE"' | [.[] | select(.type=="assistant") | (.message.content // [])[]
             | select(.type=="tool_use") | (.input.command // "")]
           | map(select(test("gh +issue +(create|comment|edit)"))) | length' "$1" 2>/dev/null)"
  # A turn that only READ issues is not touching them; M6 pins that.
  [ "${wrote:-0}" -gt 0 ] || return 0
  urls="$(jq -rs "$TURN_SLICE"' | [.[] | select(.toolUseResult != null)
             | (.toolUseResult | if type=="object" then (.stdout // .content // "") else . end | tostring)] | .[]' \
          "$1" 2>/dev/null |
          grep -oE 'https://github\.com/[A-Za-z0-9._-]+/[A-Za-z0-9._-]+/issues/[0-9]+' | sort -u)"
  [ -n "$urls" ] || return 0
  command -v gh >/dev/null 2>&1 || { printf 'BLIND: gh is not on PATH, so no milestone could be checked.\n'; return 0; }
  while IFS= read -r u; do
    [ -n "$u" ] || continue
    n=$((n + 1)); [ "$n" -gt 8 ] && { printf 'BLIND: more than 8 issues touched; only the first 8 were checked.\n'; break; }
    slug="${u#https://github.com/}"; num="${slug##*/}"; slug="${slug%/issues/*}"
    meta="$(gh api "repos/$slug/issues/$num" --jq '"\(.state)\t\(.milestone.title // "")"' 2>/dev/null)" || {
      printf 'BLIND: %s could not be read, so its milestone is unknown.\n' "$u"; continue; }
    st="${meta%%$'\t'*}"; ms="${meta#*$'\t'}"
    [ "$st" = open ] || continue
    [ -n "$ms" ] || printf '%s is OPEN and in no milestone\n' "$u"
  done <<<"$urls"
}


cited_already() { # <flagged text> <transcript> -- true when it names an artifact this transcript has already seen
  local cite seen                                    # gh issue create prints a URL, not #N, so the number is the identity
  cite="$(grep -oE '#[0-9]+|/(issues|pull)/[0-9]+' <<<"$1" | grep -oE '[0-9]+' | sed -n 1p)"
  [ -n "$cite" ] || return 1
  seen="$(grep -vF '"type":"assistant"' "$2" | grep -cE "[#/]$cite([^0-9]|\$)")"
  [ "${seen:-0}" -gt 0 ]
}

if [ -n "$transcript" ] && [ -r "$transcript" ] && command -v jq >/dev/null 2>&1; then
  turn_text="$(jq -rs '
    . as $all |
    ([range(0; length) | select($all[.].type == "user" and ($all[.] | has("toolUseResult") | not))] | last) as $b |
    if $b == null then empty else
      $all[($b + 1):][] | select(.type == "assistant") | (.message.content // [])[] | select(.type == "text") | .text
    end
  ' "$transcript" 2>/dev/null)" || turn_text=""
  hs_report="$(human_step_violations <<<"$turn_text")"
  if [ -n "$hs_report" ]; then
    {
      echo "BLOCKED: this turn asked a human to perform a manual step without confirming it can work."
      echo
      printf '%s\n' "$hs_report"
      echo
      echo "verified: is the load-bearing field -- state HOW you confirmed the target system will"
      echo "accept this, even if the honest answer is that you have not checked yet. Then check."
    } >&2
    exit 2
  fi

  turn_acts="$(jq -rs '
    . as $all |
    ([range(0; length) | select($all[.].type == "user" and ($all[.] | has("toolUseResult") | not))] | last) as $b |
    if $b == null then empty else
      $all[($b + 1):][] | select(.type == "assistant") | (.message.content // [])[] | select(.type == "tool_use") |
      if .name == "Bash" then (.input.command // "") else .name end
    end
  ' "$transcript" 2>/dev/null)" || turn_acts=""
  claim_report=""
  defect_report=""
  defer_report=""
  while IFS= read -r claim; do
    case "$claim" in F*) cited_already "$claim" "$transcript" || defer_report+="  ${claim#?}"$'\n' ;; esac
  done < <(completion_claims <<<"$turn_text")
  if ! grep -qE "$ACT_RE" <<<"$turn_acts"; then
    while IFS= read -r claim; do
      case "$claim" in
        F*) continue ;;                                                             # a deferral has its own block, with its own remedy
        P*) cited_already "$claim" "$transcript" && continue ;;                     # a done-claim naming an artifact this transcript has already seen is a citation, not a fresh claim
      esac
      claim_report+="  ${claim#?}"$'\n'
    done < <(completion_claims <<<"$turn_text")
    while IFS= read -r found; do
      cited_already "$found" "$transcript" && continue
      defect_report+="  $found"$'\n'
    done < <(stated_defects <<<"$turn_text")
  fi
  if [ -n "$claim_report" ]; then
    {
      echo "BLOCKED: this turn states an act that its own tool calls do not show."
      echo
      printf '%s' "$claim_report"
      echo
      echo "Fix it in the turn you found it; file only what you cannot reach. Do the act"
      echo "NOW -- Edit, git commit, gh issue create, gh pr create -- or cite the artifact"
      echo "that already carries it (#N, or a URL this transcript has seen). A finding"
      echo "stated in a reply and left there dies with the transcript."
    } >&2
    exit 2
  fi
  if [ -n "$defer_report" ]; then
    {
      echo "BLOCKED: this turn puts its own remaining work off to a later turn."
      echo
      printf '%s' "$defer_report"
      echo
      echo "A later turn may not come, and a promise made in a reply dies with the"
      echo "transcript. Do it NOW, or give it a URL -- an issue in the owning repo,"
      echo "with a milestone so something dispatches to it. An act elsewhere in this"
      echo "turn does not pay for the part you deferred."
    } >&2
    exit 2
  fi
  ms_report="$(milestone_gaps "$transcript")"
  ms_blind="$(grep '^BLIND:' <<<"$ms_report")"
  ms_gaps="$(grep -v '^BLIND:' <<<"$ms_report" | grep -v '^$')"
  [ -n "$ms_blind" ] && printf '%s\n' "$ms_blind" >&2
  if [ -n "$ms_gaps" ]; then
    {
      echo "BLOCKED: this turn wrote to an issue that nothing dispatches to."
      echo
      printf '%s\n' "$ms_gaps"
      echo
      echo "A project runs only while a milestone holds an open issue, so an open issue"
      echo "in no milestone is a finding nothing will ever pick up -- built-not-wired,"
      echo "in the tracker. Put it in one: gh issue edit <n> --milestone \"<title>\"."
      echo "If none fits, write that into the issue body and give it the nearest"
      echo "anyway. Leaving it unplaced and explaining why in the reply is the failure."
    } >&2
    exit 2
  fi
  spell_report="$(incantations <<<"$turn_text")"
  if [ -n "$spell_report" ]; then
    {
      echo "BLOCKED: this turn hands Zach a command no one should have to type."
      echo
      printf '%s\n' "$spell_report"
      echo
      echo "Zach, 2026-10-01: \"That incantation proves the failure. This needs to be properly"
      echo "owned by an agent that can take it on.\" A command over 160 characters, or three"
      echo "chained steps, is a missing verb: build the verb, or name the issue that builds it,"
      echo "and hand over the short form."
    } >&2
    exit 2
  fi
  unfixed_report="$(left_unfixed <<<"$turn_text")"   # NOT under the no-act guard above: an act elsewhere in the turn does not excuse this
  if [ -n "$unfixed_report" ]; then
    {
      echo "BLOCKED: this turn names something it found wrong and says it left it unfixed."
      echo
      printf '%s\n' "$unfixed_report"
      echo
      echo "Zach, 2026-10-01: \"You fix when you find. Not flag for me.\" Make the edit now"
      echo "and say what changed. If it is out of reach, say cannot and why in that"
      echo "sentence; if it is his decision, ask it as a question."
    } >&2
    exit 2
  fi
  if [ -n "$defect_report" ]; then
    {
      echo "BLOCKED: this turn states that something is broken and files nothing."
      echo
      printf '%s' "$defect_report"
      echo
      echo "Fix it in the turn you found it; file only what you cannot reach. Do the act"
      echo "NOW -- Edit, git commit, gh issue create -- or cite the artifact that already"
      echo "carries it (#N, or a URL this transcript has seen). This is the residue #681"
      echo "measured: a defect named in prose, with no owner, dies with the transcript."
    } >&2
    exit 2
  fi
fi

command -v git >/dev/null 2>&1 || { log "git not on PATH -- cannot check tree state"; exit 1; }

BASELINE=""
if [ -n "$BASELINE_FILE" ] && [ -r "$BASELINE_FILE" ] \
   && [ -z "$(find "$BASELINE_FILE" -mmin +"$BASELINE_MAX_AGE_MIN" 2>/dev/null)" ]; then
  BASELINE="$BASELINE_FILE"
fi
baseline_has_tree() { # a tree the baseline actually probed
  [ -n "$BASELINE" ] && grep -qF "$(printf 'HEAD\t%s\t' "$1")" "$BASELINE"
}
baseline_dirty() {   # the paths ALREADY dirty in <tree> when this session started
  [ -n "$BASELINE" ] || return 0
  grep -F "$(printf 'DIRTY\t%s\t' "$1")" "$BASELINE" 2>/dev/null | cut -f3-
}

discover_written_files() {  # #363: cwd misses a turn worktree-isolated elsewhere. The FILES are kept too -- in a tree no baseline saw, only a path this transcript shows being written is attributable to this session
  local transcript="$1"
  [ -n "$transcript" ] && [ -r "$transcript" ] || return 0
  command -v jq >/dev/null 2>&1 || return 0
  jq -r '
    select(.message.content != null) |
    .message.content[]? |
    select(.type == "tool_use") |
    select(.name == "Write" or .name == "Edit" or .name == "NotebookEdit") |
    .input.file_path // empty
  ' "$transcript" 2>/dev/null | sort -u
}

written_files=()
while IFS= read -r fp; do
  [ -n "$fp" ] && written_files+=("$fp")
done < <(discover_written_files "$transcript")

is_written() { # is_written <abs-path> -- did this session's transcript write it?
  local q="$1" f
  for f in ${written_files[@]+"${written_files[@]}"}; do
    [ "$f" = "$q" ] && return 0
  done
  return 1
}

# CANDIDATES, not verdicts: the loop below decides which were opened here, by
# age. Matching on command text is worse -- anything that merely CONTAINS
# "gh pr create" counts, and 3 of 3 matches were spurious on 2026-09-07.
pr_failing_checks() { # <slug> <head-sha> -> count of failing checks, or BLIND
  local slug="$1" sha="$2" n
  [ -n "$sha" ] || { echo BLIND; return; }
  # BLIND fails OPEN here on purpose: this hook decides whether an agent may
  # stop, and a check it could not read must not become a reason to block.
  n="$(gh api "repos/$slug/commits/$sha/check-runs" \
        --jq '[.check_runs[] | select(.conclusion == "failure" or .conclusion == "timed_out")] | length' \
        2>/dev/null)" || { echo BLIND; return; }
  case "$n" in ''|*[!0-9]*) echo BLIND ;; *) echo "$n" ;; esac
}

discover_prs_mentioned() {
  local transcript="$1"
  [ -n "$transcript" ] && [ -r "$transcript" ] || return 0
  grep -oE 'https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/pull/[0-9]+' "$transcript" 2>/dev/null | sort -u
}

trees=("$cwd")
for fp in ${written_files[@]+"${written_files[@]}"}; do
  d="$(dirname -- "$fp" 2>/dev/null)" || continue
  root="$(git -C "$d" rev-parse --show-toplevel 2>/dev/null)" || continue
  [ -n "$root" ] || continue
  for seen in "${trees[@]}"; do [ "$seen" = "$root" ] && continue 2; done
  trees+=("$root")
done

any_repo=0
for t in "${trees[@]}"; do
  git -C "$t" rev-parse --is-inside-work-tree >/dev/null 2>&1 && any_repo=1
done
[ "$any_repo" -eq 1 ] || exit 0

advice() {
  echo
  echo "A dirty tree at the end of a turn is a failed run, not a handoff -- an"
  echo "uncommitted change to a live script is indistinguishable from an"
  echo "abandoned one. An unpushed commit is the same failure one step later."
  echo
  echo "For the changes listed as YOURS, do ONE of these:"
  echo "  1. Commit the work you meant to keep, to a BRANCH (never main):"
  echo "       git add <specific paths>   # never 'git add -A'"
  echo "       git commit -F <msgfile>"
  echo "  2. Push it, so the branch exists on origin and not only on this host:"
  echo "       git push -u origin <branch>"
  echo "  3. Revert what you did not mean to keep:  git restore <paths>"
  echo "  4. If the user wrote the change and says to commit it as theirs, author it to them:"
  echo "       git commit --author='<their name> <their email>' -F <msgfile>"
  echo "     Take the identity from their own past commits (git log --format='%an <%ae>')."
  echo "  5. If a file is deliberately untracked, add it to .gitignore and commit that."
  echo
  echo "NONE of those apply to a path this report did not list as YOURS. Those files"
  echo "are not yours: leave them exactly as they are, say so in your reply, and stop."
  echo "If no permitted commit is open to you, name the paths and stop there too --"
  echo "destroying work to get past this hook is the one outcome it exists to prevent."
}

# The SessionStart baseline's mtime is when this session began; a PR older than
# it was not opened here. WITH NO BASELINE IT STILL BLOCKS -- a no-baseline pass
# is indistinguishable from disabling the check, and the bail-out that used to
# sit here was written by an agent this hook was blocking, in a session with no
# baseline. Safe because a re-fired Stop already exits 0 (C12).
session_started=''
if [ -n "${BASELINE_FILE:-}" ] && [ -f "$BASELINE_FILE" ]; then
  session_started="$(stat -c %Y "$BASELINE_FILE" 2>/dev/null)" || session_started=''
fi

pr_report=""
if command -v gh >/dev/null 2>&1; then
  while IFS= read -r url; do
    [ -n "$url" ] || continue
    slug="${url#https://github.com/}"; num="${slug##*/}"; slug="${slug%/pull/*}"
    meta="$(gh api "repos/$slug/pulls/$num" --jq '"\(.state)\t\(.draft)\t\(.auto_merge != null)\t\(.created_at)\t\(.head.sha)\t\(.mergeable_state // "unknown")\t\(.body // "")"' 2>/dev/null)" || {
      log "could not read $url -- not blocking on a tracker this hook cannot reach"; continue; }
    st="${meta%%$'\t'*}"; rest="${meta#*$'\t'}"; dr="${rest%%$'\t'*}"
    rest="${rest#*$'\t'}"; am="${rest%%$'\t'*}"; rest="${rest#*$'\t'}"
    created="${rest%%$'\t'*}"; rest="${rest#*$'\t'}"
    headsha="${rest%%$'\t'*}"; rest="${rest#*$'\t'}"
    mergeable_state="${rest%%$'\t'*}"; body="${rest#*$'\t'}"
    [ "$st" = open ] || continue
    # DRAFT and AUTO-MERGE first: valid stopping states whoever opened it, so
    # asking whose it is first reports already-handled work (C13-C15).
    if [ "$dr" = true ]; then
      log "note: $url is still a DRAFT -- a draft claims nothing, which is a valid way to stop."
      continue
    fi
    # ARMED IS A PREDICTION, SO CHECK IT. "It lands when its required checks
    # pass" was never verified, so an armed PR that is RED -- which will never
    # land, and which only the agent can fix -- read as handled work. That is
    # this estate's signature defect sitting inside the guard meant to catch it.
    if [ "$am" = true ]; then
      # ARMED AND CONFLICTED NEVER LANDS (#1155): a dirty PR's checks are
      # stale passes, so the failing-check read below would clear it.
      # `unknown` is a cold read, not a finding, and passes.
      if [ "$mergeable_state" = dirty ]; then
        pr_report+="  $url has AUTO-MERGE ARMED but mergeable_state=DIRTY -- a merge conflict"$'\n'
        pr_report+="    armed is not landing: auto-merge waits on checks, never on a conflict"$'\n'
        continue
      fi
      failing="$(pr_failing_checks "$slug" "$headsha")"
      if [ "$failing" = 0 ]; then
        # NOTHING FAILING IS NOT NOTHING BLOCKING (#1260): mergeable_state=blocked
        # on a repo with zero required checks means a required review, not a
        # check, is what holds it -- checks passing was never the condition.
        if [ "$mergeable_state" = blocked ]; then
          pr_report+="  $url has AUTO-MERGE ARMED but mergeable_state=BLOCKED with nothing failing"$'\n'
          pr_report+="    armed is not landing: something other than a check holds it (commonly a required review)"$'\n'
          continue
        fi
        log "note: $url has AUTO-MERGE ARMED and nothing failing -- it lands when its checks pass. Valid way to stop."
        continue
      fi
      if [ "$failing" = BLIND ]; then
        log "note: $url has AUTO-MERGE ARMED; its checks could not be read, so this hook is not blocking on them."
        continue
      fi
      pr_report+="  $url has AUTO-MERGE ARMED but $failing required check(s) FAILING"$'\n'
      pr_report+="    armed is not landing: it merges when the checks pass, and they do not"$'\n'
      continue
    fi
    # A PR predating the session is another run's work in flight, and every
    # exit offered here would damage it.
    if [ -z "$session_started" ]; then
      pr_report+="  $url is still open and not a draft"$'\n'
      pr_report+="    (no SessionStart baseline, so this hook cannot tell whether you opened it)"$'\n'
      continue
    fi
    created_epoch="$(date -d "$created" +%s 2>/dev/null)" || created_epoch=''
    if [ -z "$created_epoch" ]; then
      log "note: cannot parse $created for $url -- not blocking on a date this hook cannot read."
      continue
    fi
    if [ "$created_epoch" -lt "$session_started" ]; then
      log "note: $url predates this session ($created) -- mentioned, not opened here."
      continue
    fi
    pr_report+="  $url is still open and not a draft"$'\n'
    case "$body" in
      *DELIVERS*) : ;;
      *) pr_report+="    and carries no DELIVERS block, so nothing can check whether it landed"$'\n' ;;
    esac
  done < <(discover_prs_mentioned "$transcript")
fi
if [ -n "$pr_report" ]; then
  {
    echo "BLOCKED: this turn opened a pull request that is still open."
    echo
    printf '%s' "$pr_report"
    echo
    echo "Merging is the middle of the job, not the end of it. Three honest exits:"
    echo "  gh pr merge <n> --repo <slug> --merge --auto --delete-branch"
    echo "      arm auto-merge -- it lands when the required checks pass. PREFER THIS."
    echo "  land it now, if every required check is already green."
    echo "  convert it to a DRAFT -- a draft claims nothing, for work still in flight."
  } >&2
  exit 2
fi

own_report=""; foreign_report=""; unattr_report=""; own_total=0
[ -n "$BASELINE" ] || log "NO BASELINE for this session -- changes this hook cannot attribute are reported, not charged to you."

for t in "${trees[@]}"; do
  git -C "$t" rev-parse --is-inside-work-tree >/dev/null 2>&1 || continue
  dirty="$(git -C "$t" status --porcelain 2>/dev/null)"
  rc=$?
  if [ $rc -ne 0 ]; then
    log "git status failed in $t (rc=$rc) -- refusing to report clean on a failed probe"
    exit 1
  fi
  [ -z "$dirty" ] && continue

  had_base=0; base=""
  baseline_has_tree "$t" && { had_base=1; base="$(baseline_dirty "$t")"; }
  own=""; foreign=""; unattr=""; own_count=0
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    path="$(printf '%s\n' "$line" | porcelain_paths | head -1)"
    if [ "$had_base" -eq 1 ] && printf '%s\n' "$base" | grep -qxF "$path"; then
      foreign+="    $line"$'\n'
    elif [ "$had_base" -eq 1 ] || is_written "$t/$path"; then
      own+="    $line"$'\n'; own_count=$((own_count + 1)); own_total=$((own_total + 1))
    else
      unattr+="    $line"$'\n'
    fi
  done <<<"$dirty"

  [ -n "$own" ]     && own_report+="  tree: $t ($own_count uncommitted change(s))"$'\n'"$own"
  [ -n "$foreign" ] && foreign_report+="  tree: $t"$'\n'"$foreign"
  [ -n "$unattr" ]  && unattr_report+="  tree: $t"$'\n'"$unattr"
done

if [ "$own_total" -gt 0 ]; then
  {
    echo "BLOCKED: you are leaving $own_total uncommitted change(s) of your own."
    echo
    echo "YOURS -- new since this session started:"
    printf '%s' "$own_report"
    if [ -n "$foreign_report" ]; then
      echo
      echo "NOT YOURS -- already there when this session started. Context only:"
      printf '%s' "$foreign_report"
      echo "  Leave these exactly as they are. They are not part of this gate."
    fi
    if [ -n "$unattr_report" ]; then
      echo
      echo "UNATTRIBUTED -- no baseline for this tree, so ownership is unknown:"
      printf '%s' "$unattr_report"
      echo "  Not attributed to you and not blocking. Do not revert or commit them."
    fi
    advice
  } >&2
  exit 2
fi

if [ -n "$foreign_report" ] || [ -n "$unattr_report" ]; then
  {
    echo "stop-residue-gate: nothing in these trees is attributable to this session --"
    echo "not blocking. Reported so it is not mistaken for a clean checkout:"
    if [ -n "$foreign_report" ]; then
      echo
      echo "NOT YOURS -- already there when this session started:"
      printf '%s' "$foreign_report"
    fi
    if [ -n "$unattr_report" ]; then
      echo
      echo "UNATTRIBUTED -- no SessionStart baseline was recorded for this tree, so this"
      echo "hook cannot tell your changes from a concurrent session's:"
      printf '%s' "$unattr_report"
    fi
    echo
    echo "Leave all of the above alone: none of it is yours to commit or revert."
    echo "Mention in your reply that you stopped with it present."
  } >&2
fi

# --- price the tree BEFORE a push, not after one (man 1 tarife) ---------------
if [ -n "$cwd" ] && git -C "$cwd" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  price=""
  if command -v tarife >/dev/null 2>&1; then price="tarife"
  elif [ -x "$cwd/bin/tarife.sh" ];       then price="$cwd/bin/tarife.sh"
  fi
  if [ -n "$price" ]; then
    price_out="$(cd "$cwd" && "$price" --gate --quiet 2>&1)"; price_rc=$?
    case "$price_rc" in
      1) {
           echo "BLOCKED: this tree is over a guard that grades every PR, and you have not paid it."
           echo
           printf '%s
' "$price_out"
           echo
           echo "This is the verdict CI would give you in five minutes. Pay it now:"
           echo "the directive above names the routine and the number. Reaping your own"
           echo "added lines back out is the move it refuses."
         } >&2
         exit 2 ;;
      6) log "tarife BLIND -- the guards could not be fetched and no cache exists. This tree went UNPRICED; CI will be the first to say so." ;;
    esac
  else
    log "no tarife on PATH and no bin/tarife.sh here -- this tree went UNPRICED"
  fi
fi
exit 0
