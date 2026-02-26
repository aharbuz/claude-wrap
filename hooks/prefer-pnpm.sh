#!/bin/bash
# PreToolUse hook: Prefer pnpm over npm
# Blocks npm commands and suggests pnpm equivalents.
# Allows npx through since pnpm dlx isn't always a drop-in.

INPUT=$(cat)

TOOL=$(echo "$INPUT" | jq -r '.tool_name // empty')
[ "$TOOL" = "Bash" ] || exit 0

COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty')
[ -n "$COMMAND" ] || exit 0

# Extract the first token (handles leading whitespace, env vars, etc.)
# Match npm as standalone command at the start of the command string
if echo "$COMMAND" | grep -qE '(^|[;&|]\s*)npm\s'; then
  # Extract the npm subcommand for a helpful suggestion
  NPM_SUB=$(echo "$COMMAND" | grep -oE 'npm\s+[a-z-]+' | head -1)
  SUB_ONLY="${NPM_SUB#npm }"

  echo "Blocked: Use pnpm instead of npm. Replace '$NPM_SUB' with 'pnpm $SUB_ONLY'." >&2
  exit 2
fi

exit 0
