# claude-wrap

Bash wrapper and hooks for automating Claude Code CLI workflows.

## Features

### Auto-Export with Crash Protection (PreCompact + SessionEnd)

Incrementally exports conversations during the session (on compaction) and finalizes on session end. If a session crashes mid-way, the partial export is already on disk.

- **Incremental**: PreCompact hook appends only new lines since last checkpoint
- **Compaction-aware**: Detects transcript rewrites and processes the new compacted transcript
- **JSONL export**: Raw conversation data at `AGENTS/.convos/{timestamp}-{title}_completed.jsonl`
- **Markdown summary**: Formatted conversation at `AGENTS/.convos/{timestamp}-{title}_completed.md`
- **Smart titles**: Derived from first user message, persisted across hook invocations
- **Per-project**: Exports to `./AGENTS/.convos/` from working directory

**How it works:**

| Event | Action |
|-------|--------|
| PreCompact | Append only new lines since last checkpoint to active session files |
| SessionEnd (normal) | Append remaining lines (or create from transcript if no prior compaction), rename files with timestamp, clean up |
| SessionEnd (clear) | Skip content processing, create JSONL clear marker, finalize files with `_cleared` suffix, clean up |
| SessionEnd (logout) | Skip entirely |

**Active vs finalized files:**
- During session: `{title}-{short_session_id}.{jsonl,md}` (no timestamp)
- On session end: renamed to `{YYYY-MM-DD-HHMM}-{title}_completed.{jsonl,md}`
- On `/clear`: renamed to `{YYYY-MM-DD-HHMM}-{title}_cleared.{jsonl,md}`

**Compaction handling:**
- Detected when transcript line count shrinks (line count < last checkpoint)
- Full new transcript is processed and appended with a `--- *[Compacted at HH:MM]*` separator in markdown
- JSONL preserves both pre-compaction detail and post-compaction summary

**Temp files** (per session, cleaned up on session end):
- `/tmp/claude-export-{SESSION_ID}-lastline` - last processed line count
- `/tmp/claude-export-{SESSION_ID}-title` - persisted title
- Debug log: `/tmp/claude-export-debug.log`

**Setup**:

1. Copy hook to Claude config:
   ```bash
   cp hooks/export-session.sh ~/.claude/hooks/
   chmod +x ~/.claude/hooks/export-session.sh
   ```

2. Add to `~/.claude/settings.json`:
   ```json
   "hooks": {
     "PreCompact": [
       {
         "hooks": [
           {
             "type": "command",
             "command": "bash \"$HOME/.claude/hooks/export-session.sh\"",
             "timeout": 30
           }
         ]
       }
     ],
     "SessionEnd": [
       {
         "hooks": [
           {
             "type": "command",
             "command": "bash \"$HOME/.claude/hooks/export-session.sh\"",
             "timeout": 30
           }
         ]
       }
     ]
   }
   ```

**Markdown export format**:
- Conversation flow with User/Claude headers
- Tool uses: `🔧 ToolName` with JSON inputs
- Tool results in code blocks
- Session metadata (date, ID)
- Compaction separators between segments

### Context Guard

Monitors real context usage from API token counts and nudges/forces wrap-up at thresholds:

- **60-69%**: Warn - finish current task, start preparing handoff
- **70%+**: Critical - strongest warning, save work immediately (no tool blocking)

**How it works**:
- **PostToolUse**: Injects `systemMessage` warnings into Claude's context at each threshold
- **PreToolUse**: At 70%+, injects critical-urgency warning (no tool blocking)
- **Debouncing**: Caches usage in `/tmp/` state files, re-parses transcript only every 30 seconds
- **Handoff**: At 60%+, instructs Claude to write `AGENTS/.convos/continue/[timestamp]-CONTINUE.md` — a continuation prompt that can be used to resume in a fresh session

**Continuation prompt** (`AGENTS/.convos/continue/[timestamp]-CONTINUE.md`):

When context runs high, Claude writes a continuation file containing:
1. Summary of what was accomplished
2. Current state and any issues
3. Concrete next steps
4. Key file paths

Resume a fresh session with:
```bash
# Resume with the latest continuation prompt
claude -p "$(cat "$(ls -t AGENTS/.convos/continue/*-CONTINUE.md | head -1)")"

# Or specify the exact file
claude -p "$(cat AGENTS/.convos/continue/2026-02-11-1445-CONTINUE.md)"
```

**Setup** (in addition to export hook):

1. Copy hook to Claude config:
   ```bash
   cp hooks/context-guard.sh ~/.claude/hooks/
   chmod +x ~/.claude/hooks/context-guard.sh
   ```

2. Add to `~/.claude/settings.json` (alongside existing hooks):
   ```json
   "PreToolUse": [
     {
       "hooks": [
         {
           "type": "command",
           "command": "bash \"$HOME/.claude/hooks/context-guard.sh\"",
           "timeout": 10
         }
       ]
     }
   ],
   "PostToolUse": [
     {
       "hooks": [
         {
           "type": "command",
           "command": "bash \"$HOME/.claude/hooks/context-guard.sh\"",
           "timeout": 10
         }
       ]
     }
   ]
   ```

### Stop Wrap-Up

Automatically detects when Claude finishes meaningful work and injects wrap-up instructions (update docs, write continuation prompt, commit, push) before the session ends.

