#!/bin/bash
# Auto-export conversation transcript with incremental PreCompact support
# Handles both PreCompact (incremental append) and SessionEnd (finalization)
# Exports to [project]/AGENTS/.convos/ by default
#
# PreCompact:  Append only new lines since last checkpoint to active session files
# SessionEnd:  Append remaining lines, rename files with timestamp, clean up
# /clear:      Skip content processing, finalize files with _cleared suffix
# logout:      Skip entirely

set -euo pipefail

# --- B. Debug logging & dependency check ---

DEBUG_LOG="/tmp/claude-export-debug.log"

debug() {
  echo "$(date '+%H:%M:%S') [$$] $*" >> "$DEBUG_LOG"
}

if ! command -v jq &>/dev/null; then
  debug "FATAL: jq not found"
  exit 0
fi

# --- C. Read stdin JSON, parse fields ---

INPUT=$(cat)
HOOK_EVENT=$(echo "$INPUT" | jq -r '.hook_event_name // ""')
REASON=$(echo "$INPUT" | jq -r '.reason // ""')
TRANSCRIPT_PATH=$(echo "$INPUT" | jq -r '.transcript_path // ""')
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // "unknown"')
CWD=$(echo "$INPUT" | jq -r '.cwd // ""')

debug "Event=$HOOK_EVENT Reason=$REASON Session=$SESSION_ID"

# --- D. Early exits ---

if [ "$REASON" = "logout" ]; then
  debug "Skipping: logout"
  exit 0
fi

# --- E. Export directory ---

if [ -n "$CWD" ]; then
  EXPORT_DIR="$CWD/AGENTS/.convos"
else
  EXPORT_DIR="$HOME/.claude/exports"
fi

mkdir -p "$EXPORT_DIR"

# --- F. Detect event type ---

SHORT_ID="${SESSION_ID:0:8}"
MARKER_FILE="/tmp/claude-export-${SESSION_ID}-lastline"
TITLE_FILE="/tmp/claude-export-${SESSION_ID}-title"

if [ "$HOOK_EVENT" = "PreCompact" ]; then
  EVENT_TYPE="precompact"
elif [ "$REASON" = "clear" ]; then
  EVENT_TYPE="session-clear"
else
  EVENT_TYPE="session-end"
fi

debug "EventType=$EVENT_TYPE"

# --- G. Marker state ---

LAST_LINE=0
if [ -f "$MARKER_FILE" ]; then
  LAST_LINE=$(cat "$MARKER_FILE")
fi

TOTAL_LINES=0
if [ -n "$TRANSCRIPT_PATH" ] && [ -f "$TRANSCRIPT_PATH" ]; then
  TOTAL_LINES=$(wc -l < "$TRANSCRIPT_PATH" | tr -d ' ')
fi

debug "LastLine=$LAST_LINE TotalLines=$TOTAL_LINES"

# --- H. Title extraction (first run only, persist to file) ---

