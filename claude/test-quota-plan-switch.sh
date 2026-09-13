#!/bin/sh
# A plan change must use the account reading, even when a session's first
# status-line render mistakes cached headers for a fresh API response.
set -eu
cd "$(dirname "$0")/.."
STATE="$PWD/claude/hooks/quota-state.sh"
GATE="$PWD/claude/hooks/quota-gate.sh"
PROBE="$PWD/claude/hooks/quota-probe.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP"
mkdir -p "$HOME/.claude/hooks"
ln -s "$STATE" "$HOME/.claude/hooks/quota-state.sh"
ln -s "$PROBE" "$HOME/.claude/hooks/quota-probe.sh"
now=$(date +%s)
reset=$((now + 3600))
old_reset=$((now + 4 * 3600))
week_reset=$((now + 2 * 86400))

# Max 5x -> Max 20x: the old session's first render appears fresh and its
# reset time is farther ahead. Neither may supersede the live account probe.
"$STATE" set 11 "$reset" 39 "$week_reset" >/dev/null
"$STATE" publish 99 "$old_reset" 97 "$week_reset" 1 >/dev/null
actual=$("$STATE" read | cut -d' ' -f1,4)
[ "$actual" = '11 probe' ] || { echo "FAIL: five-hour probe replaced by $actual"; exit 1; }
actual=$("$STATE" read7 | cut -d' ' -f1,4)
[ "$actual" = '39 probe' ] || { echo "FAIL: weekly probe replaced by $actual"; exit 1; }
echo 'ok: live account reading outranks a first-render cache in both windows'

# Pro/Max plan switches: a bad cached 99% must be checked against the live
# account before the hook is allowed to suspend a request.
cat > "$TMP/fetch.sh" <<'SH'
#!/bin/sh
printf 'called\n' >> "$CLAUDE_TEST_PROBE_CALLS"
printf '%s %s %s %s\n' "$CLAUDE_TEST_LIVE_FIVE" "$CLAUDE_TEST_LIVE_RESET" 39 "$CLAUDE_TEST_WEEK_RESET"
SH
chmod +x "$TMP/fetch.sh"
jq --argjson r "$old_reset" '.five_hour.used=99 | .five_hour.resets_at=$r | .five_hour.source="session"' \
  "$HOME/.claude/quota.json" > "$TMP/quota-old.json"
mv "$TMP/quota-old.json" "$HOME/.claude/quota.json"
printf '{"session_id":"plan-switch-test"}' \
  | CLAUDE_WEEKLY_QUOTA_PROBE_COMMAND="$TMP/fetch.sh" \
    CLAUDE_TEST_PROBE_CALLS="$TMP/calls" \
    CLAUDE_TEST_LIVE_FIVE=11 CLAUDE_TEST_LIVE_RESET="$reset" \
    CLAUDE_TEST_WEEK_RESET="$week_reset" \
    CLAUDE_QUOTA_JITTER=0 CLAUDE_QUOTA_WAKE_BUFFER=0 \
    sh "$GATE" >/dev/null 2>&1 &
gate_pid=$!
tries=0
while kill -0 "$gate_pid" 2>/dev/null && [ "$tries" -lt 50 ]; do
  sleep 0.02
  tries=$((tries + 1))
done
if kill -0 "$gate_pid" 2>/dev/null; then
  pkill -TERM -P "$gate_pid" 2>/dev/null || true
  kill -TERM "$gate_pid" 2>/dev/null || true
  wait "$gate_pid" 2>/dev/null || true
  echo 'FAIL: gate suspended a session without checking the account'
  exit 1
fi
wait "$gate_pid"
[ -s "$TMP/calls" ] || { echo 'FAIL: gate did not check live quota'; exit 1; }
[ ! -e "$HOME/.claude/quota-park/plan-switch-test" ] || { echo 'FAIL: gate parked an account with quota'; exit 1; }
echo 'ok: gate checks account before parking a session'
