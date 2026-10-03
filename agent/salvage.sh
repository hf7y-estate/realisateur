#!/usr/bin/env bash
# salvage.sh <stamp> [issue] -- push what a pass left unlanded. Runs INSIDE the
# container, in the checkout, after `claude` exits for any reason.
#
# The checkout is wiped by the next pass (`rm -rf /work/$REPO`) and the
# container is `--rm`, so work that was written and not pushed is gone the
# moment the pass ends -- a turn cap reached one step before the commit keeps
# nothing (#1423).
#
# Inside, not outside: the container leaves the checkout root-owned and the
# harness runs as another user, so only the container can commit to it.
set -uo pipefail

stamp="${1:?usage: salvage.sh <stamp> [issue]}"
issue="${2:-}"

# REPORT.md is untracked on purpose; the brief says so.
git add -A -- . ':!REPORT.md' 2>/dev/null
dirty=""; git diff --cached --quiet || dirty=1
# Unpushed means no remote branch holds HEAD. A branch the pass already pushed
# does, and so does an untouched clone.
ahead=""; [ -n "$(git branch -r --contains HEAD 2>/dev/null)" ] || ahead=1
[ -n "$dirty$ahead" ] || exit 0

b="$(git branch --show-current)"
case "$b" in ''|main|master) b="salvage/${issue:+${issue}-}${stamp}"; git checkout -q -b "$b" ;; esac
[ -z "$dirty" ] || git commit -q -m "salvage: the pass ended with this uncommitted${issue:+ (#${issue})}"

if git push -q -u origin "$b"; then
  echo "=== SALVAGED: pushed ${b} -- the pass ended with work it had not landed ==="
else
  echo "=== SALVAGE FAILED: could not push ${b}, and the checkout is wiped by the next pass ==="
  exit 1
fi
# The next pass is told to read the issue with its comments, so this is how it
# finds the branch.
[ -z "$issue" ] || gh issue comment "$issue" --body "NO-DECISION: a pass on this issue ended with unlanded work, and \`run-agent.sh\` pushed it to branch \`${b}\` (pass ${stamp}). Continue from that branch; do not start over.

<!-- DEFERRED -->
- none
<!-- /DEFERRED -->

<!-- DELIVERS -->
- none
<!-- /DELIVERS -->" >/dev/null 2>&1 || echo "=== salvage: pushed, but could not comment on #${issue} ==="
