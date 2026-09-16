#!/usr/bin/env bash
# The road for dexter's boot recovery. From a machine with a dexter login:
#   install.sh [--dry-run]
# Idempotent: re-running it re-pushes the script and unit and leaves the enabled
# state alone. Installs nothing else and starts no service it did not already.
set -euo pipefail

HOST="${DEXTER_HOST:-dexter}"
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

die() { printf 'install.sh: FATAL: %s\n' "$*" >&2; exit 1; }
log() { printf '[install] %s\n' "$*" >&2; }

ssh -o BatchMode=yes -o ConnectTimeout=10 "$HOST" true \
  || die "no ssh to $HOST -- this script runs from a machine with a dexter login"

if [[ "${1:-}" == "--dry-run" ]]; then
  log "DRY RUN -- nothing is written to $HOST"
  log "would install: /usr/local/bin/dexter-srv-autostart"
  log "would install: /etc/systemd/system/dexter-srv-autostart.service"
  log "would run:     systemctl daemon-reload && systemctl enable dexter-srv-autostart.service"
  log "would NOT start it: enabling is for the next boot, and every service it"
  log "                    would start is already running. Start it by hand to test."
  exit 0
fi
[[ $# -eq 0 ]] || die "unknown argument: $1"

log "installing the script and unit on $HOST"
scp -q "$SRC/dexter-srv-autostart" "$SRC/dexter-srv-autostart.service" "$HOST:/tmp/"
ssh "$HOST" 'sudo -n install -m 0755 /tmp/dexter-srv-autostart /usr/local/bin/dexter-srv-autostart
sudo -n install -m 0644 /tmp/dexter-srv-autostart.service /etc/systemd/system/dexter-srv-autostart.service
rm -f /tmp/dexter-srv-autostart /tmp/dexter-srv-autostart.service
sudo -n systemctl daemon-reload
sudo -n systemctl enable dexter-srv-autostart.service'

# ENABLED, NOT STARTED: this unit's whole job is the next boot, and everything
# it would start is already up. `systemctl start` here would be a no-op that
# reads as a test and is not one -- the thing under test is the address wait,
# which only a real boot exercises.
log "enabled for next boot. Verify with: ssh $HOST systemctl is-enabled dexter-srv-autostart.service"
