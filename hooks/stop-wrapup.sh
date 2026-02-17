#!/bin/bash
# Stop hook - Automated wrap-up when Claude finishes meaningful work
#
# Fires every time Claude stops responding. Runs through 5 guards to determine
# if wrap-up instructions should be injected. If all guards pass, blocks the
# stop and injects wrap-up steps (update docs, continuation prompt, commit, push).
set -e

INPUT=$(cat)
STOP_HOOK_ACTIVE=$(echo "$INPUT" | jq -r '.stop_hook_active // false')
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // ""')
TRANSCRIPT_PATH=$(echo "$INPUT" | jq -r '.transcript_path // ""')

# Guard 1: Loop prevention (stop_hook_active = already continuing from a stop hook)
[ "$STOP_HOOK_ACTIVE" = "true" ] && exit 0

# Guard 2: Transcript must exist and have meaningful length
[ -z "$TRANSCRIPT_PATH" ] || [ ! -f "$TRANSCRIPT_PATH" ] && exit 0
TOTAL_LINES=$(wc -l < "$TRANSCRIPT_PATH" | tr -d ' ')
[ "$TOTAL_LINES" -lt 6 ] && exit 0

# Guard 2.5: Re-trigger prevention
# If wrap-up was previously triggered this session, only fire again if there
# are NEW Write/Edit calls after the last trigger point. Prevents re-triggering
# during back-and-forth discussion/debugging after initial wrap-up.
WRAPUP_STATE="/tmp/claude-stop-wrapup-${SESSION_ID}"
if [ -f "$WRAPUP_STATE" ]; then
  LAST_WRAPUP_LINE=$(cat "$WRAPUP_STATE" 2>/dev/null || echo "0")
  if [ "$TOTAL_LINES" -lt "$LAST_WRAPUP_LINE" ]; then
    # Transcript was compacted — reset state, proceed with normal guards
    rm -f "$WRAPUP_STATE"
  else
    LINES_SINCE=$((TOTAL_LINES - LAST_WRAPUP_LINE))
    if [ "$LINES_SINCE" -le 0 ] || ! tail -"$LINES_SINCE" "$TRANSCRIPT_PATH" | grep -q '"name":\s*"Write"\|"name":\s*"Edit"' 2>/dev/null; then
      exit 0  # No new edits since last wrap-up — don't re-trigger
    fi
  fi
fi

# Guard 3: Check for RECENT Write/Edit tool uses (last ~50 lines)
# Avoids triggering on sessions where edits happened long ago
if ! tail -50 "$TRANSCRIPT_PATH" | grep -q '"name":\s*"Write"\|"name":\s*"Edit"' 2>/dev/null; then
  exit 0
fi

# Guard 4: Last assistant message should be text-only (natural break point)
# If the last assistant response contains tool_use, Claude is still mid-work
LAST_ASSISTANT_HAS_TOOLS=$(tail -10 "$TRANSCRIPT_PATH" | jq -s '
  [.[] | select(.type == "assistant")] | last |
  if .message.content then
    [.message.content[] | select(.type == "tool_use")] | length > 0
  else false end
' 2>/dev/null || echo "false")

if [ "$LAST_ASSISTANT_HAS_TOOLS" = "true" ]; then
  exit 0
fi

# Guard 5: Check if already committed recently (last 30 lines)
if tail -30 "$TRANSCRIPT_PATH" | grep -q '"git commit' 2>/dev/null; then
  exit 0
fi

# All guards passed — inject wrap-up instructions
TIMESTAMP=$(date +"%Y-%m-%d-%H%M")

REASON="You have completed meaningful work. Before stopping, perform these wrap-up steps (skip any already done):

1. UPDATE DOCS: Check the project CLAUDE.md for which docs to update (typically AGENTS/context-in/PROGRESS.md, README.md if structure changed, and any others listed). If you have already updated them, skip.

2. CONTINUATION PROMPT: If there is more planned/requested work remaining, create AGENTS/.convos/continue/${TIMESTAMP}-CONTINUE.md with: (1) summary of work done, (2) current state, (3) next steps, (4) key file paths.
   If you are suggesting NEW future work not previously requested, the continuation prompt must note that user confirmation is needed before continuing.
   If all requested work is complete and you have no suggestions, skip this.

3. COMMIT: If this is a git repo and there are uncommitted changes, stage and commit with a descriptive message. If already committed, skip.

4. PUSH: If a git remote is configured (git remote -v), push. Otherwise skip.

Do these steps now, then you may stop."

# Record trigger point for re-trigger prevention
echo "$TOTAL_LINES" > "$WRAPUP_STATE"

jq -n --arg reason "$REASON" '{"decision": "block", "reason": $reason}'
