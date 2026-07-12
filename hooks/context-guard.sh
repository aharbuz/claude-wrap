#!/bin/bash
# Context Guard - Monitor context usage and nudge session wrap-up
# Runs on the UserPromptSubmit hook event: the nudge lands once, as Claude picks
# up your next message, instead of being bolted onto every tool call.
#
# Thresholds:
#   60-69%: Warn - start wrapping up
#   70%+:   Critical - strongest warning, save work immediately
#
# Token calculation:
#   total = input_tokens + cache_creation_input_tokens + cache_read_input_tokens
#   percentage = total * 100 / context_window
#   context_window is derived from the model ID parsed out of the transcript
#   (unknown models fall back to 200k so warnings fire earlier, not later)

set -e

# Read JSON input from stdin
INPUT=$(cat)

# Parse hook input fields
HOOK_EVENT=$(echo "$INPUT" | jq -r '.hook_event_name // ""')
TRANSCRIPT_PATH=$(echo "$INPUT" | jq -r '.transcript_path // ""')
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // ""')

# Only act on UserPromptSubmit; ignore any other event this may be wired to.
if [ "$HOOK_EVENT" != "UserPromptSubmit" ]; then
  exit 0
fi

# Bail if missing required fields
if [ -z "$TRANSCRIPT_PATH" ] || [ ! -f "$TRANSCRIPT_PATH" ]; then
  exit 0
fi

if [ -z "$SESSION_ID" ]; then
  exit 0
fi

# --- Debounce logic ---
STATE_FILE="/tmp/claude-context-guard-${SESSION_ID}"
DEBOUNCE_SECONDS=30
CONTEXT_PCT=0

now=$(date +%s)

if [ -f "$STATE_FILE" ]; then
  cached_time=$(head -1 "$STATE_FILE" 2>/dev/null || echo "0")
  cached_pct=$(tail -1 "$STATE_FILE" 2>/dev/null || echo "0")
  elapsed=$((now - cached_time))

  if [ "$elapsed" -lt "$DEBOUNCE_SECONDS" ]; then
    CONTEXT_PCT=$cached_pct
  fi
fi

# If not cached or stale, parse transcript for latest usage + model
if [ "$CONTEXT_PCT" -eq 0 ]; then
  # Read the tail of the transcript once and extract both usage and model
  # from the most recent assistant message that has usage data.
  TAIL=$(tail -50 "$TRANSCRIPT_PATH")

  USAGE=$(echo "$TAIL" | jq -s '
    [.[] | select(.type == "assistant" and .message.usage)] |
    last |
    .message.usage // empty
  ' 2>/dev/null)

  MODEL=$(echo "$TAIL" | jq -rs '
    [.[] | select(.type == "assistant" and .message.model)] |
    last |
    .message.model // empty
  ' 2>/dev/null)

  # Resolve context-window size from the model ID.
  # The 1M window is a request-header beta, not encoded in the model ID, so we
  # can't detect it from the transcript. Set CLAUDE_CONTEXT_WINDOW to override
  # when the model-ID guess below is wrong for your setup.
  # Extend this table as new 1M-window models ship. Unknown → 200k (conservative).
  if [ -n "$CLAUDE_CONTEXT_WINDOW" ]; then
    CONTEXT_WINDOW=$CLAUDE_CONTEXT_WINDOW
  else
    case "$MODEL" in
      claude-opus-4-7|claude-opus-4-7-*|claude-opus-4-8|claude-opus-4-8-*)
        CONTEXT_WINDOW=1000000
        ;;
      claude-opus-4-*|claude-sonnet-4-*|claude-haiku-4-*)
        CONTEXT_WINDOW=200000
        ;;
      *)
        CONTEXT_WINDOW=200000
        ;;
    esac
  fi

  if [ -n "$USAGE" ] && [ "$USAGE" != "null" ]; then
    input_tokens=$(echo "$USAGE" | jq -r '.input_tokens // 0')
    cache_creation=$(echo "$USAGE" | jq -r '.cache_creation_input_tokens // 0')
    cache_read=$(echo "$USAGE" | jq -r '.cache_read_input_tokens // 0')

    total=$((input_tokens + cache_creation + cache_read))
    CONTEXT_PCT=$((total * 100 / CONTEXT_WINDOW))
  fi

  # Update state file
  printf '%s\n%s' "$now" "$CONTEXT_PCT" > "$STATE_FILE"
fi

# --- Below threshold: nothing to do ---
if [ "$CONTEXT_PCT" -lt 60 ]; then
  exit 0
fi

# --- Bands: 2 = critical (70%+), 1 = warn (60-69%) ---
if [ "$CONTEXT_PCT" -ge 70 ]; then
  CURRENT_BAND=2
  MSG="Context at ${CONTEXT_PCT}%. STOP starting new work. Run /wrap-up to save progress at the next natural stopping point and suggest continuing in a new session."
else
  CURRENT_BAND=1
  MSG="Context at ${CONTEXT_PCT}%. Start wrapping up — run /wrap-up to save progress and suggest continuing in a new session."
fi

# --- Emit at most once per threshold band ---
# Only speak when crossing INTO a higher band than we last warned about, so
# Claude gets one nudge per threshold rather than one every message. The band is
# persisted separately from the debounce state so it survives the 30s cache
# window. If context drops (e.g. after a compaction) and climbs again, the band
# resets and we're allowed to warn afresh.
BAND_FILE="/tmp/claude-context-guard-${SESSION_ID}-band"
LAST_BAND=$(cat "$BAND_FILE" 2>/dev/null || echo "0")
[ -z "$LAST_BAND" ] && LAST_BAND=0

# Context dropped into a lower band — reset so a later climb can warn again.
if [ "$CURRENT_BAND" -lt "$LAST_BAND" ]; then
  printf '%s' "$CURRENT_BAND" > "$BAND_FILE"
  exit 0
fi

# Already warned at this band: stay quiet.
if [ "$CURRENT_BAND" -le "$LAST_BAND" ]; then
  exit 0
fi

# New, higher band: record it and emit once. UserPromptSubmit injects
# additionalContext into Claude's context; systemMessage surfaces it to the user.
printf '%s' "$CURRENT_BAND" > "$BAND_FILE"
jq -n --arg msg "$MSG" '{
  "systemMessage": $msg,
  "hookSpecificOutput": {
    "hookEventName": "UserPromptSubmit",
    "additionalContext": $msg
  }
}'

exit 0
