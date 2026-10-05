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
[ -z "$issue" ] || sent="YOUR ISSUE IS #${issue}. It was chosen for you: read it with its comments, skip step 1 below, and do not work any other. If a comment on it names a salvage branch, start from that branch: an earlier pass ran out of turns there."
stamp="$(date -u +%Y%m%dT%H%M%SZ)"
# The same instant as an ISO-8601 Z string, because the PR list below is
# partitioned on it and `gh --jq` compares createdAt as text.
started_iso="${stamp:0:4}-${stamp:4:2}-${stamp:6:2}T${stamp:9:2}:${stamp:11:2}:${stamp:13:2}Z"
log="/srv/agent/${repo}.${stamp}.log"

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
carry="${AGENT_STATE:-/srv/agent/state}/${repo}.prs"
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

root="/srv/agent/work"
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
0. TOO LARGE FOR ONE PASS means the pass is the split: file the issue's pieces
   as native sub-issues of it, each finishable in one pass and in the same
   milestone, and report that.
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
# NO FALLBACK. `/etc/selfdev/gh-token` is `hf7y`, Zach's own login, and a pass
# that runs on it opens PRs nobody can tell from his. Zach, 2026-10-04: "fix
# identity before more unattended runs". A pass that cannot mint does not run.
minter() {
  local m
  for m in /usr/local/libexec/selfdev/selfdev-gh-app.sh \
           "$(dirname "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")")/bin/selfdev-gh-app.sh"; do
    [ -x "$m" ] && { printf '%s' "$m"; return 0; }
  done
  return 1
}

tokfile=""
minted=""
# MINTED FRESH, NOT READ FROM THE MINTER'S CACHE (#1417). `--token` returns the
# cached token until shortly before it expires, so a pass could start on a
# credential that dies before its push. An empty cache directory makes the
# minter mint, and a pass gets the token's whole life. The cache stays what it
# was built for, git's credential helper.
nocache="$(mktemp -d)"
if m="$(minter)" && tok="$(sudo -n env XDG_CACHE_HOME="$nocache" "$m" --token 2>/dev/null)" && [ -n "$tok" ]; then
  # Outside /srv/agent/work on purpose: that directory IS the container's mount,
  # so a token written there would be readable by the agent as a plain file
  # instead of only at /run/gh-token.
  mkdir -p /srv/agent/state
  minted="$(mktemp /srv/agent/state/.gh-token.XXXXXX)"
  chmod 600 "$minted"
  printf '%s\n' "$tok" > "$minted"
  tok=""
  tokfile="$minted"
  trap 'rm -f "$minted"' EXIT
  echo "=== credential: App installation token, minted for this pass ==="
else
  sudo -n rm -rf "$nocache"
  echo "=== REFUSED: the App mint was unavailable, and this pass will not run as hf7y ===" >&2
  exit 3
fi
sudo -n rm -rf "$nocache"

rc=0
sudo -n docker run --rm \
  --cpus 1.5 --memory 3g \
  -v /etc/selfdev/claude-token:/run/claude-token:ro \
  -v "${tokfile}":/run/gh-token:ro \
  -v "${root}":/work \
  -e REPO="$repo" \
  -e BRIEF="$brief" \
  -e TURNS="$turns" \
  -e STAMP="$stamp" \
  -e ISSUE="$issue" \
  -e SALVAGE="$(cat "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/salvage.sh")" \
  -e BASH_DEFAULT_TIMEOUT_MS=900000 \
  -e BASH_MAX_TIMEOUT_MS=3600000 \
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
    # THE BASH_*_TIMEOUT_MS PAIR IS WHY A LONG TEST RUN STAYS IN THE FOREGROUND.
    # At the CLI default it moves the command to the background, the agent
    # ends its turn to wait, and `claude -p` ends the pass with it (#1423).
    #
    # AND WHATEVER IS LEFT IS PUSHED, whatever the exit: turn cap, stall, crash.
    rc=0
    claude -p "$BRIEF" \
      --max-turns "$TURNS" \
      --allowedTools "Bash,Read,Write,Edit,Glob,Grep" \
      --output-format stream-json --verbose || rc=$?
    bash -c "$SALVAGE" salvage "$STAMP" "$ISSUE" || true
    exit "$rc"
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
fi
