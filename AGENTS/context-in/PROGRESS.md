# claude-wrap Progress

## 2026-02-16 - Stop Wrap-Up hook

Added `hooks/stop-wrapup.sh` — a Stop hook that detects when Claude finishes meaningful work and injects wrap-up instructions (update docs, continuation prompt, commit, push).

### What was done
- Created `hooks/stop-wrapup.sh` with 5 guards:
  - Loop prevention (`stop_hook_active == true`)
  - Short conversation (< 6 transcript lines)
  - No recent file changes (no Write/Edit in last ~50 lines)
  - Mid-work detection (last assistant message has tool_use)
  - Already committed (recent `git commit` in last ~30 lines)
- When all guards pass, blocks stop and injects wrap-up steps (docs, continuation prompt, commit, push)
- Installed to `~/.claude/hooks/stop-wrapup.sh`
- Added Stop hook entry to `~/.claude/settings.json`
- Updated `CLAUDE.md` with documentation, guards table, setup instructions
- Updated `README.md` with feature description and install step

## 2026-02-16 - Plan Verifier hook

Added `hooks/plan-verifier.sh` — a PreToolUse hook that automatically audits plans against the original request before presenting them for approval.

### What was done
- Created `hooks/plan-verifier.sh` — intercepts `ExitPlanMode` calls
  - First call: blocks and injects verification prompt (coverage scoring, gap analysis, plan patching)
  - Second call: flag file consumed, call allowed through
  - Resets on each revision cycle (user rejects → next ExitPlanMode triggers verification again)
  - Uses `/tmp/claude-plan-verified-{SESSION_ID}` flag file
- Updated `CLAUDE.md` with plan-verifier documentation, setup instructions, and hook interaction notes
- Updated structure section to include the new hook file

## 2026-02-06 - Context Guard verification

Verified the context-guard hook is fully installed and working across all sessions.

### What was done
- Confirmed hook is registered in `~/.claude/settings.json` for both PreToolUse and PostToolUse
- Confirmed `~/.claude/hooks/context-guard.sh` exists and is executable
- Found 11 active state files in `/tmp/`, proving the hook runs on every session
- Simulated all three thresholds with mock transcripts:
  - **50%** PostToolUse: soft warning ("start wrapping up") — exit 0
  - **65%** PostToolUse: urgent warning ("wrap up NOW") — exit 0
  - **75%** PostToolUse: hard stop message ("STOP. Save progress immediately") — exit 0
  - **75%** PreToolUse + Read: **blocked** (exit 2)
  - **75%** PreToolUse + Write: **allowed** (exit 0)
- All thresholds and tool-blocking behavior confirmed correct

## 2026-02-06 - Continuation prompt on context wrap-up

Added auto-handoff: at 60%+ context, Claude is instructed to write `AGENTS/handoff.md` with a continuation prompt (what was done, current state, next steps, key files). Users can resume with `claude -p "$(cat AGENTS/handoff.md)"`.

### What was done
- Updated PostToolUse messages in `context-guard.sh` at all three thresholds to reference `AGENTS/handoff.md`
- Updated `CLAUDE.md` with handoff documentation and resume command
- Updated `README.md` with continuation prompt feature

## 2026-02-06 - Context Guard hook

Added `hooks/context-guard.sh` — monitors real context window usage via API token counts from the transcript and manages session wrap-up.

### What was done
- Created `hooks/context-guard.sh` handling both PreToolUse and PostToolUse events
  - Parses `input_tokens + cache_creation_input_tokens + cache_read_input_tokens` from last assistant message
  - Computes percentage against 200k context window
  - PostToolUse: injects `systemMessage` warnings at 45%/60%/70% tiers
  - PreToolUse: blocks non-essential tools at 70%+ (exit 2), allows Write/Edit/Bash/TaskUpdate/TaskCreate
  - Debounces with `/tmp/` state files (30-second cache)
  - macOS-compatible (uses `tail` not `tac`)
- Updated `~/.claude/settings.json` with PreToolUse and PostToolUse hook entries
- Updated `CLAUDE.md` and `README.md` with context guard docs and setup instructions
- Installed hook to `~/.claude/hooks/`

### Also included
- Pre-existing fix in `export-session.sh`: added `"user"` type alongside `"human"` for message parsing

### Verified
- Transcript parsing produces correct percentage (tested at 51%)
- Warning messages fire at correct tiers
- Tool blocking works (Read blocked, Write allowed at hard threshold)
- Graceful no-op when transcript missing or below threshold

## 2026-02-05 - Initial setup

- Created `hooks/export-session.sh` — auto-exports conversations on session end
- Set up repo structure, CLAUDE.md, README.md, .gitignore
