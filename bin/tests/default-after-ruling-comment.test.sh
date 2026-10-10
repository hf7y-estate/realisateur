#!/usr/bin/env bash
#
# Witness test for hf7y-estate/realisateur#1553 (piece 1 of #1523, itself the
# fourth shape of #1373). Replays musc-2300#55's shape: a `DECISION:` body
# carries a `DEFAULT-AFTER` window that has already lapsed, AND a comment
# filed AFTER the issue -- but still inside the window -- already relays a
# ruling via `<!-- decision-by: -->` (#924, #1366). musc-2300#219 took the
# lapsed default anyway on 2026-10-05, ignoring the 2026-09-06 ruling comment,
# and was reverted by hand (ead34bf).
#
# `bin/etiquette.sh --apply` is the executor that acts on the lapse
# (agent/nightly.sh:199 calls it `--apply` for exactly this reason, per its
# own comment: "THE EXECUTOR DEFAULT-AFTER NEVER HAD (#1410)"). #1554 (piece
# 2 of #1523) made its lapse check also read comments: a comment filed after
# the issue, from the human or an agent relaying one (`decision-by:`,
# #924/#1366), now refuses the stale default instead of taking it.
#
# HERMETICITY: full. A fake `gh` records every `issue edit`.
set -uo pipefail
. "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib/harness.sh"
SCRIPT="$(cd "$(dirname "$0")/.." && pwd)/etiquette.sh"
[ -x "$SCRIPT" ] || { echo "FAIL: $SCRIPT not executable"; exit 1; }
harness_tmp

mkdir -p "$T/bin"
cat > "$T/bin/gh" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = "issue" ] && [ "$2" = "edit" ]; then
  printf '%s\n' "$*" >> "$EDITS"; exit 0
fi
if [ "$1" = "label" ] && [ "$2" = "list" ]; then
  cat "${LABELS_FIXTURE:-/dev/null}"; exit 0
fi
if [ "$1" = "issue" ] && [ "$2" = "list" ]; then
  cat "$FIXTURE"; exit 0
fi
echo "default-after-ruling-comment.test.sh: unstubbed gh call: $*" >&2; exit 1
EOF
chmod +x "$T/bin/gh"
export PATH="$T/bin:$PATH"

printf '# fixture grammar\nneeds-human\tB60205\tderived:decision\tOnly a human can move this.\n' > "$T/grammar.tsv"
printf 'needs-human\tOnly a human can move this.\n' > "$T/labels.txt"

run() { EDITS="$T/edits" FIXTURE="$T/f.json" LABELS_FIXTURE="$T/labels.txt" \
        ETIQUETTE_GRAMMAR="$T/grammar.tsv" bash "$SCRIPT" o/r "$@"; }

echo "default-after-ruling-comment.test.sh"

section "A. musc-2300#55's shape: a lapsed DEFAULT-AFTER, already answered in a comment"
# Filed 2026-09-01 with a 14d default (lapses 2026-09-15). Zach ruled in
# conversation on 2026-09-05 and the ruling was relayed on 2026-09-06 -- nine
# days before the window lapsed, and the ruling KEEPS the clause, which is
# the opposite of what the stale default would do.
cat > "$T/f.json" <<'EOF'
[
 {"number":1,"title":"Criterion 4 grades a sample rate nothing submitted states",
  "createdAt":"2026-09-01T18:23:28Z",
  "body":"DECISION: @hf7y -- cut the clause, or collect the project\n\nDEFAULT-AFTER 14d: cut the clause",
  "labels":[{"name":"needs-human"}],
  "comments":[
    {"author":{"login":"hf7y"},"createdAt":"2026-09-06T04:39:30Z",
     "body":"DECISION (Zach, in conversation 2026-09-05):\n\n> \"3, and warn on 44100.\"\n\nKeep criterion 4's clause. Do not collect the project.\n\n<!-- decision-by: zach 2026-09-05 -->"}
  ]}
]
EOF
: > "$T/edits"; out="$(ETIQUETTE_TODAY=2026-10-05 run --apply 2>&1)"

# EXPECTED, once #1554 lands: a ruling already lives in a comment filed
# before the window even lapsed, so the stale default must not be taken --
# the label stays, and the issue reports as answered-in-comment rather than
# defaulted.
hasnt "A1 a ruling already given in a comment blocks the stale default" \
      "$(cat "$T/edits")" "issue edit 1 --repo o/r --remove-label needs-human"
eq    "A2 so nothing is written for this issue" "$(wc -l < "$T/edits" | tr -d ' ')" "0"
hasnt "A3 ...and it is not silently counted as agreeing either" "$out" "1 issue(s) agree"

summary
