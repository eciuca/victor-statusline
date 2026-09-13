#!/bin/sh
# Park this terminal when the 5h quota is nearly gone or the weekly quota has
# 1% or less left, but only after the account's live usage endpoint confirms it.
# Both windows wake at the next probe, so a plan change releases parked work.
#
# Wired to UserPromptSubmit, PreToolUse and PostToolUse: those are the three
# points immediately before an API request. PostToolUse is the tightest (the
# tool result is already in hand), PreToolUse also avoids kicking off a long
# build right at the boundary, UserPromptSubmit covers a turn that ended in
# plain text.
#
# `rate_limits` in the hook payload and shared state can hold an old plan's
# allowance. Never block an API request based solely on that cache: force a
# probe before each park, then require its fresh result for the limiting window.
# If probing fails, let the request through. The probe's lock bounds concurrent
# requests from multiple hooks.
#
# Env knobs: CLAUDE_QUOTA_MIN_PCT (default 5),
# CLAUDE_WEEKLY_QUOTA_MIN_PCT (default 1), CLAUDE_QUOTA_MAX_SLEEP (604920),
# CLAUDE_QUOTA_PROBE_SECS (default 300; CLAUDE_WEEKLY_QUOTA_PROBE_SECS is an
# accepted alias), CLAUDE_QUOTA_GATE=0 to disable.

INPUT=$(cat)                       # always drain stdin, else the writer gets SIGPIPE

[ "${CLAUDE_QUOTA_GATE:-1}" = "0" ] && exit 0

THRESH="${CLAUDE_QUOTA_MIN_PCT:-5}"
WEEK_THRESH="${CLAUDE_WEEKLY_QUOTA_MIN_PCT:-1}"
MAXSLEEP="${CLAUDE_QUOTA_MAX_SLEEP:-604920}"
PROBE_SECS="${CLAUDE_QUOTA_PROBE_SECS:-${CLAUDE_WEEKLY_QUOTA_PROBE_SECS:-300}}"
LOG="$HOME/.claude/quota-gate.log"
PARKDIR="$HOME/.claude/quota-park"
PROBE_STAMP="${CLAUDE_QUOTA_PROBE_FILE:-$HOME/.claude/quota-probe}"
PROBE="$HOME/.claude/hooks/quota-probe.sh"

case "$PROBE_SECS" in ''|*[!0-9]*|0) PROBE_SECS=300 ;; esac

STALE="${CLAUDE_QUOTA_STALE_SECS:-900}"
JITTER="${CLAUDE_QUOTA_JITTER:-90}"
BUFFER="${CLAUDE_QUOTA_WAKE_BUFFER:-30}"
jitter=0
[ "$JITTER" -gt 0 ] 2>/dev/null && jitter=$(( $$ % JITTER ))
session=$(printf '%s' "$INPUT" | jq -r '.session_id // "unknown"' 2>/dev/null)
[ -n "$session" ] || session=unknown
verified=0

while :; do
  state=$("$HOME/.claude/hooks/quota-state.sh" read 2>/dev/null) || exit 0
  used=$(printf   '%s' "$state" | cut -d' ' -f1)
  resets=$(printf '%s' "$state" | cut -d' ' -f2)
  meas=$(printf   '%s' "$state" | cut -d' ' -f3)
  source=$(printf '%s' "$state" | cut -d' ' -f4)
  state7=$("$HOME/.claude/hooks/quota-state.sh" read7 2>/dev/null)
  used7=$(printf   '%s' "$state7" | cut -d' ' -f1)
  resets7=$(printf '%s' "$state7" | cut -d' ' -f2)
  meas7=$(printf '%s' "$state7" | cut -d' ' -f3)
  source7=$(printf '%s' "$state7" | cut -d' ' -f4)
  now=$(date +%s)

  # Preserve the existing 5h decision exactly: park only on confirmed data.
  go=0
  case "$used" in
    ''|-1|*[!0-9.]*) ;;
    *)
      case "$meas" in
        ''|*[!0-9]*|0) ;;
        *)
          if [ "$((now - meas))" -le "$STALE" ]; then
            go=$(awk -v u="$used" -v t="$THRESH" -v r="$resets" -v n="$now" \
              'BEGIN{ print ((100 - u) < t && r > n) ? 1 : 0 }')
          fi
          ;;
      esac
      ;;
  esac

  go7=0
  case "$used7" in
    ''|-1|*[!0-9.]*) ;;
    *)
      go7=$(awk -v u="$used7" -v t="$WEEK_THRESH" -v r="$resets7" -v n="$now" \
        'BEGIN{ print ((100 - u) <= t && r > n) ? 1 : 0 }')
      ;;
  esac

  [ "$go" = 1 ] || [ "$go7" = 1 ] || exit 0

  if [ "$verified" = 0 ]; then
    # A failed or concurrent probe is not proof of exhaustion. Let Claude make
    # its own request instead of parking it on uncertain data.
    "$PROBE" --force >/dev/null 2>&1 || exit 0
    verified=1
    continue
  fi
  verified=0
  # A concurrent status-line write could replace the probe before this read.
  # Require the chosen window itself to still carry the account measurement.
  if [ "$go" = 1 ]; then
    [ "$source" = probe ] && [ "$((now - meas))" -le 30 ] || exit 0
  fi
  if [ "$go7" = 1 ]; then
    [ "$source7" = probe ] && [ "$((now - meas7))" -le 30 ] || exit 0
  fi

  probe_last=$(sed -n '1p' "$PROBE_STAMP" 2>/dev/null | cut -d' ' -f1)
  case "$probe_last" in ''|*[!0-9]*) probe_last=$now ;; esac
  wake=$((probe_last + PROBE_SECS + jitter))
  if [ "$go7" = 1 ]; then
    window=seven_day
    used=$used7
    reset_wake=$((resets7 + BUFFER + jitter))
  else
    window=five_hour
    reset_wake=$((resets + BUFFER + jitter))
  fi
  [ "$reset_wake" -lt "$wake" ] && wake=$reset_wake

  secs=$((wake - now))
  [ "$secs" -le 0 ] && continue
  stamp=$(date -r "$wake" '+%H:%M' 2>/dev/null)

  if [ "$secs" -gt "$MAXSLEEP" ]; then
    printf '%s park-declined session=%s window=%s used=%s reset_in=%ss exceeds max=%ss\n' \
      "$(date '+%Y-%m-%dT%H:%M:%S')" "$session" "$window" "$used" "$secs" "$MAXSLEEP" >> "$LOG"
    exit 0
  fi

  mkdir -p "$PARKDIR"
  printf '%s %s' "$wake" "$window" > "$PARKDIR/$session"
  trap 'rm -f "$PARKDIR/$session"' EXIT
  trap 'exit 130' INT TERM

  printf '%s park session=%s window=%s used=%s%% sleeping=%ss until=%s\n' \
    "$(date '+%Y-%m-%dT%H:%M:%S')" "$session" "$window" "$used" "$secs" "$stamp" >> "$LOG"
  sleep "$secs"
  printf '%s wake session=%s window=%s\n' \
    "$(date '+%Y-%m-%dT%H:%M:%S')" "$session" "$window" >> "$LOG"
done
