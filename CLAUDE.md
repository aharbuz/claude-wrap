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
| SessionEnd (normal) | Append remaining lines, rename files with timestamp, clean up |
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

- **50-65%**: Warn - finish current task, start preparing handoff
- **66-75%**: Urgent - wrap up NOW, save progress
- **76%+**: Hard stop - blocks non-essential tools, forces immediate session end

**How it works**:
- **PostToolUse**: Injects `systemMessage` warnings into Claude's context at each threshold
- **PreToolUse**: At 70%+, blocks tools like Read, Glob, Grep, WebSearch (exit 2) while allowing Write, Edit, Bash, TaskUpdate, TaskCreate for saving work
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

## Structure

```
claude-wrap/
├── hooks/
│   ├── export-session.sh    # PreCompact + SessionEnd hook script
│   └── context-guard.sh     # PreToolUse/PostToolUse context monitor
├── AGENTS/
│   └── .convos/              # Exported conversations (gitignored)
├── CLAUDE.md                # This file
└── .gitignore
```

## Related

- Feature request: [--export-on-exit flag](https://github.com/anthropics/claude-code/issues/23308)
- Feature request: [--context CLI flag](https://github.com/anthropics/claude-code/issues/18664)
