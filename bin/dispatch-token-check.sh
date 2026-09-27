#!/usr/bin/env bash
# dispatch-token-check.sh -- what the nightly's credential can still do, asked
# on the host that holds it and answered WITHOUT ever showing it.
# RUNNER: bin/estate-status-collect.py -- every published tick, from the
# `realisateur:estate-watch:WATCH` cron row on dexter
# GUARD-TEST: bin/tests/dispatch-token-check.test.sh -- hermetic behind
#   DISPATCH_TOKEN_FILE and DISPATCH_GH; it never reads a real credential
# GATE: none -- it grades a HOST's credential, never this tree, and it is read
#   off hf7y.com/estate where an unread probe is DEGRADED rather than OK
#
# WHY THIS IS A MECHANISM AND NOT A COMMAND SOMEBODY RUNS. An agent cannot ask
# this question at all: any shell line that materialises the credential is
# refused by the harness before it runs, which is correct and is not going to
# change. So the question moved to something that already runs on dexter as a
# plain cron job -- estate-status-collect.py calls this, publishes the ANSWER,
# and nobody is handed the command.
#
# WHAT IT NEVER DOES: print, log, or pass the credential on a command line. It
# enters the environment of one `gh` call and nothing else, so it stays out of
# `ps`, `docker inspect` and this script's own output. What comes out is a
# shape, a login and two answers.
#
# THE QUESTION IT EXISTS FOR: GitHub refuses a push that creates or updates
# anything under `.github/workflows/` unless the credential carries workflow
# write. A pass that edits a workflow file commits, fails to push, and -- until
# the brief said otherwise -- threw the branch away. That cap is invisible from
# inside the container, so it is published from outside.
#
# THE SCOPE LIST IS NOT PUBLISHED. It is a map of the credential's blast radius
# and hf7y.com/estate is public. Only the derived answer goes out.
set -uo pipefail

CLI_NAME="dispatch-token-check"
usage() { echo "usage: $0 [--check|--state]" >&2; }

MODE=--check
while [ $# -gt 0 ]; do
  case "$1" in
    --check|--state) MODE="$1" ;;
    *)               usage; exit 2 ;;
  esac
  shift
done

TOKEN_FILE="${DISPATCH_TOKEN_FILE:-/etc/selfdev/gh-token}"
GH="${DISPATCH_GH:-gh}"

OUT=""
emit() { OUT="${OUT}${1}	${2}
"; }

# The credential's own prefix says which question is answerable at all.
#   ghp_/gho_     classic -- scopes come back in a response header
#   github_pat_   fine-grained -- no scope header, permissions are per-repo
#   ghs_/ghu_     App installation -- permissions are not readable by the bearer
kind_of() {
  case "$1" in
    ghp_*|gho_*)  echo classic ;;
    github_pat_*) echo fine-grained ;;
    ghs_*|ghu_*)  echo app-installation ;;
    *)            echo unknown ;;
  esac
}

finish() {  # <exit-code>
  if [ "$MODE" = --state ]; then printf '%s' "$OUT"
  else
    echo "== $CLI_NAME -- $TOKEN_FILE on $(hostname -s) =="
    printf '%s' "$OUT" | while IFS="	" read -r k v; do printf '  %-10s %s\n' "$k" "$v"; done
  fi
  exit "$1"
}

if ! { [ -r "$TOKEN_FILE" ] || sudo -n test -r "$TOKEN_FILE" 2>/dev/null; }; then
  # BLIND, never a pass: "I could not look" and "nothing is wrong" are the two
  # answers this estate most often conflates.
  emit reachable unknown
  emit why "no read of $TOKEN_FILE as $(id -un)"
  finish 6
fi

if [ -r "$TOKEN_FILE" ]; then tok="$(cat "$TOKEN_FILE")"
else tok="$(sudo -n cat "$TOKEN_FILE")"; fi
tok="${tok%%[[:space:]]*}"
if [ -z "$tok" ]; then
  emit reachable no
  emit why "$TOKEN_FILE is empty"
  finish 5
fi

kind="$(kind_of "$tok")"
hdrs="$(GH_TOKEN="$tok" GITHUB_TOKEN="$tok" "$GH" api user -i 2>&1)"; rc=$?
tok=""

status="$(printf '%s\n' "$hdrs" | sed -n 's|^HTTP/[0-9.]* \([0-9]*\).*|\1|p' | head -1)"
scopes="$(printf '%s\n' "$hdrs" | sed -n 's/^[Xx]-[Oo][Aa]uth-[Ss]copes:[[:space:]]*//p' | head -1 | tr -d '\r')"
login="$(printf '%s\n' "$hdrs" | sed -n 's/.*"login"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)"

emit kind "$kind"

if [ -z "$status" ]; then
  emit reachable unknown
  emit why "gh exited $rc without an HTTP status -- the API was not reached"
  finish 6
fi
if [ "$status" = 401 ]; then
  emit reachable no
  emit why "the API answered 401 -- the credential the nightly pushes with is dead"
  finish 5
fi

emit reachable yes
emit login "${login:-unknown}"
case "$kind" in
  classic)
    case ",${scopes// /}," in
      *,workflow,*) emit workflows yes ;;
      *)            emit workflows no
                    emit why "no workflow scope -- a pass editing .github/workflows/ cannot push it" ;;
    esac ;;
  *)
    # UNKNOWN, never a guess: a wrong `yes` sends a pass at work it will lose.
    emit workflows unknown
    emit why "a $kind credential does not report its permissions to its own bearer" ;;
esac
finish 0
