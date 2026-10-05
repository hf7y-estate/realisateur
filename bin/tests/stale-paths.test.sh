#!/usr/bin/env bash
set -uo pipefail  # contract test for bin/stale-paths.sh (#700). HERMETICITY: full -- a fake `gh` serves the bulk issue list AND the git tree API call from fixtures; the real bin/lib/stale-paths.jq predicate runs.
. "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib/harness.sh"
SCRIPT="$(cd "$(dirname "$0")/.." && pwd)/stale-paths.sh"
[ -x "$SCRIPT" ] || { echo "FAIL: $SCRIPT not executable"; exit 1; }
harness_tmp

mkdir -p "$T/bin"
cat > "$T/bin/gh" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = "issue" ] && [ "$2" = "list" ]; then
  [ -n "${GH_FAIL:-}" ] && { echo "$GH_FAIL" >&2; exit 1; }
  cat "${FIXTURE:-/dev/null}"; exit 0
fi
if [ "$1" = "api" ]; then
  [ -n "${TREE_FAIL:-}" ] && { echo "$TREE_FAIL" >&2; exit 1; }
  cat "${TREE_FIXTURE:-/dev/null}"; exit 0
fi
echo "unexpected gh call: $*" >&2; exit 1
EOF
chmod +x "$T/bin/gh"
export PATH="$T/bin:$PATH"

printf '{"truncated":false,"tree":[{"path":"bin","type":"tree"},{"path":"bin/carry.sh","type":"blob"},{"path":"bin/lib","type":"tree"},{"path":"bin/lib/arming.sh","type":"blob"}]}\n' > "$T/tree.json"

run() { FIXTURE="$T/f.json" TREE_FIXTURE="${TREE_FIXTURE:-$T/tree.json}" bash "$SCRIPT" "$@"; }

echo "stale-paths.test.sh"

section "A. a body citing a path the tree does not have is a finding"
cat > "$T/f.json" <<'EOF'
[{"number":1,"title":"cites a moved file","body":"See `publish_fa26.py:12` for the publisher."}]
EOF
out="$(run o/r 2>&1)"; code=$?
rc  "A1 exit 1"                                  1 "$code"
has "A2 the issue is named"                      "$out" "#1"
has "A3 the missing path is named, LINE NUMBER STRIPPED" "$out" "publish_fa26.py"
hasnt "A4 the stripped locator does not survive" "$out" "publish_fa26.py:12"

section "B. real paths only is clean"
cat > "$T/f.json" <<'EOF'
[{"number":2,"title":"cites what is there","body":"See bin/lib/arming.sh."}]
EOF
out="$(run o/r 2>&1)"; code=$?
rc    "B1 exit 0" 0 "$code"
hasnt "B2 no finding printed" "$out" "#2"

section "C. cross-repo citations are OUT OF SCOPE, not stale"
cat > "$T/f.json" <<'EOF'
[{"number":3,"title":"qualified cross-repo","body":"hf7y/other-repo/nonexistent.py and hf7y/other-repo#9 -- both elsewhere."}]
EOF
out="$(run o/r 2>&1)"; code=$?
rc    "C1 a \$owner/repo-qualified citation is not flagged: exit 0" 0 "$code"
hasnt "C2 ...and prints no finding"                                 "$out" "#3"

section "D. named IN PROSE (a roster project, no \$owner/ prefix) is also out of scope"
cat > "$T/f.json" <<'EOF'
[{"number":4,"title":"named by bare project name","body":"See senechal `alert.sh` for why -- not this tree."}]
EOF
out="$(run o/r 2>&1)"; code=$?
rc    "D1 exit 0, the prose citation is not resolved against this tree" 0 "$code"
hasnt "D2 ...and prints no finding"                                     "$out" "#4"

section "E. a \`\`\` fence quotes what output ONCE was, not a claim about now"
cat > "$T/f.json" <<'EOF'
[{"number":5,"title":"fenced historical output","body":"Ran it:\n```\nnonexistent-file.py: line 3\n```\nand it worked."}]
EOF
out="$(run o/r 2>&1)"; code=$?
rc    "E1 exit 0, fenced content is not extracted" 0 "$code"
hasnt "E2 ...and prints no finding"                "$out" "#5"

section "F. a bare filename matches a longer path by its TAIL"
cat > "$T/f.json" <<'EOF'
[{"number":6,"title":"bare name, real file lives in a subdir","body":"the fix is in carry.sh"}]
EOF
out="$(run o/r 2>&1)"; code=$?
rc    "F1 exit 0 -- carry.sh is present as bin/carry.sh's tail" 0 "$code"
hasnt "F2 ...and prints no finding"                             "$out" "#6"

section "G. a slash-joined enumeration with no extension is not a path"
cat > "$T/f.json" <<'EOF'
[{"number":7,"title":"an enumeration, not a path","body":"checked scheduler/senechal/crt for the same shape"}]
EOF
out="$(run o/r 2>&1)"; code=$?
rc    "G1 exit 0, no extension means no candidate" 0 "$code"
hasnt "G2 ...and prints no finding"                "$out" "#7"

section "H. a dotted method/attribute chain is not a path"
cat > "$T/f.json" <<'EOF'
[{"number":8,"title":"code, not a citation","body":"Runner.call raises when course.types.get is empty"}]
EOF
out="$(run o/r 2>&1)"; code=$?
rc    "H1 exit 0 -- neither .call nor .get is a KNOWN extension" 0 "$code"
hasnt "H2 ...and prints no finding"                              "$out" "#8"

section "I. a TRUNCATED tree is BLIND, never a silent clean"
printf '{"truncated":true,"tree":[]}\n' > "$T/truncated.json"
cat > "$T/f.json" <<'EOF'
[{"number":9,"title":"anything","body":"nonexistent.py"}]
EOF
out="$(TREE_FIXTURE="$T/truncated.json" run o/r 2>&1)"; code=$?
rc  "I1 exit 6" 6 "$code"
has "I2 says TRUNCATED, not clean" "$out" "TRUNCATED"

section "J. an unreadable issue list is BLIND"
out="$(GH_FAIL="HTTP 401" run o/r 2>&1)"; code=$?
rc "J1 exit 6" 6 "$code"

section "K. --json emits a stale record and a summary"
cat > "$T/f.json" <<'EOF'
[{"number":10,"title":"json mode","body":"nonexistent.py"}]
EOF
out="$(run o/r --json 2>&1)"
has "K1 a stale record"        "$out" '"kind":"stale"'
has "K2 ...carries the number" "$out" '"number":10'
has "K3 ...and the missing path" "$out" 'nonexistent.py'
has "K4 a summary record"      "$out" '"kind":"summary"'

section "L. the argument contract"
rc "L1 an unknown flag is a usage error" 2 "$(bash "$SCRIPT" --nope >/dev/null 2>&1; echo $?)"
rc "L2 no argument is a usage error"     2 "$(bash "$SCRIPT" >/dev/null 2>&1; echo $?)"

echo
summary
