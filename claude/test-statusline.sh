#!/bin/sh
# Minimal regression harness for claude/statusline-command.sh: feeds sample
# JSON payloads (what Claude Code hands the script on stdin) and asserts
# substrings in the rendered line, so the quota/park rendering is checked by
# an assertion instead of by eye. Not a general test framework -- just enough
# to keep the paused-on-quota segment (and the plain 5h segment next to it)
# from silently regressing.
#
# Runs in a throwaway $HOME so it never touches the real quota-park/cwd state
# under ~/.claude, and cleans up its /tmp state files (those are keyed by
# session_id and hardcoded to /tmp inside the script itself, HOME override or
# not -- see the "why /tmp and not $HOME" note in the script for cost/turn
# caching).
#
#   ./claude/test-statusline.sh
cd "$(dirname "$0")/.." || exit 2
SCRIPT="$PWD/claude/statusline-command.sh"

TMP=$(mktemp -d)
cleanup() {
  rm -rf "$TMP"
  rm -f /tmp/claude-statusline-*-statusline-test-*.txt 2>/dev/null
  rm -f /tmp/claude-turn-statusline-test-*.state 2>/dev/null
}
trap cleanup EXIT INT TERM
export HOME="$TMP"
mkdir -p "$HOME/.claude"

pass=0
fail=0

# strip_ansi + assert_contains "<label>" "<haystack>" "<needle>"
assert_contains() {
  label=$1; haystack=$2; needle=$3
  plain=$(printf '%s' "$haystack" | sed 's/\x1b\[[0-9;]*m//g')
  case "$plain" in
    *"$needle"*) pass=$((pass + 1)); printf 'ok    %s\n' "$label" ;;
    *)
      fail=$((fail + 1))
      printf 'FAIL  %s\n      expected to find: %s\n      got:              %s\n' \
        "$label" "$needle" "$plain"
      ;;
  esac
}

assert_not_contains() {
  label=$1; haystack=$2; needle=$3
  plain=$(printf '%s' "$haystack" | sed 's/\x1b\[[0-9;]*m//g')
  case "$plain" in
    *"$needle"*)
      fail=$((fail + 1))
      printf 'FAIL  %s\n      expected NOT to find: %s\n      got:                  %s\n' \
        "$label" "$needle" "$plain"
      ;;
    *) pass=$((pass + 1)); printf 'ok    %s\n' "$label" ;;
  esac
}

now=$(date +%s)
reset=$((now + 3 * 3600 + 23 * 60))   # 3h23m from now

# --- Case 1: normal 5h quota, this terminal NOT parked -----------------------
payload=$(cat <<JSON
{"session_id":"statusline-test-normal","model":{"display_name":"Claude Opus"},
 "context_window":{},
 "rate_limits":{"five_hour":{"used_percentage":40,"resets_at":$reset}}}
JSON
)
out=$(printf '%s' "$payload" | sh "$SCRIPT")
assert_contains    "normal: quota-left percentage"     "$out" "60%"
assert_contains    "normal: window countdown"           "$out" "3h2"
assert_not_contains "normal: no pause glyph when awake" "$out" "💤"

# --- Case 2: quota exhausted AND parked by quota-gate.sh ---------------------
session="statusline-test-parked"
wake=$((now + 45 * 60 + 12))          # 45m12s from now
mkdir -p "$HOME/.claude/quota-park"
printf '%s' "$wake" > "$HOME/.claude/quota-park/$session"
back=$(date -r "$wake" +%H:%M)
payload=$(cat <<JSON
{"session_id":"$session","model":{"display_name":"Claude Opus"},
 "context_window":{},
 "rate_limits":{"five_hour":{"used_percentage":98,"resets_at":$reset}}}
JSON
)
out=$(printf '%s' "$payload" | sh "$SCRIPT")
assert_contains "parked: pause glyph present"        "$out" "💤"
assert_contains "parked: absolute local wake clock"  "$out" "$back"
assert_contains "parked: glyph glued to the percentage" "$out" "%💤"
assert_contains "parked: next probe precedes the reset countdown" "$out" "%💤 → $back /"
assert_not_contains "parked: no second sleep countdown"  "$out" "45m"

