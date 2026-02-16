#!/bin/bash
# Plan Verifier - Automatically audit plans before presenting for approval
# PreToolUse hook that intercepts ExitPlanMode calls
#
# Flow:
#   1st ExitPlanMode call → blocked, verification prompt injected, flag set
#   2nd ExitPlanMode call → flag found, removed, call allowed through
#   If user rejects and Claude revises → next ExitPlanMode triggers verification again
set -e

INPUT=$(cat)

TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // ""')
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // ""')

# Only fire on ExitPlanMode
if [ "$TOOL_NAME" != "ExitPlanMode" ]; then
  exit 0
fi

if [ -z "$SESSION_ID" ]; then
  exit 0
fi

FLAG_FILE="/tmp/claude-plan-verified-${SESSION_ID}"

# Loop prevention: if already verified, allow through and reset flag
if [ -f "$FLAG_FILE" ]; then
  rm -f "$FLAG_FILE"
  exit 0
fi

# Set flag so next ExitPlanMode passes through
touch "$FLAG_FILE"

# Block and inject verification prompt
REASON="PLAN VERIFICATION — Before presenting this plan for approval, audit it against the original request/PRD already in this conversation.

For each major requirement you can infer from the request:
* Mark it **Covered / Partial / Missing**
* Briefly cite *where* it's addressed in the plan (section name or short quote). If you can't point to evidence, treat it as **Partial** or **Missing**.

Then:
1. Give a **coverage score (0–100)** and a 1–2 sentence rationale.
2. List the **top gaps** (missing, partially covered, or unclear assumptions), prioritized by impact.
3. Produce a **patched version of the plan** that closes those gaps with **minimal changes** — preserve the original structure, add/adjust sections rather than rewriting.
4. Write the patched plan to the plan file.
5. Call ExitPlanMode again to present the verified plan."

jq -n --arg reason "$REASON" '{"decision": "block", "reason": $reason}'
