#!/bin/sh
# Tests the BSD/GNU `date` fallback. Turning an epoch into a clock is spelled
# `date -r EPOCH` on macOS/BSD and `date -d @EPOCH` on Linux/GNU; the scripts try
# the first and fall back to the second. The real `date` on whatever machine runs
# this can only ever exercise ONE of those paths, so this harness puts a fake
# `date` first on PATH and forces each flavour in turn:
#
#   bsd      only `-r EPOCH FMT` works (GNU's `-d @EPOCH` is rejected)
#   gnu      only `-d @EPOCH FMT` works (`-r` fails: "No such file or directory")
#   neither  both fail -- the clock has to degrade, not crash or print an error
#
# The fake answers "12:34" ("Wed 12:34" for a weekday format) and passes every
# other invocation (`date +%s` and friends) through to the real one, so the
# scripts under test run unmodified.
#
#   ./claude/test-date-fallback.sh
cd "$(dirname "$0")/.." || exit 2
SCRIPT="$PWD/claude/statusline-command.sh"
GATE="$PWD/claude/hooks/quota-gate.sh"
REAL_DATE=$(command -v date)

TMP=$(mktemp -d)
cleanup() {
  rm -rf "$TMP"
  rm -f /tmp/claude-statusline-*-statusline-test-datefb-*.txt 2>/dev/null
  rm -f /tmp/claude-turn-statusline-test-datefb-*.state 2>/dev/null
}
trap cleanup EXIT INT TERM
export HOME="$TMP/home"
mkdir -p "$HOME/.claude/quota-park"

pass=0
fail=0

assert_eq() {
  label=$1 actual=$2 expected=$3
  if [ "$actual" = "$expected" ]; then
    pass=$((pass + 1)); printf 'ok    %s\n' "$label"
  else
    fail=$((fail + 1))
    printf 'FAIL  %s\n      expected: %s\n      got:      %s\n' "$label" "$expected" "$actual"
  fi
}

# assert_has / assert_lacks "<label>" "<haystack>" "<needle>" (ANSI stripped)
assert_has() {
  plain=$(printf '%s' "$2" | sed 's/\x1b\[[0-9;]*m//g')
  case "$plain" in
    *"$3"*) pass=$((pass + 1)); printf 'ok    %s\n' "$1" ;;
    *) fail=$((fail + 1)); printf 'FAIL  %s\n      expected to find: %s\n      got:              %s\n' "$1" "$3" "$plain" ;;
  esac
}
assert_lacks() {
  plain=$(printf '%s' "$2" | sed 's/\x1b\[[0-9;]*m//g')
  case "$plain" in
    *"$3"*) fail=$((fail + 1)); printf 'FAIL  %s\n      expected NOT to find: %s\n      got:                  %s\n' "$1" "$3" "$plain" ;;
    *) pass=$((pass + 1)); printf 'ok    %s\n' "$1" ;;
  esac
}

# mkshim <mode> -> $TMP/<mode>/date
mkshim() {
  mkdir -p "$TMP/$1"
  cat > "$TMP/$1/date" <<SHIM
#!/bin/sh
mode=$1
clock() { case "\$1" in *%a*) echo "Wed 12:34" ;; *) echo "12:34" ;; esac; }
case "\$1" in
  -r) if [ "\$mode" = bsd ]; then clock "\$3"; exit 0; fi
      echo "date: \$2: No such file or directory" >&2; exit 1 ;;
  -d) case "\$2" in @*) if [ "\$mode" = gnu ]; then clock "\$3"; exit 0; fi ;; esac
      echo "date: invalid date '\$2'" >&2; exit 1 ;;
esac
exec "$REAL_DATE" "\$@"
SHIM
  chmod +x "$TMP/$1/date"
}
for m in bsd gnu neither; do mkshim "$m"; done

# --- The helper itself, lifted verbatim from the script under test -----------
helper=$(grep '^fmt_epoch()' "$SCRIPT")
if [ -z "$helper" ]; then
  echo "FAIL  could not find fmt_epoch() in $SCRIPT"; exit 1