# --- Case 3: a park marker whose wake time has ALREADY passed (stale/woken) --
# quota-gate.sh's own trap removes this file on exit, but the render must not
# show a pause state, whether the file lingers or not.
session="statusline-test-woken"
mkdir -p "$HOME/.claude/quota-park"
printf '%s' "$((now - 60))" > "$HOME/.claude/quota-park/$session"
payload=$(cat <<JSON
{"session_id":"$session","model":{"display_name":"Claude Opus"},
 "context_window":{},
 "rate_limits":{"five_hour":{"used_percentage":98,"resets_at":$reset}}}
JSON
)
out=$(printf '%s' "$payload" | sh "$SCRIPT")
assert_not_contains "woken: no pause glyph once wake time has passed" "$out" "💤"

# --- Case 4: weekly quota exhausted and parked by quota-gate.sh -------------
# Window-aware markers put the sleep state on the quota that caused it. The
# weekly probe clock includes a weekday so an hour crossing midnight is clear.
session="statusline-test-weekly-parked"
week_reset=$((now + 2 * 86400 + 47 * 60))
wake=$((week_reset + 12))
mkdir -p "$HOME/.claude/quota-park"
printf '%s seven_day' "$wake" > "$HOME/.claude/quota-park/$session"
back=$(date -r "$wake" '+%a %H:%M')
payload=$(cat <<JSON
{"session_id":"$session","model":{"display_name":"Claude Opus"},
 "context_window":{},
 "rate_limits":{"five_hour":{"used_percentage":40,"resets_at":$reset},
                "seven_day":{"used_percentage":100,"resets_at":$week_reset}}}
JSON
)
out=$(printf '%s' "$payload" | sh "$SCRIPT")
assert_contains "weekly parked: glyph glued to weekly percentage" "$out" "0%💤"
assert_contains "weekly parked: wake clock includes weekday"      "$out" "→ $back"
assert_not_contains "weekly parked: five-hour percentage stays awake" "$out" "60%💤"

# --- Case 5: a probe reading outranks a frozen session payload --------------
# The plan-switch bug of 2026-09-11 (Max 5x -> 20x): an idle terminal keeps
# re-publishing the payload it was handed before the allowance grew, and by
# value that old, higher figure wins the merge on every render. quota-probe.sh
# writes the account's real number with source=probe, and quota-state.sh must
# refuse to let a NON-fresh session reading displace it. Needs the real
# quota-state.sh under this throwaway HOME; quota-probe.sh is deliberately
# absent, so the render never fires a network request from a test.
STATE="$PWD/claude/hooks/quota-state.sh"
mkdir -p "$HOME/.claude/hooks"
ln -s "$STATE" "$HOME/.claude/hooks/quota-state.sh"
session="statusline-test-weekly-probe"
rm -f "/tmp/claude-statusline-rl-$session.txt"
payload=$(cat <<JSON
{"session_id":"$session","model":{"display_name":"Claude Opus"},
 "context_window":{},
 "rate_limits":{"five_hour":{"used_percentage":40,"resets_at":$reset},
                "seven_day":{"used_percentage":94,"resets_at":$week_reset}}}
JSON
)
# First render: nothing stored and a payload never seen -> fresh, and 94 lands.
# This is the pre-upgrade state every terminal was in.
out=$(printf '%s' "$payload" | sh "$SCRIPT")
assert_contains "probe: the frozen payload paints the old plan's number first" "$out" "6% /"
# The probe arrives with the account's real figure.
"$STATE" set -1 0 9 "$week_reset" >/dev/null
# Same bytes again -> non-fresh -> the measurement holds, whatever the cache says.
out=$(printf '%s' "$payload" | sh "$SCRIPT")
assert_contains "probe: the measured 9% used replaces the frozen 94%" "$out" "91% /"
assert_not_contains "probe: the old plan's number is gone" "$out" "6% /"

