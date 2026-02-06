#!/bin/bash
# Context Guard - Monitor context usage and nudge/force session wrap-up
# Handles both PreToolUse and PostToolUse hook events
#
# Thresholds:
#   45-59%: Warn - start wrapping up
#   60-69%: Urgent - wrap up NOW
#   70%+:   Hard stop - block non-essential tools
#
# Token calculation:
#   total = input_tokens + cache_creation_input_tokens + cache_read_input_tokens
#   percentage = total / 200000

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

# If not cached or stale, parse transcript for latest usage
if [ "$CONTEXT_PCT" -eq 0 ]; then
  # Get the last assistant message's usage stats from the transcript
  # Use tail (macOS-compatible, no tac) to read recent lines and find the last usage block
  USAGE=$(tail -50 "$TRANSCRIPT_PATH" | jq -s '
    [.[] | select(.type == "assistant" and .message.usage)] |
    last |
    .message.usage // empty
  ' 2>/dev/null)

  if [ -n "$USAGE" ] && [ "$USAGE" != "null" ]; then
    input_tokens=$(echo "$USAGE" | jq -r '.input_tokens // 0')
    cache_creation=$(echo "$USAGE" | jq -r '.cache_creation_input_tokens // 0')
    cache_read=$(echo "$USAGE" | jq -r '.cache_read_input_tokens // 0')

    total=$((input_tokens + cache_creation + cache_read))
    # Integer percentage: (total * 100) / 200000
    CONTEXT_PCT=$((total * 100 / 200000))
  fi

  # Update state file
  printf '%s\n%s' "$now" "$CONTEXT_PCT" > "$STATE_FILE"
fi

# --- Below threshold: nothing to do ---
if [ "$CONTEXT_PCT" -lt 45 ]; then
  exit 0
fi

# --- PreToolUse: block non-essential tools at 70%+ ---
if [ "$HOOK_EVENT" = "PreToolUse" ] && [ "$CONTEXT_PCT" -ge 70 ]; then
  # Allow tools needed for saving work
  case "$TOOL_NAME" in
    Write|Edit|Bash|TaskUpdate|TaskCreate)
      # Allowed - let these through for saving work
      ;;
    *)
      # Block everything else
      echo "Context at ${CONTEXT_PCT}%. Blocked ${TOOL_NAME}. Save your work and end the session." >&2
      exit 2
      ;;
  esac
fi

# --- PostToolUse: inject system messages at thresholds ---
if [ "$HOOK_EVENT" = "PostToolUse" ]; then
  if [ "$CONTEXT_PCT" -ge 70 ]; then
    MSG="CONTEXT AT ${CONTEXT_PCT}%. STOP. Do not start new work. Save progress immediately: summarize what was done, what remains, and any file paths needed to continue. Then end the session."
  elif [ "$CONTEXT_PCT" -ge 60 ]; then
    MSG="Context at ${CONTEXT_PCT}%. Wrap up NOW. Finish your current edit, save progress to AGENTS/PROGRESS.md, and prepare a handoff summary. Do not begin any new tasks."
  else
    MSG="Context at ${CONTEXT_PCT}%. Start wrapping up at the next sensible point. Finish what you're doing, then prepare a handoff summary."
  fi

  # Output JSON with systemMessage for Claude to receive
  echo "{\"systemMessage\": \"$MSG\", \"continue\": true}"
fi

exit 0
