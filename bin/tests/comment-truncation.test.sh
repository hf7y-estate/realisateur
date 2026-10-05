#!/usr/bin/env bash
set -uo pipefail  # a comment block cut mid-clause above code fails here, at the write, not when someone next reads it (#1099). HERMETICITY: full -- reads only tracked files and fixtures.
. "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib/harness.sh"
ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../.." && pwd)"
harness_tmp

# The predicate #1099 measured with: a comment line ending on a dangling word
# or comma, and the next line is code rather than more comment or a blank.
truncated() {
  awk -v F="$1" 'prev ~ /^[[:space:]]*#.*([,;]|[[:space:]](and|which|but|so|because|that|the|a|of|to|in|is|was|this))[[:space:]]*$/ \
                 && $0 !~ /^[[:space:]]*#/ && $0 !~ /^[[:space:]]*$/ {print F":"NR-1": "prev} {prev=$0}' "$1"
}

echo "comment-truncation.test.sh"

section "A. the detector sees the shapes #1099 repaired"
printf '%s\n' '# ls-remote against an unreadable repo prompts, and in CI the job hangs to the' 'export GIT_TERMINAL_PROMPT=0' > "$T/a.sh"
printf '%s\n' '  # is how one App key came to sit on disk under four different names, and' '  if true; then :; fi' > "$T/b.sh"
printf '%s\n' '# "no new build because main is broken". Without it both are just an absence,' 'echo' > "$T/c.sh"
for f in a b c; do
  out="$(truncated "$T/$f.sh")"
  has "A-$f $f.sh is flagged at line 1" "$out" "$T/$f.sh:1:"
done

section "B. a finished sentence, a continued block, and a blank line are not findings"
printf '%s\n' '# a whole sentence.' 'echo' > "$T/d.sh"
printf '%s\n' '# runs every suite, and' '# reports the ones that failed.' 'echo' > "$T/e.sh"
printf '%s\n' '# the header ends on a comma,' '' 'echo' > "$T/g.sh"
for f in d e g; do
  out="$(truncated "$T/$f.sh")"
  eq "B-$f $f.sh is clean" "$out" ""
done

section "C. no tracked file in this repo carries a truncated comment"
found=""
while IFS= read -r f; do
  found+="$(truncated "$ROOT/$f")"
done < <(git -C "$ROOT" ls-files '*.sh' '*.py' '*.yml')
if [ -z "$found" ]; then ok "C1 zero truncated comment blocks"; else bad "C1 truncated comment block(s) -- finish the sentence or delete the fragment" "$found"; fi

summary
