#!/usr/bin/env bash
# SUBJECT: agent/run-agent.sh (the mint-and-refresh loop) and
# agent/in-container.sh (the credential helper and the `gh` wrapper that read
# what it refreshes). Hermetic -- `sudo`, `docker`, the App minter and `gh` are
# stubs, a bare repo stands in for GitHub, and the refresh interval is
# SECONDS so the suite does not wait an hour to prove the point (#1504).
#
# What a real docker run cannot show in a few seconds, this proves directly:
# the credential a long-held pass presents at the END is not the one it
# started with. `docker` here just calls agent/in-container.sh in-process
# instead of inside a container -- the file both would read is the same file.
set -uo pipefail
. "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib/harness.sh"
harness_tmp
REPO_ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../.." && pwd)"
echo "token-refresh.test.sh"

mkdir -p "$T/agent" "$T/bin" "$T/home" "$T/markers" "$T/srv"
cp "$REPO_ROOT/agent/run-agent.sh"    "$T/agent/run-agent.sh"
cp "$REPO_ROOT/agent/in-container.sh" "$T/agent/in-container.sh"
cp "$REPO_ROOT/agent/salvage.sh"      "$T/agent/salvage.sh"
chmod +x "$T/agent"/*.sh

REPONAME="tokfixture"

# --- the fixture GitHub: a bare repo, reached through the SAME URL the real
# clone and push use, rewritten by a global url.insteadOf the way a real host
# never would be -- only this test needs to not be the real GitHub.
git init -q --bare -b main "$T/origin.git"
git clone -q "$T/origin.git" "$T/seed" 2>/dev/null
( cd "$T/seed" && git -c user.name=t -c user.email=t@t commit -q --allow-empty -m seed && git push -q origin main )
export HOME="$T/home"
git config --global url."file://$T/origin.git".insteadOf "https://github.com/hf7y-estate/$REPONAME"

# --- sudo: drops -n and execs the rest, same stub nightly-image.test.sh
# already uses for this repo's other sudo -n callers.
cat > "$T/bin/sudo" <<'STUB'
#!/usr/bin/env bash
shift
exec "$@"
STUB

# --- the App minter: run-agent.sh's minter() resolves it relative to its OWN
# path (dirname(dirname($T/agent))/bin/...), which is $T/bin here. Every call
# bumps a counter and hands back a new, distinguishable "token" -- a stand-in
# for a real installation token that is only good for an hour.
cat > "$T/bin/selfdev-gh-app.sh" <<STUB
#!/usr/bin/env bash
n=\$(( \$(cat "$T/mintcount" 2>/dev/null || echo 0) + 1 ))
printf '%s' "\$n" > "$T/mintcount"
printf 'tok-%s\n' "\$n"
STUB
chmod +x "$T/bin/sudo" "$T/bin/selfdev-gh-app.sh"

# --- gh: answers every real call with "nothing found" (empty, exit 0) so
# merge-carry.sh and the reporting tail run and finish without a network.
# `__echo_token__` is this suite's own hook, not a real gh subcommand: it is
# how the claude stub below observes what the `gh` wrapper in
# in-container.sh actually read, at two different moments.
cat > "$T/bin/gh" <<'STUB'
#!/usr/bin/env bash
[ "$1" = "__echo_token__" ] && { printf '%s\n' "${GH_TOKEN:-<unset>}"; exit 0; }
exit 0
STUB
chmod +x "$T/bin/gh"

# --- claude: stands in for the agent itself. It holds the "pass" open past
# TICK_SECONDS so the refresher loop in run-agent.sh gets at least one chance
# to rewrite the mounted file while this is running, then leaves one unpushed
# commit for salvage.sh to carry -- the shape of a turn-capped pass (#1423).
cat > "$T/bin/claude" <<'STUB'
#!/usr/bin/env bash
gh __echo_token__ > "$MARKERS/gh-before"
printf 'protocol=https\nhost=github.com\n\n' | git credential fill 2>/dev/null \
  | sed -n 's/^password=//p' > "$MARKERS/cred-before"
sleep "${CLAUDE_STUB_SLEEP:-3}"
gh __echo_token__ > "$MARKERS/gh-after"
printf 'protocol=https\nhost=github.com\n\n' | git credential fill 2>/dev/null \
  | sed -n 's/^password=//p' > "$MARKERS/cred-after"
echo "work from a pass that outlived a refresh tick" > deliverable.txt
git add deliverable.txt
git commit -q -m "stub: simulated long pass"
exit 0
STUB
chmod +x "$T/bin/claude"

# --- docker: run-agent.sh's whole point of contact with containment. This
# stub reads the -v/-e flags for exactly what a real `docker run` would have
# bind-mounted and exported, then runs agent/in-container.sh DIRECTLY against
# those same paths -- same files, no container, so a write run-agent.sh makes
# to the token file on "the host" is a write this sees too, exactly as a bind
# mount would show it.
cat > "$T/bin/docker" <<STUB
#!/usr/bin/env bash
set -uo pipefail
[ "\$1" = run ] || { echo "unexpected docker invocation: \$*" >&2; exit 1; }
shift
gh_token_file=""; claude_token_file=""; workroot=""
declare -A envs
while [ \$# -gt 0 ]; do
  case "\$1" in
    -v)
      spec="\$2"; shift 2
      src="\${spec%%:*}"; rest="\${spec#*:}"; dstpart="\${rest%:ro}"; dst="\${dstpart%%:*}"
      case "\$dst" in
        /run/gh-token) gh_token_file="\$src" ;;
        /run/claude-token) claude_token_file="\$src" ;;
        /work) workroot="\$src" ;;
      esac ;;
    -e)
      kv="\$2"; shift 2
      envs["\${kv%%=*}"]="\${kv#*=}" ;;
    --cpus|--memory) shift 2 ;;
    --rm) shift ;;
    *) break ;;
  esac
done
# \$1 is now the image; the rest ("bash" "-lc" 'eval "\$INCONTAINER"') is the
# same literal command run-agent.sh always passes and this stub ignores,
# running in-container.sh itself instead.
echo "stub docker: would run image \${1:-?}"
env -i \
  HOME="\$HOME" PATH="\$PATH" \
  MARKERS="$T/markers" CLAUDE_STUB_SLEEP="\${CLAUDE_STUB_SLEEP:-3}" \
  GH_TOKEN_FILE="\$gh_token_file" CLAUDE_TOKEN_FILE="$T/claude-token.src" WORKROOT="\$workroot" \
  REPO="\${envs[REPO]}" BRIEF="\${envs[BRIEF]}" TURNS="\${envs[TURNS]}" \
  STAMP="\${envs[STAMP]}" ISSUE="\${envs[ISSUE]}" SALVAGE="\${envs[SALVAGE]}" \
  bash "$T/agent/in-container.sh"
STUB
chmod +x "$T/bin/docker"

printf 'a-claude-token\n' > "$T/claude-token.src"

run() {
  rm -f "$T/mintcount" "$T/markers"/*
  rm -rf "$T/srv"; mkdir -p "$T/srv"
  PATH="$T/bin:$PATH" HOME="$T/home" \
    AGENT_DIR="$T/srv" AGENT_TOKEN_REFRESH_SECONDS="${1:-1}" CLAUDE_STUB_SLEEP="${2:-3}" \
    AGENT_IMAGE=test-image \
    bash "$T/agent/run-agent.sh" "$REPONAME" 5 2>&1
}

section "A. the token file is refreshed while the simulated pass holds it open"
out="$(run 1 3)"; rc "run-agent.sh exits 0" 0 "$?"
has "...mints before the pass starts" "$out" "credential: App installation token, minted for this pass"
mints_seen="$(cat "$T/mintcount" 2>/dev/null || echo 0)"
case "$mints_seen" in
  [2-9]|[1-9][0-9]*) ok "...minted more than once across a 3s hold on a 1s interval (saw $mints_seen)" ;;
  *) bad "...minted more than once across a 3s hold on a 1s interval" "mintcount file says: $mints_seen" ;;
esac

section "B. the credential helper reads the file LIVE, not the value from container start"
before="$(cat "$T/markers/cred-before" 2>/dev/null)"
after="$(cat "$T/markers/cred-after" 2>/dev/null)"
[ -n "$before" ]; rc "...the helper answered before the hold" 0 "$?"
[ -n "$after" ]; rc "...and after it" 0 "$?"
if [ "$before" != "$after" ]; then ok "...and the two answers differ ($before -> $after)"
else bad "...and the two answers differ" "both were '$before' -- the helper is still reading a frozen value"; fi

section "C. the gh wrapper re-reads it too, the same two moments"
ghbefore="$(cat "$T/markers/gh-before" 2>/dev/null)"
ghafter="$(cat "$T/markers/gh-after" 2>/dev/null)"
if [ "$ghbefore" != "$ghafter" ]; then ok "...GH_TOKEN as gh saw it changed ($ghbefore -> $ghafter)"
else bad "...GH_TOKEN as gh saw it changed" "both were '$ghbefore'"; fi

section "D. the pass's work still lands: salvage pushes with whatever is current"
has "...salvage pushed a branch" "$out" "SALVAGED: pushed salvage/"
pushed_branch="$(git -C "$T/origin.git" for-each-ref --format='%(refname:short)' 'refs/heads/salvage/*')"
has "...and the branch is really on origin" "$(printf '%s' "$pushed_branch")" "salvage/"
eq "...carrying the stub's commit" \
   "$(git -C "$T/origin.git" show "$pushed_branch:deliverable.txt" 2>/dev/null)" \
   "work from a pass that outlived a refresh tick"

section "E. the refresher stops with the container -- it does not keep minting forever"
after_exit="$(cat "$T/mintcount")"
sleep 2
still="$(cat "$T/mintcount")"
eq "...mintcount is unchanged a couple seconds after run-agent.sh returned" "$still" "$after_exit"

summary
