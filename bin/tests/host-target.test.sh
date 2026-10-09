#!/usr/bin/env bash
# host-target.test.sh -- witness for bin/lib/host-target.sh (#1659, piece 1
# of #1620's split: give `needs-host` a consumer).
#
# SUBJECT: bin/lib/host-target.sh

. "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib/harness.sh"
HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../.." && pwd)"
. "$HERE/bin/lib/host-target.sh"

names() { host_target_names "$1" | tr '\n' ',' ; }

section 'A. no declaration means any self-dev host may claim it'
eq "A1 empty body" "$(names '')" ''
eq "A2 prose with no host: line at all" \
   "$(names 'Something broke on dexter. See the title.')" ''

section 'B. one declared host'
eq "B1 bare line"   "$(names 'host:mandark')" 'mandark,'
eq "B2 bulleted"    "$(names '- host:mandark')" 'mandark,'
eq "B3 DELIVERS-style, with a trailing description" \
   "$(names '- host:mandark -- a timer whose enable is left for Zach')" 'mandark,'

section 'C. more than one declared host'
eq "C1 comma-separated on one line" "$(names 'host:mandark,dexter')" 'mandark,dexter,'
eq "C2 space-separated on one line" "$(names 'host:mandark dexter')" 'mandark,dexter,'
eq "C3 one per line" "$(names 'host:mandark
host:dexter')" 'mandark,dexter,'

section 'D. a hostname named only in prose, not on a declared line, does NOT match'
eq "D1 the word appears but never after host:" \
   "$(names 'This one needs host:')" ''
eq "D2 named mid-sentence, not line-initial after any bullet strip" \
   "$(names 'This is dexter-specific, see host:mandark in the thread above it, not here')" ''
eq "D3 a code fence mentioning host: is not a declaration" \
   "$(names '```
host:mandark
```')" ''

section 'E. a real issue, checked by hand (hf7y-estate/realisateur#1441)'
# #1441 is dexter-specific but says so only in its title (#1659's own
# example of the gap this convention closes) -- no host: line anywhere in
# its body, so host_target_names must read it the same as "any host".
REAL_1441='NO-DECISION: @hf7y -- routed to hf7y-estate/realisateur and owned there; nothing here needs a call

dexter went dark at 2026-10-04T11:09Z and was still dark at 22:38Z.

## Done when

Pull dexter'"'"'s plug, restore it, and `tailscale ping dexter` answers with nobody touching the machine.

<!-- DEFERRED -->
- none
<!-- /DEFERRED -->

<!-- DELIVERS -->
- none
<!-- /DELIVERS -->'
eq "E1 #1441 declares no host: line -- any self-dev host reads it as claimable, though only dexter can finish it" \
   "$(names "$REAL_1441")" ''

summary
