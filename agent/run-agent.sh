#!/usr/bin/env bash
# run-agent.sh <repo> [max_turns] [issue] -- one unattended pass over a repo's open
# issues in a container, or over the ONE issue named (#1382: a pass that can be
# sent, not only left to choose). This is the whole dispatch mechanism: no ROSTER, no
# pacer, no rotation index, no ledger, no flock, no unix account.
#
# THE FLAG THAT MAKES IT UNATTENDED, and it took four runs to find:
#
#   --permission-mode acceptEdits   allows EDITS, still PROMPTS on Bash
#   --allowedTools "Bash,..."       what actually runs unattended
#
# With acceptEdits, `gh`, `curl`, `git fetch`, python urllib and even `ping` all
# came back "This command requires approval" -- and an unattended run has no
# approver. The agent diagnosed that correctly, stopped probing and wrote an
# honest report; the configuration was the bug.
#
# The string below is not invented. It is hf7y/scheduler
# lib/sweep-loop-common.sh:59, the default behind 5,155 DONE runs:
#   : "${ALLOWED_TOOLS:=Bash,Read,Write,Edit,Glob,Grep}"
#
# `Bash` unqualified grants network. The containment is the CONTAINER -- --rm,
# --cpus, --memory, and no host mount but the two credential files -- not a
# tool allow-list. That replaces `run_contained`'s systemd-run scope, and with
# it the 1,024-line file that held it.
#
# Credentials are MOUNTED read-only, never env vars on a command line, so they
# stay out of `docker inspect`, `ps` and shell history.
set -euo pipefail

repo="${1:?usage: run-agent.sh <repo> [max_turns] [issue]}"
turns="${2:-150}"
issue="${3:-}"
case "$issue" in ''|*[!0-9]*) [ -z "$issue" ] || { echo "run-agent.sh: issue must be a number, got '$issue'" >&2; exit 2; } ;; esac
# SENT, NOT CHOSEN. With an issue number the pass does not read the queue to pick.
sent=""
[ -z "$issue" ] || sent="YOUR ISSUE IS #${issue}. It was chosen for you: read it with its comments, skip steps 0 and 1 below, and do not work any other. If it is too large for one pass, the pass is the split described in step 0."
# Overridable so a test can drive this script hermetically (#1382); the host
# default is unchanged.
dir="${AGENT_DIR:-/srv/agent}"
state_dir="${AGENT_STATE:-${dir}/state}"
stamp="$(date -u +%Y%m%dT%H%M%SZ)"
# The same instant as an ISO-8601 Z string, because the PR list below is
# partitioned on it and `gh --jq` compares createdAt as text.
started_iso="${stamp:0:4}-${stamp:4:2}-${stamp:6:2}T${stamp:9:2}:${stamp:11:2}:${stamp:13:2}Z"
log="${dir}/${repo}.${stamp}.log"

# WHAT THE PREVIOUS PASS OPENED, and nothing else. Zach, 2026-09-26, asked which
# of three options merges the container's PRs: "Next night's pass merges".
#
# The discriminator cannot be an identity. Measured on the six PRs open that day,
# the head commit's committer read `claude-agent` on three, `Claude` on one and
# `test` on another -- and Zach's own PRs are authored `hf7y`, the same token
# identity the pass uses, so matching on either merges a human's work by
# accident. What IS reliable is that this harness already knows which PRs it
# opened: it prints them below, partitioned on this pass's own start time. So it
# writes those numbers down and the next pass merges exactly them.
carry="${state_dir}/${repo}.prs"
mkdir -p "$(dirname "$carry")"