# Protection lasts two probe intervals (the probe runs every one). Past that the
# probe reading is as old as anything else and value order resumes -- the
# deliberate fallback when the probe keeps failing.
jq '.seven_day.measured_at -= 601' "$HOME/.claude/quota.json" > "$HOME/.claude/quota.json.new" \
  && mv "$HOME/.claude/quota.json.new" "$HOME/.claude/quota.json"
out=$(printf '%s' "$payload" | env -u CLAUDE_QUOTA_PROBE_SECS -u CLAUDE_WEEKLY_QUOTA_PROBE_SECS sh "$SCRIPT")
assert_contains "probe: an aged-out probe reading yields to value order again" "$out" "6% /"
rm -f "$HOME/.claude/hooks/quota-state.sh" "$HOME/.claude/quota.json"

# --- Case: subagents in flight ----------------------------------------------
# Builds a session directory shaped like the one Claude Code writes -- a parent
# transcript plus <sid>/subagents/agent-<id>.{meta.json,jsonl} -- and checks the
# three judgements the chip has to make: who is still running, what each one is
# running on, and how the groups collapse.
session="statusline-test-subagents"
proj="$HOME/.claude/projects/test"
sub="$proj/$session/subagents"
mkdir -p "$sub"
tp="$proj/$session.jsonl"

# id / model / effort ("-" = none, as Haiku writes it) / requested-alias
mk_agent() {
  printf '{"agentType":"general-purpose","description":"t","toolUseId":"toolu_%s","spawnDepth":1,"model":"%s"}' \
    "$1" "$4" > "$sub/agent-$1.meta.json"
  eff=",\"effort\":\"$3\""
  [ "$3" = "-" ] && eff=""
  printf '{"type":"user","isSidechain":true,"agentId":"%s","message":{"role":"user"}}\n{"type":"assistant","agentId":"%s"%s,"message":{"role":"assistant","model":"%s"}}\n' \
    "$1" "$1" "$eff" "$2" > "$sub/agent-$1.jsonl"
}
mk_agent A claude-opus-5              high   opus
mk_agent B claude-opus-5              high   opus
mk_agent C claude-sonnet-5            medium sonnet
mk_agent D claude-opus-5              high   opus
mk_agent E claude-haiku-4-5-20251001  -      haiku
mk_agent F claude-fable-5-1           high   fable
mk_agent G claude-opus-5              high   opus

{
  # The spawn itself: tool_use blocks carry the id as "id", never as
  # "tool_use_id", so none of these may read as a finished agent.
  printf '{"type":"assistant","message":{"content":[{"type":"tool_use","id":"toolu_A","name":"Task"},{"type":"tool_use","id":"toolu_D","name":"Task"}]}}\n'
  # D returned; E was launched async in the SAME user turn. The launch receipt
  # must not be mistaken for D's result, nor D's result for E's.
  printf '{"type":"user","message":{"content":[{"tool_use_id":"toolu_D","type":"tool_result","content":"the report"},{"tool_use_id":"toolu_E","type":"tool_result","content":[{"type":"text","text":"Async agent launched successfully. agentId: E"}]}]}}\n'
  # F was launched async and has since notified that it stopped.
  printf '{"type":"user","message":{"content":[{"tool_use_id":"toolu_F","type":"tool_result","content":[{"type":"text","text":"Async agent launched successfully. agentId: F"}]}]}}\n'
  printf '{"type":"user","message":{"content":"<task-notification>\\n<task-id>F</task-id>\\n<tool-use-id>toolu_F</tool-use-id>\\n<status>completed</status>\\n</task-notification>"}}\n'
} > "$tp"

