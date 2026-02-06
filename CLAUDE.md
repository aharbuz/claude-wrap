# claude-wrap

Bash wrapper and hooks for automating Claude Code CLI workflows.

## Features

### Auto-Export on Session End

Automatically exports conversations when sessions end:

- **JSONL export**: Raw conversation data at `AGENTS/convos/{timestamp}-{title}.jsonl`
- **Markdown summary**: Formatted conversation at `AGENTS/convos/{timestamp}-{title}.md`
- **Smart titles**: Derived from first user message
- **Per-project**: Exports to `./AGENTS/convos/` from working directory

**Setup**:

1. Copy hook to Claude config:
   ```bash
   cp hooks/export-session.sh ~/.claude/hooks/
   chmod +x ~/.claude/hooks/export-session.sh
   ```

2. Add to `~/.claude/settings.json`:
   ```json
   "hooks": {
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
- Session metadata (date, ID, exit reason)

### Context Guard

Monitors real context usage from API token counts and nudges/forces wrap-up at thresholds:

- **45-59%**: Warn - finish current task, start preparing handoff
- **60-69%**: Urgent - wrap up NOW, save progress
- **70%+**: Hard stop - blocks non-essential tools, forces immediate session end

**How it works**:
- **PostToolUse**: Injects `systemMessage` warnings into Claude's context at each threshold
- **PreToolUse**: At 70%+, blocks tools like Read, Glob, Grep, WebSearch (exit 2) while allowing Write, Edit, Bash, TaskUpdate, TaskCreate for saving work
- **Debouncing**: Caches usage in `/tmp/` state files, re-parses transcript only every 30 seconds

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
│   ├── export-session.sh    # SessionEnd hook script
│   └── context-guard.sh     # PreToolUse/PostToolUse context monitor
├── AGENTS/
│   └── convos/              # Exported conversations (gitignored)
├── CLAUDE.md                # This file
└── .gitignore
```

## Related

- Feature request: [--export-on-exit flag](https://github.com/anthropics/claude-code/issues/23308)
- Feature request: [--context CLI flag](https://github.com/anthropics/claude-code/issues/18664)
