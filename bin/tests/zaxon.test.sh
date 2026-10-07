#!/usr/bin/env bash
#
# SUBJECT: bin/lib/zaxon.sh -- the ask_zach/send_zach callers of the relay.
#
# THE GAP THIS PINS (realisateur#1571). zaxon_relay_server.py refuses any
# request without the right X-Zaxon-Shared-Secret header once
# ZAXON_SHARED_SECRET is set (crt#194), but no caller sent it: turning the
# server check on today would silence every alarm that reaches Zach. So every
# curl call in this library must carry the header when the variable is set,
# and must not invent one when it is not.
#
# HERMETICITY: no network. A fake `curl` on PATH logs every invocation's
# argv and fakes just enough of the MCP handshake (a session id on the -D
# header file, a ticket_id on the final --data-binary call) for zaxon_ask
# and zaxon_send to run their full loop against it.
set -uo pipefail
. "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib/harness.sh"
REPO="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../.." && pwd)"
LIB="$REPO/bin/lib/zaxon.sh"
harness_tmp

echo "zaxon.test.sh"

[ -f "$LIB" ] && ok "bin/lib/zaxon.sh is present" \
  || { bad "bin/lib/zaxon.sh is present" "the shared relay library is gone"; summary; exit 1; }

# shellcheck source=/dev/null
. "$LIB"

mkdir -p "$T/bin"
cat > "$T/bin/curl" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$CURL_LOG"
prev=""
for a in "$@"; do
  case "$prev" in
    -D) printf 'mcp-session-id: deadbeef\r\n' > "$a" ;;
    -o) [ "$a" = "/dev/null" ] || : > "$a" ;;
  esac
  prev="$a"
done
case "$*" in
  *--data-binary*) printf '{"ticket_id": "abc123"}' ;;
esac
exit 0
STUB
chmod +x "$T/bin/curl"
export PATH="$T/bin:$PATH"
export ZAXON="http://127.0.0.1:8643/mcp"
export CURL_LOG="$T/curl.log"

section "A. zaxon_probe -- no secret configured"
: > "$CURL_LOG"
unset ZAXON_SHARED_SECRET
out="$(zaxon_probe tester)"; r=$?
rc  "A1 probe reports a reachable url" 0 "$r"
hasnt "A2 ...and sends no secret header -- none is configured" "$(cat "$CURL_LOG")" "X-Zaxon-Shared-Secret"

section "B. zaxon_probe -- secret configured"
: > "$CURL_LOG"
export ZAXON_SHARED_SECRET="s3kr1t"
out="$(zaxon_probe tester)"; r=$?
rc  "B1 probe still reports a reachable url" 0 "$r"
has "B2 ...and now sends the header with the configured value" "$(cat "$CURL_LOG")" "X-Zaxon-Shared-Secret: s3kr1t"
unset ZAXON_SHARED_SECRET

section "C. zaxon_send -- every curl call in the loop carries the header once configured"
: > "$CURL_LOG"
export ZAXON_SHARED_SECRET="s3kr1t"
out="$(zaxon_send "hello" tester)"; r=$?
rc  "C1 send succeeds against the fake relay" 0 "$r"
eq  "C2 ...and reports delivery" "$out" "sent"
calls=$(grep -c . "$CURL_LOG")
hdrs=$(grep -c "X-Zaxon-Shared-Secret: s3kr1t" "$CURL_LOG")
[ "$calls" -eq 3 ] && ok "C3 the loop made the three curl calls it always makes ($calls)" \
  || bad "C3 the loop made the three curl calls it always makes" "got $calls"
eq "C4 ...and all $calls carried the secret header, not just the first" "$hdrs" "$calls"
unset ZAXON_SHARED_SECRET

section "D. zaxon_send -- unconfigured, no call invents the header"
: > "$CURL_LOG"
unset ZAXON_SHARED_SECRET
out="$(zaxon_send "hello" tester)"; r=$?
rc "D1 send still succeeds" 0 "$r"
hasnt "D2 ...and nothing in the loop sent the header" "$(cat "$CURL_LOG")" "X-Zaxon-Shared-Secret"

section "E. zaxon_ask -- carries the header through its loop too"
: > "$CURL_LOG"
export ZAXON_SHARED_SECRET="s3kr1t"
out="$(zaxon_ask "question" tester)"; r=$?
rc "E1 ask succeeds against the fake relay" 0 "$r"
eq "E2 ...and returns the ticket id" "$out" "abc123"
calls=$(grep -c . "$CURL_LOG")
hdrs=$(grep -c "X-Zaxon-Shared-Secret: s3kr1t" "$CURL_LOG")
eq "E3 every one of the $calls calls carried the secret header" "$hdrs" "$calls"
unset ZAXON_SHARED_SECRET

summary
