#!/usr/bin/env bash
# defere-self-caused.test.sh -- #1408 (#140 shape, hf7y/musc-2300#140): a
# `needs-human` whose cause is the filing agent's own change earlier in the
# same run must be refused, not escalated. The incident: the agent deleted a
# rubric checklist, then filed the mismatch it had just created as a
# DECISION for Zach -- "so you just created a problem for me?"
#
# HERMETIC. Stubs `gh` on PATH; builds a throwaway git repo under $T.
#
set -uo pipefail
# shellcheck source=bin/tests/lib/harness.sh
. "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib/harness.sh"

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$ROOT/bin/defere.sh"
[ -x "$SCRIPT" ] || { echo "FAIL: $SCRIPT not executable"; exit 1; }

echo "defere-self-caused.test.sh"
harness_tmp

mkdir -p "$T/bin"
cat > "$T/bin/gh" <<'EOF'
#!/usr/bin/env bash
case "$1 $2" in
  'repo view') printf 'owner/repo\n'; exit 0 ;;
  'issue list') printf '[]\n'; exit 0 ;;
esac
[ "$1" = api ] && printf ''
exit 0
EOF
chmod +x "$T/bin/gh"

REPO="$T/repo"
mkdir -p "$REPO"
git init -q -b main "$REPO"
git -C "$REPO" config user.email t@test
git -C "$REPO" config user.name T
printf 'Midterm Proposal\n\nRubric:\n- criterion one\n- criterion two\n' > "$REPO/assignment.md"
git -C "$REPO" -c commit.gpgsign=false add -A
git -C "$REPO" -c commit.gpgsign=false commit -q -m init

run() {
  ( cd "$REPO" && PATH="$T/bin:$PATH" DEFERE_BASE=main \
      bash "$SCRIPT" "$@" --repo owner/repo --default-after '2d: block' --policy 'none yet' --dry-run ) 2>&1
}

section "A. uncommitted self-caused change: the agent's own edit is named in the filing"

git -C "$REPO" checkout -q -b feature-a
printf 'Midterm Proposal\n\nRubric: distributed separately.\n' > "$REPO/assignment.md"

A_OUT="$(run 'assignment.md promises a rubric that no longer exists' --human 'only Zach can say what replaces the rubric')"; A_RC=$?
rc  "A1 refused, not filed" 1 "$A_RC"
has "A2 names the self-changed file" "$A_OUT" "assignment.md"
has "A3 cites the #140 shape" "$A_OUT" "140"
has "A4 tells the agent to fix it, not ask" "$A_OUT" "fix what you changed"

section "B. same change, staged and committed on the branch -- still caught"

git -C "$REPO" -c commit.gpgsign=false add -A
git -C "$REPO" -c commit.gpgsign=false commit -q -m "edit assignment.md"
B_OUT="$(run 'assignment.md promises a rubric that no longer exists' --human 'only Zach can say what replaces the rubric')"; B_RC=$?
rc  "B1 still refused after commit" 1 "$B_RC"
has "B2 still names assignment.md" "$B_OUT" "assignment.md"

section "C. an unrelated question, touching nothing this run changed, still files"

git -C "$REPO" checkout -q main
git -C "$REPO" checkout -q -b feature-c
printf 'line\n' >> "$REPO/assignment.md"
git -C "$REPO" -c commit.gpgsign=false add -A
git -C "$REPO" -c commit.gpgsign=false commit -q -m "unrelated touch"

C_OUT="$(run 'rotate the deploy key' --human 'need a call')"; C_RC=$?
rc    "C1 not refused" 0 "$C_RC"
hasnt "C2 no self-caused refusal printed" "$C_OUT" "self-caused"

summary