# G never got a marker but has been silent for hours: a corpse, not a worker.
touch -t 202001010000 "$sub/agent-G.jsonl"

payload=$(cat <<JSON
{"session_id":"$session","model":{"display_name":"Opus 5 (1M context)"},
 "effort":{"level":"high"},"transcript_path":"$tp",
 "context_window":{"used_percentage":6,"context_window_size":1000000},
 "rate_limits":{"five_hour":{"used_percentage":40,"resets_at":$reset}}}
JSON
)
out=$(printf '%s' "$payload" | sh "$SCRIPT")
assert_contains     "subagents: groups by model+effort, biggest first" "$out" "+{O5h×2,H4.5,S5m}"
assert_not_contains "subagents: no effort letter is invented for Haiku" "$out" "H4.5h"
assert_contains     "subagents: chip hangs off the model segment"      "$out" "60K +{"
assert_not_contains "subagents: a returned Task is gone"               "$out" "×3"
assert_not_contains "subagents: a notified async agent is gone"        "$out" "F5.1"
assert_not_contains "subagents: a silent corpse is not counted"        "$out" "×4"

# Second render, same state: the per-agent facts now come from the cache file
# rather than from re-reading seven agent transcripts. Same answer either way.
out=$(printf '%s' "$payload" | sh "$SCRIPT")
assert_contains "subagents: cached second render is identical" "$out" "+{O5h×2,H4.5,S5m}"

# --- Case 7: a done-marker that has scrolled out of the scanned tail ---------
# Only the last $CLAUDE_SUB_TAIL bytes of the parent transcript are read, and a
# busy session writes past its own markers. Once F's notification falls outside
# that window the scan can no longer see that F ever stopped -- unless the first
# render wrote the id down. This is the bug that had a finished async agent
# sitting in the chip for a quarter of an hour (10 Sep 2026).
session="statusline-test-scrolled"
sub="$proj/$session/subagents"
mkdir -p "$sub"
tp="$proj/$session.jsonl"
mk_agent F claude-fable-5-1 high fable
{
  printf '{"type":"user","message":{"content":[{"tool_use_id":"toolu_F","type":"tool_result","content":[{"type":"text","text":"Async agent launched successfully. agentId: F"}]}]}}\n'
  printf '{"type":"user","message":{"content":"<task-notification>\\n<task-id>F</task-id>\\n<tool-use-id>toolu_F</tool-use-id>\\n<status>completed</status>\\n</task-notification>"}}\n'
  # Everything after the marker: enough of it to push the marker out of a small tail.
  i=0
  while [ "$i" -lt 200 ]; do
    printf '{"type":"assistant","message":{"content":"padding padding padding padding padding padding padding padding"}}\n'
    i=$((i + 1))
  done
} > "$tp"

payload=$(cat <<JSON
{"session_id":"$session","model":{"display_name":"Opus 5 (1M context)"},
 "effort":{"level":"high"},"transcript_path":"$tp",
 "context_window":{"used_percentage":6,"context_window_size":1000000},
 "rate_limits":{"five_hour":{"used_percentage":40,"resets_at":$reset}}}
JSON
)
# First render: the marker is still inside a generous tail, so F is seen to stop.
out=$(printf '%s' "$payload" | CLAUDE_SUB_TAIL=2000000 sh "$SCRIPT")
assert_not_contains "scrolled: marker inside the tail retires the agent" "$out" "F5.1"
# Second render, tail now too small to reach the marker. Without the remembered
# id, F comes back from the dead and the chip lies until the mtime floor.
out=$(printf '%s' "$payload" | CLAUDE_SUB_TAIL=4000 sh "$SCRIPT")
assert_not_contains "scrolled: marker outside the tail stays retired" "$out" "F5.1"
assert_not_contains "scrolled: no chip left at all"                   "$out" "+{"