extract_title() {
  local transcript="$1"
  local first_msg
  first_msg=$(jq -r '
    select(.type == "human" or .type == "user") |
    .message.content |
    if type == "array" then
      map(select(.type == "text") | .text) | first // ""
    elif type == "string" then
      .
    else
      ""
    end
  ' "$transcript" 2>/dev/null | head -1 | tr -d '\n')

  echo "$first_msg" | \
    sed 's/[^a-zA-Z0-9 ]//g' | \
    tr '[:upper:]' '[:lower:]' | \
    tr ' ' '-' | \
    sed 's/--*/-/g' | \
    sed 's/^-//' | \
    sed 's/-$//' | \
    cut -c1-50
}

if [ -f "$TITLE_FILE" ]; then
  TITLE=$(cat "$TITLE_FILE")
else
  TITLE=""
  if [ -n "$TRANSCRIPT_PATH" ] && [ -f "$TRANSCRIPT_PATH" ]; then
    TITLE=$(extract_title "$TRANSCRIPT_PATH")
  fi
  if [ -z "$TITLE" ] || [ "$TITLE" = "null" ]; then
    TITLE="session"
  fi
  echo "$TITLE" > "$TITLE_FILE"
fi

debug "Title=$TITLE"

# --- I. Active file paths ---

ACTIVE_JSONL="$EXPORT_DIR/${TITLE}-${SHORT_ID}.jsonl"
ACTIVE_MD="$EXPORT_DIR/${TITLE}-${SHORT_ID}.md"
ACTIVE_TXT="$EXPORT_DIR/${TITLE}-${SHORT_ID}.txt"

# --- J. jq markdown filter as shell function ---

jq_markdown_filter() {
  jq -r '
    if (.type == "human" or .type == "user") then
      "## User\n\n" + (
        .message.content |
        if type == "array" then
          map(
            if .type == "text" then .text
            elif .type == "image" then "*[Image]*"
            else ""
            end
          ) | join("\n\n")
        elif type == "string" then .
        else ""
        end
      ) + "\n"
    elif .type == "assistant" then
      "## Claude\n\n" + (
        .message.content |
        if type == "array" then
          map(
            if .type == "text" then
              .text
            elif .type == "tool_use" then
              "**🔧 " + .name + "**" +
              (if .input then
                "\n```json\n" + (.input | tostring) + "\n```"
              else "" end)
            else ""
            end
          ) | map(select(. != "")) | join("\n\n")
        elif type == "string" then .
        else ""
        end
      ) + "\n"
    elif .type == "tool_result" then
      "### → Result" +
      (if .message.content then
        (
          .message.content |
          if type == "array" then
            map(
              if .type == "text" then
                "\n```\n" + .text + "\n```"
              else ""
              end
            ) | join("\n")
          elif type == "string" then
            "\n```\n" + . + "\n```"
          else ""
          end
        )
      else "" end) + "\n"
    else
      empty
    end
  '
}

# --- J2. jq TXT filter as shell function ---

jq_txt_filter() {
  jq -r '
    # Skip meta messages and tool results
    select(.isMeta != true) |
    if (.type == "human" or .type == "user") then
      (.message.content |
        if type == "array" then
          map(select(.type == "text") | .text) | join("\n\n")
        elif type == "string" then .
        else ""
        end
      ) as $content |
      if $content != "" then "> " + $content + "\n" else empty end
    elif .type == "assistant" then
      (.message.content |
        if type == "array" then
          map(
            if .type == "text" and .text != "" then "\u23fa " + .text
            elif .type == "tool_use" then "\u23fa Using tool: " + .name
            else empty
            end
          ) | join("\n\n")
        elif type == "string" then
          if . != "" then "\u23fa " + . else empty end
        else empty
        end
      ) as $content |
      if $content != "" then $content + "\n" else empty end
    else
      empty
    end
  '
}

# --- K. Main dispatch: markdown processing ---

if [ "$EVENT_TYPE" = "session-clear" ]; then
  debug "Session clear: skipping content processing"

elif [ "$TOTAL_LINES" -eq 0 ]; then
  debug "No transcript content, skipping"

elif [ "$LAST_LINE" -eq 0 ]; then
  # First run: write header + all content
  debug "First run: processing all $TOTAL_LINES lines"

  {
    echo "# ${TITLE}"
    echo ""
    echo "**Date:** $(date '+%Y-%m-%d %H:%M')"
    echo "**Session:** ${SESSION_ID}"
    echo ""
    echo "---"
    echo ""
    jq_markdown_filter < "$TRANSCRIPT_PATH" 2>/dev/null || echo "*Could not parse transcript*"
  } > "$ACTIVE_MD"

  {
    echo "════════════════════════════════════════════════════════════════"
    echo "Session: ${TITLE}"
    echo "Date: $(date '+%Y-%m-%d %H:%M')"
    echo "ID: ${SESSION_ID}"
    echo "════════════════════════════════════════════════════════════════"
    echo ""
    jq_txt_filter < "$TRANSCRIPT_PATH" 2>/dev/null || echo "(Could not parse transcript)"
  } > "$ACTIVE_TXT"

elif [ "$TOTAL_LINES" -lt "$LAST_LINE" ]; then
  # Compaction detected: transcript was rewritten, process full new transcript
  debug "Compaction detected (${TOTAL_LINES} < ${LAST_LINE}): processing full new transcript"

  {
    echo ""
    echo "---"
    echo "*[Compacted at $(date '+%H:%M')]*"
    echo ""
    jq_markdown_filter < "$TRANSCRIPT_PATH" 2>/dev/null || echo "*Could not parse transcript*"
  } >> "$ACTIVE_MD"

  {
    echo ""
    echo "──── [Compacted at $(date '+%H:%M') | full transcript reprocessed] ────"
    echo ""
    jq_txt_filter < "$TRANSCRIPT_PATH" 2>/dev/null || echo "(Could not parse transcript)"
  } >> "$ACTIVE_TXT"

elif [ "$TOTAL_LINES" -gt "$LAST_LINE" ]; then
  # Incremental: append only new lines
  NEW_LINES=$((TOTAL_LINES - LAST_LINE))
  debug "Incremental: appending $NEW_LINES new lines (${LAST_LINE}+1 to ${TOTAL_LINES})"

  tail -n "$NEW_LINES" "$TRANSCRIPT_PATH" | jq_markdown_filter >> "$ACTIVE_MD" 2>/dev/null || true

  tail -n "$NEW_LINES" "$TRANSCRIPT_PATH" | jq_txt_filter >> "$ACTIVE_TXT" 2>/dev/null || true

else
  debug "No new lines since last checkpoint"
fi

# --- L. JSONL incremental append ---

if [ "$EVENT_TYPE" != "session-clear" ] && [ "$TOTAL_LINES" -gt 0 ]; then
  if [ "$LAST_LINE" -eq 0 ]; then
    cp "$TRANSCRIPT_PATH" "$ACTIVE_JSONL"
  elif [ "$TOTAL_LINES" -lt "$LAST_LINE" ]; then
    # Compaction: append full new transcript (preserves pre-compaction data)
    cat "$TRANSCRIPT_PATH" >> "$ACTIVE_JSONL"
  elif [ "$TOTAL_LINES" -gt "$LAST_LINE" ]; then
    NEW_LINES=$((TOTAL_LINES - LAST_LINE))
    tail -n "$NEW_LINES" "$TRANSCRIPT_PATH" >> "$ACTIVE_JSONL"
  fi
fi

# --- M. Update marker ---

if [ "$TOTAL_LINES" -gt 0 ]; then
  echo "$TOTAL_LINES" > "$MARKER_FILE"
fi

# --- N. Finalization (SessionEnd only) ---

# Skip empty sessions: no content was ever exported and nothing to finalize
if [ "$TOTAL_LINES" -eq 0 ] && [ ! -f "$ACTIVE_JSONL" ] && [ ! -f "$ACTIVE_MD" ] && [ ! -f "$ACTIVE_TXT" ]; then
  debug "Empty session, skipping export"
  rm -f "$MARKER_FILE" "$TITLE_FILE"
  exit 0
fi

if [ "$EVENT_TYPE" = "session-end" ] || [ "$EVENT_TYPE" = "session-clear" ]; then
  TIMESTAMP=$(date +"%Y-%m-%d-%H%M")

  if [ "$EVENT_TYPE" = "session-end" ]; then
    SUFFIX="_completed"
  else
    SUFFIX="_cleared"
  fi

  FINAL_JSONL="$EXPORT_DIR/${TIMESTAMP}-${TITLE}${SUFFIX}.jsonl"
  FINAL_MD="$EXPORT_DIR/${TIMESTAMP}-${TITLE}${SUFFIX}.md"
  FINAL_TXT="$EXPORT_DIR/${TIMESTAMP}-${TITLE}${SUFFIX}.txt"

  # Rename active files if they exist
  if [ -f "$ACTIVE_JSONL" ]; then
    if [ "$EVENT_TYPE" = "session-clear" ]; then
      # Append clear marker to existing JSONL
      echo "{\"event\":\"session-clear\",\"timestamp\":\"$(date -Iseconds)\",\"session_id\":\"${SESSION_ID}\"}" >> "$ACTIVE_JSONL"
    fi
    mv "$ACTIVE_JSONL" "$FINAL_JSONL"
    debug "Finalized JSONL: $FINAL_JSONL"
  elif [ "$EVENT_TYPE" = "session-end" ] && [ -n "$TRANSCRIPT_PATH" ] && [ -f "$TRANSCRIPT_PATH" ]; then
    # No active JSONL but transcript exists (fallback)
    cp "$TRANSCRIPT_PATH" "$FINAL_JSONL"
    debug "Copied transcript to JSONL (fallback): $FINAL_JSONL"
  elif [ "$EVENT_TYPE" = "session-clear" ]; then
    # No active JSONL (clear with no prior compact), create minimal marker file
    echo "{\"event\":\"session-clear\",\"timestamp\":\"$(date -Iseconds)\",\"session_id\":\"${SESSION_ID}\"}" > "$FINAL_JSONL"
    debug "Created minimal cleared JSONL: $FINAL_JSONL"
  fi

  if [ -f "$ACTIVE_MD" ]; then
    if [ "$EVENT_TYPE" = "session-clear" ]; then
      {
        echo ""
        echo "---"
        echo "*[Session cleared at $(date '+%H:%M')]*"
      } >> "$ACTIVE_MD"
    fi
    mv "$ACTIVE_MD" "$FINAL_MD"
    debug "Finalized MD: $FINAL_MD"
  elif [ "$EVENT_TYPE" = "session-clear" ]; then
    # No active MD (clear with no prior compact), create minimal file
    {
      echo "# ${TITLE}"
      echo ""
      echo "**Date:** $(date '+%Y-%m-%d %H:%M')"
      echo "**Session:** ${SESSION_ID}"
      echo ""
      echo "---"
      echo "*[Session cleared at $(date '+%H:%M')]*"
    } > "$FINAL_MD"
    debug "Created minimal cleared MD: $FINAL_MD"
  elif [ "$EVENT_TYPE" = "session-end" ] && [ -n "$TRANSCRIPT_PATH" ] && [ -f "$TRANSCRIPT_PATH" ]; then
    # No active MD but transcript exists (fallback for session-end without prior compaction)
    {
      echo "# ${TITLE}"
      echo ""
      echo "**Date:** $(date '+%Y-%m-%d %H:%M')"
      echo "**Session:** ${SESSION_ID}"
      echo ""
      echo "---"
      echo ""
      jq_markdown_filter < "$TRANSCRIPT_PATH" 2>/dev/null || echo "*Could not parse transcript*"
    } > "$FINAL_MD"
    debug "Created MD from transcript (fallback): $FINAL_MD"
  fi

  if [ -f "$ACTIVE_TXT" ]; then
    if [ "$EVENT_TYPE" = "session-end" ]; then
      {
        echo ""
        echo "════════════════════════════════════════════════════════════════"
        echo "Session ended: $(date '+%Y-%m-%d %H:%M')"
        echo "════════════════════════════════════════════════════════════════"
      } >> "$ACTIVE_TXT"
    elif [ "$EVENT_TYPE" = "session-clear" ]; then
      {
        echo ""
        echo "──── [Session cleared at $(date '+%H:%M')] ────"
        echo ""
        echo "════════════════════════════════════════════════════════════════"
        echo "Session cleared: $(date '+%Y-%m-%d %H:%M')"
        echo "════════════════════════════════════════════════════════════════"
      } >> "$ACTIVE_TXT"
    fi
    mv "$ACTIVE_TXT" "$FINAL_TXT"
    debug "Finalized TXT: $FINAL_TXT"
  elif [ "$EVENT_TYPE" = "session-clear" ]; then
    # No active TXT (clear with no prior compact), create minimal file
    {
      echo "════════════════════════════════════════════════════════════════"
      echo "Session: ${TITLE}"
      echo "Date: $(date '+%Y-%m-%d %H:%M')"
      echo "ID: ${SESSION_ID}"
      echo "════════════════════════════════════════════════════════════════"
      echo ""
      echo "──── [Session cleared at $(date '+%H:%M')] ────"
      echo ""
      echo "════════════════════════════════════════════════════════════════"
      echo "Session cleared: $(date '+%Y-%m-%d %H:%M')"
      echo "════════════════════════════════════════════════════════════════"
    } > "$FINAL_TXT"
    debug "Created minimal cleared TXT: $FINAL_TXT"
  elif [ "$EVENT_TYPE" = "session-end" ] && [ -n "$TRANSCRIPT_PATH" ] && [ -f "$TRANSCRIPT_PATH" ]; then
    # No active TXT but transcript exists (fallback for session-end without prior compaction)
    {
      echo "════════════════════════════════════════════════════════════════"
      echo "Session: ${TITLE}"
      echo "Date: $(date '+%Y-%m-%d %H:%M')"
      echo "ID: ${SESSION_ID}"
      echo "════════════════════════════════════════════════════════════════"
      echo ""
      jq_txt_filter < "$TRANSCRIPT_PATH" 2>/dev/null || echo "(Could not parse transcript)"
      echo ""
      echo "════════════════════════════════════════════════════════════════"
      echo "Session ended: $(date '+%Y-%m-%d %H:%M')"
      echo "════════════════════════════════════════════════════════════════"
    } > "$FINAL_TXT"
    debug "Created TXT from transcript (fallback): $FINAL_TXT"
  fi

  # Clean up temp files
  rm -f "$MARKER_FILE" "$TITLE_FILE"
  debug "Cleaned up temp files for session $SESSION_ID"

  # Log the export
  LOG_FILE="$HOME/.claude/export-log.txt"
  echo "$(date '+%Y-%m-%d %H:%M:%S') | ${EVENT_TYPE} | ${FINAL_MD}" >> "$LOG_FILE"
fi

debug "Done: $EVENT_TYPE"
exit 0
