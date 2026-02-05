#!/bin/bash
# Auto-export conversation transcript on session end
# Creates both JSONL transcript and formatted markdown summary
# Exports to [project]/AGENTS/convos/ by default

set -e

# Read JSON input from stdin
INPUT=$(cat)

# Parse fields from hook input
REASON=$(echo "$INPUT" | jq -r '.reason // "unknown"')
TRANSCRIPT_PATH=$(echo "$INPUT" | jq -r '.transcript_path // ""')
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // "unknown"')
CWD=$(echo "$INPUT" | jq -r '.cwd // ""')

# Skip export on logout
if [ "$REASON" = "logout" ]; then
  exit 0
fi

# Validate transcript exists
if [ -z "$TRANSCRIPT_PATH" ] || [ ! -f "$TRANSCRIPT_PATH" ]; then
  exit 0
fi

# Default export directory: ./AGENTS/convos/ from cwd
if [ -n "$CWD" ]; then
  EXPORT_DIR="$CWD/AGENTS/convos"
else
  EXPORT_DIR="$HOME/.claude/exports"
fi

# Create export directory
mkdir -p "$EXPORT_DIR"

# Generate timestamp
TIMESTAMP=$(date +"%Y-%m-%d-%H%M")
SHORT_ID="${SESSION_ID:0:8}"

# Extract first user message for title generation
FIRST_USER_MSG=$(jq -r '
  select(.type == "human") |
  .message.content |
  if type == "array" then
    map(select(.type == "text") | .text) | first // ""
  elif type == "string" then
    .
  else
    ""
  end
' "$TRANSCRIPT_PATH" 2>/dev/null | head -1 | tr -d '\n')

# Clean and truncate for filename (max 50 chars, filename-safe)
TITLE=$(echo "$FIRST_USER_MSG" | \
  sed 's/[^a-zA-Z0-9 ]//g' | \
  tr '[:upper:]' '[:lower:]' | \
  tr ' ' '-' | \
  sed 's/--*/-/g' | \
  sed 's/^-//' | \
  sed 's/-$//' | \
  cut -c1-50)

# Fallback title if extraction failed
if [ -z "$TITLE" ] || [ "$TITLE" = "null" ]; then
  TITLE="session"
fi

# Final filename
BASENAME="${TIMESTAMP}-${TITLE}"
JSONL_FILE="$EXPORT_DIR/${BASENAME}.jsonl"
MD_FILE="$EXPORT_DIR/${BASENAME}.md"

# Copy transcript
cp "$TRANSCRIPT_PATH" "$JSONL_FILE"

# Generate markdown summary with improved formatting
{
  echo "# ${TITLE}"
  echo ""
  echo "**Date:** $(date '+%Y-%m-%d %H:%M')"
  echo "**Session:** ${SESSION_ID}"
  echo ""
  echo "---"
  echo ""

  # Process messages with better formatting
  jq -r '
    if .type == "human" then
      # User message
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
      # Assistant message with tool uses
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
      # Tool results
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
  ' "$TRANSCRIPT_PATH" 2>/dev/null || echo "*Could not parse transcript*"

} > "$MD_FILE"

# Log the export
LOG_FILE="$HOME/.claude/export-log.txt"
echo "$(date '+%Y-%m-%d %H:%M:%S') | $REASON | $MD_FILE" >> "$LOG_FILE"

exit 0