# --- Case 8: an async agent resumed with SendMessage ------------------------
# The first stop earns the agent a marker, and the marker is remembered. A
# SendMessage addressed to its id restarts it under the same toolUseId, so the
# remembered marker alone would hide it for the rest of the session while it
# works (13 Sep 2026: chip showed one agent, the native list two). A resume seen
# AFTER the last marker means live again; the next stop retires it once more.
session="statusline-test-resumed"
sub="$proj/$session/subagents"
mkdir -p "$sub"
tp="$proj/$session.jsonl"
mk_agent F claude-fable-5-1 high fable
{
  printf '{"type":"user","message":{"content":[{"tool_use_id":"toolu_F","type":"tool_result","content":[{"type":"text","text":"Async agent launched successfully. agentId: F"}]}]}}\n'
  printf '{"type":"user","message":{"content":"<task-notification>\\n<task-id>F</task-id>\\n<tool-use-id>toolu_F</tool-use-id>\\n<status>completed</status>\\n</task-notification>"}}\n'
} > "$tp"
payload=$(cat <<JSON
{"session_id":"$session","model":{"display_name":"Opus 5 (1M context)"},
 "effort":{"level":"high"},"transcript_path":"$tp",
 "context_window":{"used_percentage":6,"context_window_size":1000000},
 "rate_limits":{"five_hour":{"used_percentage":40,"resets_at":$reset}}}
JSON
)
out=$(printf '%s' "$payload" | sh "$SCRIPT")
assert_not_contains "resumed: the first stop retires the agent" "$out" "F5.1"
# Enough traffic to push that marker out of a small tail, then the resume. The
# remembered id says done; the resume inside the window must win over it.
i=0
while [ "$i" -lt 200 ]; do
  printf '{"type":"assistant","message":{"content":"padding padding padding padding padding padding padding padding"}}\n' >> "$tp"
  i=$((i + 1))
done
printf '{"type":"assistant","message":{"content":[{"type":"tool_use","id":"toolu_S1","name":"SendMessage","input":{"to":"F","summary":"one more thing","message":"carry on"}}]}}\n' >> "$tp"
touch "$sub/agent-F.jsonl"
out=$(printf '%s' "$payload" | CLAUDE_SUB_TAIL=4000 sh "$SCRIPT")
assert_contains "resumed: a SendMessage after the marker brings it back" "$out" "+{F5.1h}"
# The second stop: same toolUseId, new notification, later than the resume.
printf '{"type":"user","message":{"content":"<task-notification>\\n<task-id>F</task-id>\\n<tool-use-id>toolu_F</tool-use-id>\\n<status>completed</status>\\n</task-notification>"}}\n' >> "$tp"
# A message to something that is not one of our agents changes nothing.
printf '{"type":"assistant","message":{"content":[{"type":"tool_use","id":"toolu_S2","name":"SendMessage","input":{"to":"reviewer","message":"ping"}}]}}\n' >> "$tp"
out=$(printf '%s' "$payload" | CLAUDE_SUB_TAIL=4000 sh "$SCRIPT")
assert_not_contains "resumed: the second stop retires it again"        "$out" "F5.1"
assert_not_contains "resumed: a message to a stranger revives nothing" "$out" "+{"

# --- Case 9: a slash-command forked into the background ---------------------
# /code-review run in the background is an agent like any other -- its own
# transcript, its own line in the native list as @code-review-2 -- but its
# meta.json carries a "name" and no "toolUseId" whatsoever. A scan keyed on that
# one field dropped it before it was ever counted, and the chip stayed blank
# through an hour-long review (15 Sep 2026). Such an agent is keyed on its own
# agentId, retired on the <task-id> of its notification, and resumable by name.
session="statusline-test-forked-skill"
sub="$proj/$session/subagents"
mkdir -p "$sub"
tp="$proj/$session.jsonl"

