#!/usr/bin/env bash
# burn-tick.sh -- the hourly row: ask the quota gate, and run a night only when
# the week is under its burn-line (#1476). nightly.sh's own flock makes a tick
# that lands on a running night exit, so this needs no lock of its own.
#
# THE TOKEN IS THE PASS'S. dexter's ~/.claude/.credentials.json answers the gate
# 401; /etc/selfdev/claude-token is what every container already runs on, so the
# gate reads the same account the passes spend.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
dir="${AGENT_DIR:-/srv/agent}"
gate="${USAGE_GATE:-$here/usage-gate.sh}"
night="${NIGHTLY:-$here/nightly.sh}"

out="$(CLAUDE_CODE_OAUTH_TOKEN="$(sudo -n cat /etc/selfdev/claude-token)" bash "$gate" 2>&1)"; rc=$?
printf '%s rc=%s %s\n' "$(date -u +%FT%TZ)" "$rc" "$(printf '%s' "$out" | grep -v '^#' | tr '\n' ' ')" >> "$dir/gate.log"

case "$rc" in
  0) exec "$night" ;;
  1) exit 0 ;;
  # COULD NOT LOOK IS NOT HOLD. A gate that cannot read the window says so on
  # stderr, where cron mails it, and in the log, and the tick fails.
  *) echo "$(date -u +%FT%TZ) BLIND rc=$rc -- the gate could not read the window; nothing dispatched" | tee -a "$dir/gate.log" >&2
     exit 2 ;;
esac
