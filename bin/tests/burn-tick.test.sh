#!/usr/bin/env bash
# SUBJECT: agent/burn-tick.sh, the three verdicts of the quota gate (#1476).
# Hermetic -- `sudo` is a stub on PATH, the gate and the night are stubs named
# by USAGE_GATE and NIGHTLY, and AGENT_DIR is a fixture.
set -uo pipefail
. "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib/harness.sh"
harness_tmp; export T
REPO="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../.." && pwd)"

echo "burn-tick.test.sh"

mkdir -p "$T/bin" "$T/srv"
cat > "$T/bin/sudo" <<'STUB'
#!/usr/bin/env bash
shift                                   # drop -n
[ "$1" = cat ] && { printf 'not-a-real-token\n'; exit 0; }
exec "$@"
STUB
# The gate stub answers with GATE_RC and records the token it was handed.
cat > "$T/gate" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$CLAUDE_CODE_OAUTH_TOKEN" > "$T/token-seen"
echo "verdict=STUB util=0.080"; echo "# a human summary line"
exit "$GATE_RC"
STUB
printf '#!/usr/bin/env bash\necho ran > "$T/night-ran"\n' > "$T/night"
chmod +x "$T/bin/sudo" "$T/gate" "$T/night"

tick() {  # <gate rc>
  rm -f "$T/night-ran" "$T/srv/gate.log"
  PATH="$T/bin:$PATH" AGENT_DIR="$T/srv" USAGE_GATE="$T/gate" NIGHTLY="$T/night" GATE_RC="$1" \
    bash "$REPO/agent/burn-tick.sh" 2>&1
}

section "A. RUN (gate exits 0) starts a night"
out="$(tick 0)"; rc "the tick exits 0" 0 "$?"
eq  "the night ran" "$(cat "$T/night-ran" 2>/dev/null)" "ran"
has "the reading is logged" "$(cat "$T/srv/gate.log")" "rc=0 verdict=STUB util=0.080"
hasnt "...without the human summary line" "$(cat "$T/srv/gate.log")" "# a human"
eq  "the gate was handed the pass token" "$(cat "$T/token-seen")" "not-a-real-token"

section "B. HOLD (gate exits 1) is quiet and starts nothing"
out="$(tick 1)"; rc "the tick exits 0" 0 "$?"
eq  "it prints nothing" "$out" ""
eq  "no night ran" "$(ls "$T/night-ran" 2>/dev/null | wc -l)" "0"
has "the reading is still logged" "$(cat "$T/srv/gate.log")" "rc=1 verdict=STUB"

section "C. ERROR (gate exits 2) is BLIND, loud, and not a HOLD"
out="$(tick 2)"; rc "the tick exits 2" 2 "$?"
has "it says BLIND where cron will mail it" "$out" "BLIND rc=2"
has "...and in the log" "$(cat "$T/srv/gate.log")" "BLIND rc=2"
eq  "no night ran" "$(ls "$T/night-ran" 2>/dev/null | wc -l)" "0"

section "D. a gate that is not there is BLIND too, not a HOLD"
rm -f "$T/srv/gate.log"
out="$(PATH="$T/bin:$PATH" AGENT_DIR="$T/srv" USAGE_GATE="$T/absent" NIGHTLY="$T/night" bash "$REPO/agent/burn-tick.sh" 2>&1)"
rc  "the tick exits 2" 2 "$?"
has "it says BLIND" "$out" "BLIND rc=127"

summary
