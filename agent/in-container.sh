#!/usr/bin/env bash
# in-container.sh -- the pass's entrypoint INSIDE the agent container, run by
# run-agent.sh as `bash -lc 'eval "$INCONTAINER"'`. Separate file so it can be
# exercised by a test without docker, the same way salvage.sh already is.
#
# GH_TOKEN_FILE IS READ AT CALL TIME, NOT ONCE (#1504). A pass over 60 minutes
# outlives the one-hour App installation token run-agent.sh mints before the
# container starts. The old version read the file once into $GH_TOKEN and
# baked that value into `credential.helper` and the environment, so a push
# near the end of a long pass carried the FIRST token, already dead.
# run-agent.sh now refreshes the file on disk for the life of the container;
# this script only has to stop freezing it.
set -euo pipefail

GH_TOKEN_FILE="${GH_TOKEN_FILE:-/run/gh-token}"
CLAUDE_TOKEN_FILE="${CLAUDE_TOKEN_FILE:-/run/claude-token}"
WORKROOT="${WORKROOT:-/work}"

export CLAUDE_CODE_OAUTH_TOKEN="$(cat "$CLAUDE_TOKEN_FILE")"
export GH_TOKEN_FILE
git config --global user.name  "claude-agent"
git config --global user.email "noreply@anthropic.com"
# Single-quoted end to end: `$(cat "$GH_TOKEN_FILE")` is resolved when git
# RUNS the helper (a fresh shell, inheriting GH_TOKEN_FILE from this one's
# exported environment), not when this line writes the config.
git config --global credential.helper '!f() { echo username=x-access-token; echo "password=$(cat "$GH_TOKEN_FILE")"; }; f'
# `gh` has no credential-helper hook; it takes GH_TOKEN from its OWN
# environment once per process. Shadowing the binary with a function is what
# makes it re-read the file on every call instead of carrying the token the
# process started with. `export -f` is bash-only, matching the image's shell.
gh() { GH_TOKEN="$(cat "$GH_TOKEN_FILE")" command gh "$@"; }
export -f gh

# --depth 1, NOT 50: a depth-50 pack of hf7y/crt reset mid-transfer
# ("curl 56 Recv failure") while depth 1 went 3/3 on the same bridge
# network, so the network is fine and the packfile size was the problem.
rm -rf "$WORKROOT/$REPO"
for a in 1 2 3; do
  git clone --quiet --depth 1 "https://github.com/hf7y-estate/$REPO" "$WORKROOT/$REPO" && break
  echo "clone attempt $a failed" >&2; rm -rf "$WORKROOT/$REPO"; sleep 5
done
[ -d "$WORKROOT/$REPO/.git" ] || { echo "CLONE FAILED after 3 attempts" >&2; exit 1; }

cd "$WORKROOT/$REPO"
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
