#!/usr/bin/env bash
# estate-watch.sh -- publish the estate's health as its CONTAINERS report it.
#
# RUNS ON dexter, where docker and /srv are. That is the opposite of its
# predecessor, monkey-watch.sh, which ran on dexter precisely so it did NOT
# depend on its subject being up. Here the subject IS this host, so a dead
# dexter publishes nothing at all -- and the page says so itself: every payload
# carries a valid_until, and a reader past it is looking at a stopped clock,
# not a healthy estate. There is no second host left to watch from.
#
# ALWAYS PUBLISHES when it runs. There is deliberately no "refusing to publish
# a bad-looking page" guard: an empty container list IS the report, and
# refusing to publish it is what hid the 2026-08-14 outage (#274).
set -uo pipefail

CLI_NAME='estate-watch'
HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
COLLECTOR="${COLLECTOR:-$HERE/bin/estate-status-collect.py}"
PAGE_SRC="${PAGE_SRC:-$HERE/share/estate-status.html}"
. "$HERE/bin/lib/estate-set.sh"
PUBLISH_REPO="${PUBLISH_REPO:-$GH_ESTATE_OWNER/$GH_ESTATE_SITE_REPO}"
PUBLISH_DIR="${PUBLISH_DIR:-estate}"
CRON_TAG='# realisateur:estate-watch:WATCH'
CRON_SPEC="${ESTATE_WATCH_CRON_SPEC:-*/20 * * * *}"

die() { printf '%s: FAIL: %s\n' "$CLI_NAME" "$*" >&2; exit 2; }

if [ "${1:-}" = "--cadence" ]; then
  # PRINTS, never installs. An agent cannot arm this host's cron; Zach types it.
  # No inline lock: the script takes cron_lock itself (bin/lib/cron-lock.sh),
  # which is the estate's one implementation of "a tick that outlives its
  # interval must leave, not pile up".
  printf "%s cd %s && git pull -q --ff-only; %s/bin/%s.sh --apply >> \$HOME/.local/state/%s.log 2>&1 %s\n" \
    "$CRON_SPEC" "$HERE" "$HERE" "$CLI_NAME" "$CLI_NAME" "$CRON_TAG"
  exit 0
fi

# ONE AT A TIME: the work is a clone, a collect and a push, and a tick that
# outlives its interval must not be joined by a second copy of itself (#629).
# shellcheck source=lib/cron-lock.sh
. "$HERE/bin/lib/cron-lock.sh"
cron_lock estate-watch

[ -x "$COLLECTOR" ] || die "collector not found at $COLLECTOR"
command -v docker >/dev/null || die "no docker on $(hostname) -- this runs on the container host, not beside it"

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
payload="$(python3 "$COLLECTOR")"
[ -n "$payload" ] || die "the collector produced nothing -- publishing nothing."
verdict="$(printf '%s' "$payload" | python3 -c 'import json,sys; print(json.load(sys.stdin)["verdict"])' 2>/dev/null)"
[ -n "$verdict" ] || die "the collector produced no verdict -- publishing nothing."

if [ "${1:-}" != "--apply" ]; then
  printf '%s\n' "$payload"
  printf '%s: %s -- NOT published (need --apply)\n' "$CLI_NAME" "$verdict"
  exit 0
fi

gh repo clone "$PUBLISH_REPO" "$WORK/site" -- -q --depth 1 2>/dev/null \
  || die "could not clone $PUBLISH_REPO -- nothing published"
mkdir -p "$WORK/site/$PUBLISH_DIR"
printf '%s\n' "$payload" > "$WORK/site/$PUBLISH_DIR/status.json"
[ -f "$PAGE_SRC" ] && cp "$PAGE_SRC" "$WORK/site/$PUBLISH_DIR/index.html"
cd "$WORK/site" || die "could not enter the site clone"
if [ -z "$(git status --porcelain "$PUBLISH_DIR")" ]; then
  printf '%s: %s -- no change to publish\n' "$CLI_NAME" "$verdict"
  exit 0
fi
git add "$PUBLISH_DIR"
git -c user.name="$CLI_NAME" -c user.email="noreply@$GH_ESTATE_SITE" \
    commit -q -m "$CLI_NAME: $verdict" || die "commit failed"
git push -q || die "push failed"
printf '%s: published %s to https://%s/%s/\n' "$CLI_NAME" "$verdict" "$GH_ESTATE_SITE" "$PUBLISH_DIR"
