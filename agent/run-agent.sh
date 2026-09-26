#!/usr/bin/env bash
# run-agent.sh <repo> [max_turns] -- one unattended pass over a repo's open
# issues, in a container. This is the whole dispatch mechanism: no ROSTER, no
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

repo="${1:?usage: run-agent.sh <repo> [max_turns]}"
turns="${2:-150}"
stamp="$(date -u +%Y%m%dT%H%M%SZ)"
log="/srv/agent/${repo}.${stamp}.log"

# ONE level, not two. The previous version mounted /srv/agent/work/<repo> at
# /work and then cloned to /work/<repo>, so the checkout landed at
# .../work/<repo>/<repo> AND claude refused /work itself: "may only list files
# in the allowed working directories for this session: '/work/crt'". Its cwd is
# the clone, so the clone must be the mount's child.
root="/srv/agent/work"
checkout="${root}/${repo}"
mkdir -p "$root"

read -r -d '' brief <<BRIEF || true
You are working unattended on hf7y-estate/${repo}. ONE issue, ONE branch, then stop.

\`gh\` is authenticated and the network works. Start by reading the queue:

    gh issue list --repo hf7y-estate/${repo} --state open \\
      --search '-label:needs-host -label:needs-human'

Those two exclusions ARE the queue, not a suggestion. \`needs-host\` means the
issue cannot be finished from here -- it needs a physical device or a live
remote host. Do not route around the filter by listing issues without it.

Then:
1. Pick the ONE you can finish AND verify from this container: network, node,
   git, gh, a shell, this checkout. Prefer small and provable over interesting.
   Spend at most a few turns choosing. Choosing is not the work.
2. Branch. Make the change. Run whatever test covers it and show its real
   output. Commit.
3. Push the branch and open a PR with \`gh pr create\`. Never push to main.
4. Write REPORT.md in the repo root before you finish, WHATEVER happened: the
   issue number, the branch, the test command and its actual output, the PR
   URL, and anything you could not do. Leave it untracked, do not commit it.
   If you achieved nothing, say so plainly and say why -- "nothing finishable
   from here, because X" is a SUCCESSFUL run of this mechanism. A silent or
   empty report is the only real failure.

State the command behind every claim you make about what the code does.
BRIEF

exec > >(tee -a "$log") 2>&1
echo "=== ${stamp} agent pass: ${repo} (turns=${turns}) ==="
echo "=== checkout: ${checkout}   log: ${log} ==="

rc=0
sudo -n docker run --rm \
  --cpus 1.5 --memory 3g \
  -v /etc/selfdev/claude-token:/run/claude-token:ro \
  -v /etc/selfdev/gh-token:/run/gh-token:ro \
  -v "${root}":/work \
  -e REPO="$repo" \
  -e BRIEF="$brief" \
  -e TURNS="$turns" \
  agent:local bash -lc '
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
  echo "=== REPORT.md (${checkout}/REPORT.md) ==="
  if [ -f "${checkout}/REPORT.md" ]; then
    cat "${checkout}/REPORT.md"
  else
    echo "NOT FOUND at that path. Anything else named REPORT.md under ${root}:"
    find "$root" -name REPORT.md 2>/dev/null || echo "  (none anywhere)"
  fi
  echo
  echo "=== branch and commits ==="
  git -c safe.directory="$checkout" -C "$checkout" branch --show-current
  git -c safe.directory="$checkout" -C "$checkout" log --oneline -5
  echo "=== uncommitted ==="
  git -c safe.directory="$checkout" -C "$checkout" status --porcelain | head
  echo "=== PRs opened by claude-agent on hf7y-estate/${repo} in the last hour ==="
  GH_TOKEN="$(sudo -n cat /etc/selfdev/gh-token)" \
    gh pr list --repo "hf7y-estate/${repo}" --limit 5 \
      --json number,title,author,createdAt \
      --jq '.[] | select(.author.login|test("claude|agent";"i")) | "#\(.number) \(.createdAt) \(.title)"' \
    || echo "  (could not list)"
fi
