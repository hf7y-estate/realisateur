#!/usr/bin/env bash
# lib/host-target.sh -- which host(s) a `needs-host` issue is waiting for.
#
# #1620 needs a host-level job to tell, from an issue alone, whether THIS
# host is the one it's waiting for. Checked 2026-10-08 across the org's open
# needs-host issues: none follow a machine-readable convention. Some name a
# host only in prose (hf7y-estate/crt#342's title says "monkey" and "potato";
# hf7y-estate/realisateur#1441 is dexter-specific but says so only in its
# title) -- a hostname written in a sentence is not a claim a job can act on.
#
# The convention: a line of the body, once any leading bullet marker is
# stripped, that itself opens with `host:` -- the same bare <kind>:<value>
# token body-grammar.sh's DELIVERS entries already use for `host:mandark`
# (hf7y-estate/senechal#1090). One or more names follow, comma- or
# space-separated; a ` -- ` (DELIVERS' own description separator) ends the
# list. No such line means any self-dev host may claim the issue.
#
# host_target_names <body> -- declared host names, one per line, in order
# of first appearance; nothing printed when the body declares none.
host_target_names() {
  local body="$1" line stripped fenced=0 rest token
  while IFS= read -r line; do
    case "$line" in '```'*) fenced=$((1 - fenced)); continue ;; esac
    [ "$fenced" -eq 1 ] && continue
    stripped="${line#"${line%%[![:space:]]*}"}"
    case "$stripped" in
      '- '*|'* '*|'+ '*) stripped="${stripped#??}" ;;
    esac
    stripped="${stripped#"${stripped%%[![:space:]]*}"}"
    case "$stripped" in
      host:*)
        rest="${stripped#host:}"
        rest="${rest%% -- *}"
        rest="${rest//,/ }"
        for token in $rest; do
          [ -n "$token" ] && printf '%s\n' "$token"
        done
        ;;
    esac
  done <<<"$body"
}