**How it works**:

The hook fires every time Claude stops responding. It runs through 5 guards:

| Guard | Check | If triggered |
|-------|-------|-------------|
| **Loop prevention** | `stop_hook_active == true` | Allow stop (wrap-up already injected) |
| **Short conversation** | < 6 transcript lines | Allow stop (just a quick Q&A) |
| **Re-trigger prevention** | No new Write/Edit since last wrap-up trigger | Allow stop (still discussing, no new edits) |
| **No recent file changes** | No Write/Edit in last ~50 lines | Allow stop (no work to commit) |
| **Last response is tool-heavy** | Last assistant message has tool_use | Allow stop (still mid-work) |
| **Already committed** | Recent `git commit` in last ~30 lines | Allow stop (already wrapped up) |

If all guards pass → blocks the stop and injects self-contained wrap-up instructions as the `reason`.

Guards 3 and 4 together detect "finished meaningful work": recent file edits + last response was a text summary (not a tool use) = Claude just finished a chunk of work and is presenting results.

The re-trigger prevention guard tracks the transcript line where wrap-up last fired. Subsequent stops only re-trigger if there are NEW Write/Edit calls after that point, preventing repeated wrap-up prompts during back-and-forth debugging or discussion. The state resets if the transcript is compacted.

**Wrap-up steps injected**:
1. Update docs (PROGRESS.md, README if structure changed, others per CLAUDE.md)
2. Write continuation prompt if more planned work remains
3. Commit uncommitted changes
4. Push if remote is configured

**Interaction with other hooks**:
- **Context guard**: If context-guard already urged wrap-up and Claude committed, Guard 5 catches the recent commit and defers
- **Bash-only work**: Won't trigger (Guard 3 checks for Write/Edit only) — intentional since Bash-only sessions rarely need doc updates
- **Non-git projects**: Wrap-up instructions handle gracefully ("if this is a git repo")

**Temp files**:
- `/tmp/claude-stop-wrapup-{SESSION_ID}` — transcript line of last wrap-up trigger (for re-trigger prevention)

**Setup**:

1. Copy hook to Claude config:
   ```bash
   cp hooks/stop-wrapup.sh ~/.claude/hooks/
   chmod +x ~/.claude/hooks/stop-wrapup.sh
   ```

2. Add to `~/.claude/settings.json` (alongside existing hooks):
   ```json
   "Stop": [
     {
       "hooks": [
         {
           "type": "command",
           "command": "bash \"$HOME/.claude/hooks/stop-wrapup.sh\"",
           "timeout": 15
         }
       ]
     }
   ]
   ```

### Plan Verifier

Automatically audits plans against the original request before presenting them for approval. Eliminates the need to manually paste a verification prompt after every planning session.

**How it works**:

A PreToolUse hook intercepts `ExitPlanMode` calls:

| Call | Action |
|------|--------|
| 1st `ExitPlanMode` | Blocked — verification prompt injected, flag file set |
| Claude audits | Coverage analysis, gap identification, plan patching |
| 2nd `ExitPlanMode` | Flag found — removed, call allowed through |

If the user rejects the plan and Claude revises, the next `ExitPlanMode` triggers verification again (the flag was consumed on the previous pass).

**Verification steps injected**:
1. Mark each requirement as Covered / Partial / Missing with citations
2. Coverage score (0–100) with rationale
3. Top gaps prioritized by impact
4. Patched plan written to plan file (minimal changes, preserve structure)

**Temp files**:
- `/tmp/claude-plan-verified-{SESSION_ID}` — one-shot flag file (created on block, removed on allow)

**Setup**:

1. Copy hook to Claude config:
   ```bash
   cp hooks/plan-verifier.sh ~/.claude/hooks/
   chmod +x ~/.claude/hooks/plan-verifier.sh
   ```

2. Add to `~/.claude/settings.json` — chain with existing PreToolUse hooks:
   ```json
   "PreToolUse": [
     {
       "hooks": [
         {
           "type": "command",
           "command": "bash \"$HOME/.claude/hooks/context-guard.sh\"",
           "timeout": 10
         },
         {
           "type": "command",
           "command": "bash \"$HOME/.claude/hooks/plan-verifier.sh\"",
           "timeout": 10
         }
       ]
     }
   ]
   ```

**Interaction with other hooks**:
- **Context guard**: Both run as PreToolUse hooks — context-guard checks context usage, plan-verifier checks for ExitPlanMode. They don't conflict since plan-verifier exits early for non-ExitPlanMode tools.
- **Stop wrap-up**: Plan verification happens during active work, well before stop conditions are met.

## Structure

```
claude-wrap/
├── hooks/
│   ├── export-session.sh    # PreCompact + SessionEnd hook script
│   ├── context-guard.sh     # PreToolUse/PostToolUse context monitor
│   ├── stop-wrapup.sh       # Stop hook - automated wrap-up
│   └── plan-verifier.sh     # PreToolUse - plan audit before approval
├── AGENTS/
│   └── .convos/              # Exported conversations (gitignored)
├── CLAUDE.md                # This file
└── .gitignore
```

## Related

- Feature request: [--export-on-exit flag](https://github.com/anthropics/claude-code/issues/23308)
- Feature request: [--context CLI flag](https://github.com/anthropics/claude-code/issues/18664)