# ONE level, not two. The previous version mounted /srv/agent/work/<repo> at
# /work and then cloned to /work/<repo>, so the checkout landed at
# .../work/<repo>/<repo> AND claude refused /work itself: "may only list files
# in the allowed working directories for this session: '/work/crt'". Its cwd is
# the clone, so the clone must be the mount's child.
# PULLED, NOT BUILT, AND NOT `agent:local`. The registry copy is the one CI
# asserted `claude --version` against; nightly.sh pulls it before the loop and
# exports this, so a night cannot run an image older than the merged Dockerfile
# (#1341). A standalone run of this script takes whatever docker already has.
image="${AGENT_IMAGE:-ghcr.io/hf7y-estate/agent:latest}"

root="${dir}/work"
checkout="${root}/${repo}"
mkdir -p "$root"

read -r -d '' brief <<BRIEF || true
You are working unattended on hf7y-estate/${repo}. ONE issue, ONE branch, then stop.
${sent}

\`gh\` is authenticated and the network works. Start by reading the queue --
open issues in an open milestone, minus needs-host and needs-human:

    ms=\$(gh api "repos/hf7y-estate/${repo}/milestones?state=open&per_page=100" --jq '[.[].number]')
    gh issue list --repo hf7y-estate/${repo} --state open --limit 200 \\
      --search '-label:needs-host -label:needs-human' --json number,title,milestone \\
      | jq --argjson ms "\$ms" '.[] | select(.milestone and (.milestone.number as \$m | \$ms|index(\$m)))'

No milestone, or a closed one, is not in scope -- same as the two label
exclusions, not a suggestion. \`needs-host\` means the issue cannot be
finished from here -- it needs a physical device or a live remote host. Do
not route around the filter by listing issues without it.

Then:
0. FIRST COMES FIRST. If any issue in that queue carries the label \`first\`,
   the lowest-numbered of those IS tonight's issue and you do not choose. If it
   is too large for one pass, the pass is the split: file its pieces as native
   sub-issues of it, each finishable in one night, label them \`first\`, take
   the label off the parent, and report that. Otherwise:
1. Pick the ONE you can finish AND verify from this container: network, node,
   git, gh, a shell, this checkout. Prefer small and provable over interesting.
   Spend at most a few turns choosing. Choosing is not the work.
2. Branch. Make the change. Run whatever test covers it and show its real
   output. Commit.
3. Push the branch and open a PR with \`gh pr create\`. Never push to main.
   End the body with both blocks below, verbatim markers -- they are what lets a
   checker grade the claim afterwards instead of only reading it. Write
   \`- none\` in either one when it is empty, and note that DELIVERS entries are
   \`path:X\` with no space:

       <!-- DEFERRED -->
       - none
       <!-- /DEFERRED -->

       <!-- DELIVERS -->
       - path:<file> -- what takes effect outside the repo when this lands
       <!-- /DELIVERS -->
4. Write REPORT.md in the repo root before you finish, WHATEVER happened: the
   issue number, the branch, the test command and its actual output, the PR
   URL, and anything you could not do. Leave it untracked, do not commit it.
   If you achieved nothing, say so plainly and say why -- "nothing finishable
   from here, because X" is a SUCCESSFUL run of this mechanism. A silent or
   empty report is the only real failure.

If \`git push\` is refused, the branch is the only copy of the work: say so in
REPORT.md with the exact error and LEAVE IT ALONE. \`git branch -D\` after a
failed push destroys the pass -- the container is \`--rm\`, so nothing survives
it. That is what crt did on 2026-09-26 with a verified fix in hand.

You are running non-interactively. Nothing will notify you, nothing will wake
you, and there is no one to ask: a backgrounded command, a \`ScheduleWakeup\`,
or an \`until ! pgrep -f ...\` loop (which matches itself) just burns the rest
of the pass. Run every command in the foreground.

State the command behind every claim you make about what the code does.
BRIEF

exec > >(tee -a "$log") 2>&1
echo "=== ${stamp} agent pass: ${repo} (turns=${turns}) ==="
echo "=== checkout: ${checkout}   log: ${log} ==="
echo "=== image: ${image} ==="

# BEFORE the pass, not after: crt spent two nights re-reading a queue whose work
# was already sitting in three unmerged PRs of its own, and exiting without
# saying so (#1329). A pass that starts against a merged predecessor sees the
# queue as it really is. Its own script, because a step that merges is one to be
# able to run and test by itself.
"$(dirname "$0")/merge-carry.sh" "$repo" || echo "=== merge-carry.sh failed (rc=$?) -- dispatching anyway ==="

# THE CREDENTIAL IS MINTED, NOT PLACED. `/etc/selfdev/gh-token` is a classic PAT
# a human made; it carries no `workflow` scope, so a pass that edits anything under
# `.github/workflows/` commits, fails to push, and has nothing to show (#1345).
#
# The App installed on the org has carried `workflows: write` since 2026-09-03
# (#922). What stopped the estate from using it was one stale word: dexter's
# `SELFDEV_GH_OWNER` still said `hf7y` after the repos moved to `hf7y-estate`, so
# `installation_id()` resolved the pre-org-move USER installation and every token
# it minted granted 23 `hf7y/*` repos and could not read `hf7y-estate/dog` at all.
# Fixed in the host config and in `estate-set.sh`'s default (#1313).
#
# FALLS BACK, DELIBERATELY. A mint needs the network and /etc/selfdev/app.pem; if
# either is unavailable this is the difference between a pass on the old
# credential and no pass at all. The log says which one it used, because "it
# pushed" and "it pushed as whom" are different questions.
minter() {
  local m
  for m in /usr/local/libexec/selfdev/selfdev-gh-app.sh \
           "$(dirname "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")")/bin/selfdev-gh-app.sh"; do
    [ -x "$m" ] && { printf '%s' "$m"; return 0; }
  done
  return 1
}

tokfile=/etc/selfdev/gh-token
minted=""
if m="$(minter)" && tok="$(sudo -n "$m" --token 2>/dev/null)" && [ -n "$tok" ]; then
  # Outside /srv/agent/work on purpose: that directory IS the container's mount,
  # so a token written there would be readable by the agent as a plain file
  # instead of only at /run/gh-token.
  mkdir -p "$state_dir"
  minted="$(mktemp "$state_dir/.gh-token.XXXXXX")"
  chmod 600 "$minted"
  printf '%s\n' "$tok" > "$minted"
  tok=""
  tokfile="$minted"
  trap 'rm -f "$minted"' EXIT
  echo "=== credential: App installation token, minted for this pass ==="
else
  echo "=== credential: /etc/selfdev/gh-token -- the App mint was unavailable ==="
fi

rc=0
sudo -n docker run --rm \
  --cpus 1.5 --memory 3g \
  -v /etc/selfdev/claude-token:/run/claude-token:ro \
  -v "${tokfile}":/run/gh-token:ro \
  -v "${root}":/work \
  -e REPO="$repo" \
  -e BRIEF="$brief" \
  -e TURNS="$turns" \
  "$image" bash -lc '
    set -euo pipefail
    export CLAUDE_CODE_OAUTH_TOKEN="$(cat /run/claude-token)"
    export GH_TOKEN="$(cat /run/gh-token)"
    git config --global user.name  "claude-agent"
    git config --global user.email "noreply@anthropic.com"
    git config --global credential.helper "!f() { echo username=x-access-token; echo password=$GH_TOKEN; }; f"

    # --depth 1, NOT 50: a depth-50 pack of hf7y/crt reset mid-transfer
    # ("curl 56 Recv failure") while depth 1 went 3/3 on the same bridge
    # network, so the network is fine and the packfile size was the problem.
    rm -rf "/work/$REPO"
    for a in 1 2 3; do
      git clone --quiet --depth 1 "https://github.com/hf7y-estate/$REPO" "/work/$REPO" && break
      echo "clone attempt $a failed" >&2; rm -rf "/work/$REPO"; sleep 5
    done
    [ -d "/work/$REPO/.git" ] || { echo "CLONE FAILED after 3 attempts" >&2; exit 1; }

    cd "/work/$REPO"
    claude -p "$BRIEF" \
      --max-turns "$TURNS" \
      --allowedTools "Bash,Read,Write,Edit,Glob,Grep" \
      --output-format stream-json --verbose
  ' | while IFS= read -r line; do
        # One readable line per event. Raw stream-json is unreadable at volume
        # and the interesting parts are the tool calls and the text.
        printf '%s\n' "$line" | jq -r '
          if .type=="assistant" then
            (.message.content[]? |
              if .type=="text" then "  … " + (.text|split("\n")[0])
              elif .type=="tool_use" then "  > " + .name + " " + ((.input.command // .input.file_path // .input.pattern // "")|tostring|.[0:120])
              else empty end)
          elif .type=="result" then
            "=== result: " + (.subtype//"?") + "  turns=" + ((.num_turns//0)|tostring) + "  cost=$" + ((.total_cost_usd//0)|tostring)
          else empty end' 2>/dev/null || printf '%s\n' "${line:0:200}"
      done || rc=$?

echo
echo "=== $(date -u +%FT%TZ) container exited (rc=${rc}) ==="

# SAY WHICH IT IS. The previous version printed "(no REPORT.md written)" while a
# report sat one directory away, because it looked in the wrong place -- the
# harness hiding its own evidence, the third time in one session. "not found at
# <path>" is a different claim from "never looked", and both differ from "empty".
if [ ! -d "$checkout" ]; then
  echo "=== NO CHECKOUT at ${checkout} -- the clone never landed ==="
else
  g() { git -c safe.directory="$checkout" -C "$checkout" "$@"; }
  branch="$(g branch --show-current)"
  tree=clean; [ -n "$(g status --porcelain)" ] && tree=dirty
  turns_used="$(sed -n 's/^=== result: .*turns=\([0-9]*\).*/\1/p' "$log" | tail -1)"
  cost_used="$(sed -n 's/^=== result: .*cost=\$\([0-9.]*\).*/\1/p' "$log" | tail -1)"

  # THE AUTHOR IS NOT `claude-agent`. The `git config user.name` above sets
  # that as the COMMITTER, while the PR is authored `hf7y` -- the token's
  # identity -- so the old
  # `select(.author.login|test("claude|agent";"i"))` matched nobody, and every
  # green night's log claimed no PR under a header saying it listed them.
  # Recency is the pass's own artifact and survives the token changing identity
  # again; `gh --jq` takes no --arg, so the cutoff is stitched into the program.
  prs="$(GH_TOKEN="$(sudo -n cat "$tokfile")" \
    gh pr list --repo "hf7y-estate/${repo}" --limit 30 \
      --json number,createdAt,headRefName,title \
      --jq '.[] | "\(.createdAt)\t\(.number)\t\(.headRefName)\t\(.title)"' 2>/dev/null)" || prs=""
  # This pass's PRs carry the full URL; older ones are listed by number only.
  # estate-status-collect.py reads the pass's PR off the first URL in the log,
  # so a PR from a previous night printed as a URL would be read as tonight's.
  mine="$(printf '%s\n' "$prs" | awk -F'\t' -v s="$started_iso" -v r="$repo" \
    '$1!="" && $1>=s { printf "  https://github.com/hf7y-estate/%s/pull/%s  %s  %s\n", r, $2, $3, $4 }')"
  prior="$(printf '%s\n' "$prs" | awk -F'\t' -v s="$started_iso" \
    '$1!="" && $1<s { printf "  #%s  %s  %s  %s\n", $2, $1, $3, $4 }')"

  # A pass that landed nothing and said nothing is indistinguishable from one
  # that crashed (#1329) -- crt, two nights running. The harness cannot say WHY
  # the agent stopped, only what it left, so it writes that down and signs it,
  # and the collector grades a signed report on its facts rather than on its
  # absence.
  report="${checkout}/REPORT.md"
  if [ -f "$report" ]; then
    echo "=== REPORT.md (${report}) ==="
  else
    cat > "$report" <<EOF
