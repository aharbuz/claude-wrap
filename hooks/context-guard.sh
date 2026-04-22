#!/bin/bash
# Context Guard - Monitor context usage and nudge/force session wrap-up
# Handles both PreToolUse and PostToolUse hook events
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
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // ""')

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
  # Extend this table as new 1M-window models ship. Unknown → 200k (conservative).
  case "$MODEL" in
    claude-opus-4-7|claude-opus-4-7-*)
      CONTEXT_WINDOW=1000000
      ;;
    claude-opus-4-*|claude-sonnet-4-*|claude-haiku-4-*)
      CONTEXT_WINDOW=200000
      ;;
    *)
      CONTEXT_WINDOW=200000
      ;;
  esac

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

# --- PreToolUse: urgent warning at 70%+ (no blocking) ---
if [ "$HOOK_EVENT" = "PreToolUse" ] && [ "$CONTEXT_PCT" -ge 70 ]; then
  MSG="CRITICAL: Context at ${CONTEXT_PCT}%. Run /wrap-up to save progress at the next natural stopping point and suggest continuing in a new session."
  jq -n --arg msg "$MSG" '{"systemMessage": $msg, "continue": true}'
fi

# --- PostToolUse: inject system messages at thresholds ---
if [ "$HOOK_EVENT" = "PostToolUse" ]; then
  if [ "$CONTEXT_PCT" -ge 70 ]; then
    MSG="CONTEXT AT ${CONTEXT_PCT}%. STOP. Do not start new work. Run /wrap-up to save progress at the next natural stopping point and suggest continuing in a new session."
  else
    MSG="Context at ${CONTEXT_PCT}%. Run /wrap-up to save progress at the next natural stopping point and suggest continuing in a new session."
  fi

  # Output JSON with systemMessage for Claude to receive (use jq for safe encoding)
  jq -n --arg msg "$MSG" '{"systemMessage": $msg, "continue": true}'
fi

exit 0
