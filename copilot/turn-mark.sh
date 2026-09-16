#!/usr/bin/env bash
# Copilot CLI hook (userPromptSubmitted): mark that a NEW TURN has begun.
#
# The status line wants to show what the last turn cost — the single most useful
# number when you come back to a session you left working — but the payload it
# renders from only carries the session's RUNNING total (ai_used.total_nano_aiu).
# A per-turn figure is that total minus whatever it was when the turn started,
# and nothing in the payload says where a turn starts.
#
# So this hook does the only thing it is in a position to do: drop a marker.
# It cannot record the credits itself — the hook payload has no spend in it — but
# the status line remembers the last total it rendered, and a turn begins exactly
# where that value was frozen. The next render sees the marker, promotes its own
# "last seen" figure to the turn's baseline, and deletes the marker.
#
# Written as a marker rather than a timestamp on purpose: a heuristic ("no render
# for 30s ⇒ new turn") would reset the counter in the middle of any slow tool call.
set -u
sid="$(python3 -c 'import json,sys
try: print(json.load(sys.stdin).get("sessionId") or "")
except Exception: print("")' 2>/dev/null)"
[ -n "$sid" ] || exit 0
dir="$HOME/.copilot/turn-state"
mkdir -p "$dir" || exit 0
: > "$dir/$sid.new"