# REPORT.md -- WRITTEN BY run-agent.sh, the agent wrote none

harness-report: rc=${rc} turns=${turns_used:-0} of ${turns} tree=${tree} branch=${branch:-none}

The agent exited without writing a report, so this says only what the harness
can see from outside the container. It is NOT a verdict on the pass: rc 0, a
clean tree and turns well under the cap is an orderly exit that landed nothing,
which the brief calls a successful run. rc non-zero or a dirty tree is not.
EOF
    echo "=== REPORT.md (${report}) -- WRITTEN BY run-agent.sh, the agent wrote none ==="
  fi
  cat "$report"

  echo
  echo "=== PRs opened by THIS pass (since ${started_iso}) ==="
  printf '%s\n' "${mine:-  (none)}"

  # The next pass merges these. Appended, so a PR held back above is not lost.
  printf '%s\n' "$prs" | awk -F'\t' -v s="$started_iso" \
    '$1!="" && $1>=s { print $2 }' >> "$carry"
  echo "=== already open on hf7y-estate/${repo} before it ==="
  printf '%s\n' "${prior:-  (none)}"
  echo "=== branch and commits ==="
  printf '%s\n' "${branch:-(detached)}"
  g log --oneline -5
  echo "=== uncommitted ==="
  g status --porcelain | head

  # SENT means BRAKED (#1382): a pass told which issue to work gets its
  # attempt recorded, so a brief that keeps failing the same issue stops
  # silently costing turns forever. Unforced passes (no issue argument) pick
  # their own work from the queue each night and are not tracked here -- the
  # brake is for a pass that was SENT, not one that chose.
  if [ -n "$issue" ]; then
    outcome=no-change
    [ -n "$mine" ] && outcome=pr-opened
    [ "$outcome" = no-change ] && [ "$tree" = dirty ] && outcome=dirty-tree
    attempts_file="${state_dir}/${repo}.${issue}.attempts.tsv"
    mkdir -p "$state_dir"
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$(date -u +%FT%TZ)" "$repo" "$issue" "${turns_used:-0}" "${cost_used:-0}" "$outcome" \
      >> "$attempts_file"
    attempt_count="$(wc -l < "$attempts_file" | tr -d ' ')"
    max_attempts="${MAX_ATTEMPTS:-3}"
    echo "=== forced pass on #${issue}: attempt ${attempt_count} of ${max_attempts}, outcome=${outcome} (${attempts_file}) ==="
    if [ "$attempt_count" -ge "$max_attempts" ]; then
      issue_json="$(GH_TOKEN="$(sudo -n cat "$tokfile")" \
        gh issue view "$issue" --repo "hf7y-estate/${repo}" --json state,labels 2>/dev/null)" || issue_json=""
      state="$(printf '%s' "$issue_json" | jq -r '.state // "UNKNOWN"' 2>/dev/null)"
      already="$(printf '%s' "$issue_json" | jq -r '[.labels[]?.name] | any(. == "needs-human")' 2>/dev/null)"
      if [ "$state" = OPEN ] && [ "$already" != true ]; then
        GH_TOKEN="$(sudo -n cat "$tokfile")" gh issue edit "$issue" --repo "hf7y-estate/${repo}" \
          --add-label needs-human 2>&1 | sed 's/^/  /'
        GH_TOKEN="$(sudo -n cat "$tokfile")" gh issue comment "$issue" --repo "hf7y-estate/${repo}" \
          --body "NO-DECISION: ${attempt_count} forced passes on this issue did not close it (brake at ${max_attempts}, \`${attempts_file}\`). Labeled \`needs-human\` rather than spending another pass." \
          2>&1 | sed 's/^/  /'
        echo "=== #${issue}: ${attempt_count} attempts without closing -- labeled needs-human ==="
      else
        echo "=== #${issue}: brake reached but state=${state} already=${already} -- nothing to do ==="
      fi
    fi
  fi
fi