# id / @name / model / effort. No toolUseId and no model alias: exactly the
# shape Claude Code writes for a forked skill.
mk_forked() {
  printf '{"agentType":"general-purpose","description":"/code-review main","name":"%s","spawnDepth":1,"requestShape":"background","requestNonInteractive":true}' \
    "$2" > "$sub/agent-$1.meta.json"
  printf '{"type":"user","isSidechain":true,"agentId":"%s","message":{"role":"user"}}\n{"type":"assistant","agentId":"%s","effort":"%s","message":{"role":"assistant","model":"%s"}}\n' \
    "$1" "$1" "$4" "$3" > "$sub/agent-$1.jsonl"
}
mk_forked P code-review   claude-opus-5   high
mk_forked Q code-review-2 claude-sonnet-5 medium
{
  # The launch receipt. It names the agent under "agentId", and its own
  # tool_use_id belongs to the Skill call, not to the agent -- so it can never
  # read as that agent stopping.
  printf '{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"toolu_P","content":"Skill launched (forked execution, running in the background).\\n\\nRunning in the background as @code-review"}]},"toolUseResult":{"status":"forked","background":true,"agentId":"P"}}\n'
  printf '{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"toolu_Q","content":"Skill launched (forked execution, running in the background).\\n\\nRunning in the background as @code-review-2"}]},"toolUseResult":{"status":"forked","background":true,"agentId":"Q"}}\n'
} > "$tp"

payload=$(cat <<JSON
{"session_id":"$session","model":{"display_name":"Opus 5 (1M context)"},
 "effort":{"level":"high"},"transcript_path":"$tp",
 "context_window":{"used_percentage":6,"context_window_size":1000000},
 "rate_limits":{"five_hour":{"used_percentage":40,"resets_at":$reset}}}
JSON
)
out=$(printf '%s' "$payload" | sh "$SCRIPT")
assert_contains "forked skill: an agent with no toolUseId is still counted" "$out" "+{O5h,S5m}"

# P stops. Its notification carries the launch tool-use-id, which is NOT the key
# here, and the agent id, which is -- so this retires it only via <task-id>.
printf '{"type":"user","message":{"content":"<task-notification>\\n<task-id>P</task-id>\\n<tool-use-id>toolu_P</tool-use-id>\\n<status>killed</status>\\n</task-notification>"}}\n' >> "$tp"
out=$(printf '%s' "$payload" | sh "$SCRIPT")
assert_not_contains "forked skill: its notification retires it by task-id" "$out" "O5h"
assert_contains     "forked skill: the one still working stays"            "$out" "+{S5m}"

# Resumed the way Victor actually resumes one of these: by @name, not by id.
printf '{"type":"assistant","message":{"content":[{"type":"tool_use","id":"toolu_S3","name":"SendMessage","input":{"to":"code-review","message":"carry on"}}]}}\n' >> "$tp"
touch "$sub/agent-P.jsonl"
out=$(printf '%s' "$payload" | sh "$SCRIPT")
assert_contains "forked skill: a SendMessage to its @name brings it back" "$out" "+{O5h,S5m}"

# A session that never spawned anything renders no chip at all.
session="statusline-test-no-subagents"
tp="$proj/$session.jsonl"
printf '{"type":"assistant","message":{"content":[]}}\n' > "$tp"
payload=$(cat <<JSON
{"session_id":"$session","model":{"display_name":"Opus 5 (1M context)"},
 "effort":{"level":"high"},"transcript_path":"$tp",
 "context_window":{"used_percentage":6,"context_window_size":1000000},
 "rate_limits":{"five_hour":{"used_percentage":40,"resets_at":$reset}}}
JSON
)
out=$(printf '%s' "$payload" | sh "$SCRIPT")
assert_not_contains "no subagents: no chip, no placeholder" "$out" "+{"
assert_not_contains "no subagents: placeholder is resolved" "$out" "@@SUB@@"

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