fi
eval "$helper"
epoch=1790000000
for m in bsd gnu; do
  out=$( PATH="$TMP/$m:$PATH"; fmt_epoch "$epoch" +%H:%M 2>&1 )
  assert_eq "fmt_epoch, $m date: clock, and nothing leaked on stderr" "$out" "12:34"
  out=$( PATH="$TMP/$m:$PATH"; fmt_epoch "$epoch" '+%a %H:%M' 2>&1 )
  assert_eq "fmt_epoch, $m date: weekday format passes through" "$out" "Wed 12:34"
done
out=$( PATH="$TMP/neither:$PATH"; fmt_epoch "$epoch" +%H:%M 2>&1 )
assert_eq "fmt_epoch, neither works: empty and silent" "$out" ""
( PATH="$TMP/neither:$PATH"; fmt_epoch "$epoch" +%H:%M >/dev/null 2>&1 )
assert_eq "fmt_epoch, neither works: non-zero status" "$?" "1"

# --- The gate hook's own stamp line, likewise -------------------------------
stamp_line=$(grep '^  stamp=\$(date' "$GATE")
if [ -z "$stamp_line" ]; then
  echo "FAIL  could not find the stamp= line in $GATE"; exit 1
fi
wake=$epoch
for m in bsd gnu; do
  out=$( PATH="$TMP/$m:$PATH"; eval "$stamp_line" 2>&1; printf '%s' "$stamp" )
  assert_eq "quota-gate stamp, $m date" "$out" "12:34"
done
out=$( PATH="$TMP/neither:$PATH"; eval "$stamp_line" 2>&1; printf '[%s]' "$stamp" )
assert_eq "quota-gate stamp, neither works: empty and silent" "$out" "[]"

# --- End to end: a parked terminal's wake clock, through the real bar ---------
now=$($REAL_DATE +%s)
reset=$((now + 3 * 3600 + 23 * 60))
render() { # mode session
  PATH="$TMP/$1:$PATH" sh "$SCRIPT" 2>&1
}
for m in bsd gnu neither; do
  session="statusline-test-datefb-$m"
  printf '%s' "$((now + 45 * 60 + 12))" > "$HOME/.claude/quota-park/$session"
  out=$(printf '{"session_id":"%s","model":{"display_name":"Claude Opus"},"context_window":{},"rate_limits":{"five_hour":{"used_percentage":98,"resets_at":%s}}}' \
        "$session" "$reset" | render "$m")
  assert_has  "bar, $m date: still parked" "$out" "%💤"
  assert_lacks "bar, $m date: no date(1) error leaks into the output" "$out" "date:"
  if [ "$m" = neither ]; then
    assert_lacks "bar, neither works: no wake clock is invented" "$out" "→ 12:34"
  else
    assert_has "bar, $m date: wake clock shown" "$out" "%💤 → 12:34 /"
  fi

  session="statusline-test-datefb-week-$m"
  week_reset=$((now + 2 * 86400 + 47 * 60))
  printf '%s seven_day' "$((week_reset + 12))" > "$HOME/.claude/quota-park/$session"
  out=$(printf '{"session_id":"%s","model":{"display_name":"Claude Opus"},"context_window":{},"rate_limits":{"five_hour":{"used_percentage":40,"resets_at":%s},"seven_day":{"used_percentage":100,"resets_at":%s}}}' \
        "$session" "$reset" "$week_reset" | render "$m")
  assert_has  "weekly bar, $m date: still parked" "$out" "0%💤"
  assert_lacks "weekly bar, $m date: no date(1) error leaks into the output" "$out" "date:"
  if [ "$m" = neither ]; then
    assert_lacks "weekly bar, neither works: no wake clock is invented" "$out" "→ Wed"
  else
    assert_has "weekly bar, $m date: weekday and clock shown" "$out" "→ Wed 12:34"
  fi
done

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
