# claude-wrap

Bash hooks for automating Claude Code CLI workflows.

## Features

### Auto-Export with Crash Protection

Incrementally exports conversations during the session and finalizes on session end. Uses the `PreCompact` hook to save progress before each compaction, so if a long session crashes, the partial export is already on disk.

- **Incremental export**: Only new lines are processed on each compaction
- **Compaction-aware**: Detects transcript rewrites and handles them gracefully
- **JSONL export**: Raw conversation data for reprocessing
- **Markdown summary**: Formatted conversation with tool uses and results
- **Smart titles**: Filenames derived from first user message
- **Per-project**: Exports to working directory's `AGENTS/.convos/`

**Example output:**
```
AGENTS/.convos/
├── 2026-02-05-1145-auto-export-hooks-setup_completed.jsonl
├── 2026-02-05-1145-auto-export-hooks-setup_completed.md
├── 2026-02-05-1300-quick-fix_cleared.md        # from /clear
└── my-task-8372a64f.md                          # active (mid-session)
```

**How it works:**

| Hook | When | What happens |
|------|------|-------------|
| `PreCompact` | Before each context compaction | Appends only new lines since last checkpoint |
| `SessionEnd` | Normal exit (`/exit`, Ctrl+D) | Appends remaining lines, renames with timestamp + `_completed` suffix |
| `SessionEnd` | `/clear` | Skips content, renames with `_cleared` suffix |
| `SessionEnd` | Logout | Skipped entirely |

### Context Guard

Monitors real context window usage and manages session wrap-up:

- **45%**: Warns Claude to start wrapping up
- **60%**: Urgently tells Claude to save progress and write a continuation prompt
- **70%**: Blocks non-essential tools (Read, Grep, WebSearch, etc.) while still allowing Write, Edit, and Bash for saving work

At 60%+, Claude writes a continuation prompt to `AGENTS/.convos/continue/[timestamp]-CONTINUE.md` so you can resume in a fresh session:

```bash
# Resume with the latest continuation prompt
claude -p "$(cat "$(ls -t AGENTS/.convos/continue/*-CONTINUE.md | head -1)")"

# Or specify the exact file
claude -p "$(cat AGENTS/.convos/continue/2026-02-11-1445-CONTINUE.md)"
```

Uses actual API token counts from the transcript.

## Installation

### 1. Install the hooks

```bash
# Clone or download this repo
git clone https://github.com/aharbuz/claude-wrap.git
cd claude-wrap

# Copy hooks to Claude config
cp hooks/export-session.sh ~/.claude/hooks/
cp hooks/context-guard.sh ~/.claude/hooks/
chmod +x ~/.claude/hooks/export-session.sh ~/.claude/hooks/context-guard.sh
```

### 2. Configure Claude Code

Add to `~/.claude/settings.json`:

```json
{
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
    ],
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
  }
}
```

### 3. Use it

Just work normally in Claude Code. Conversations are exported incrementally during compaction and finalized when you end the session:
- Active files (mid-session): `./AGENTS/.convos/{title}-{session_id}.{jsonl,md}`
- Completed: `./AGENTS/.convos/{timestamp}-{title}_completed.{jsonl,md}`
- Cleared: `./AGENTS/.convos/{timestamp}-{title}_cleared.{jsonl,md}`

## Markdown Format

The markdown export includes:

- **Title**: Derived from first user message
- **Metadata**: Date, session ID
- **Conversation flow**: Clear User/Claude headers
- **Tool uses**: `🔧 ToolName` with JSON inputs
- **Tool results**: In code blocks
- **Compaction markers**: `--- *[Compacted at HH:MM]*` separators between segments

## Debugging

Check `/tmp/claude-export-debug.log` for detailed trace output from the export hook. Each invocation logs event type, line counts, compaction detection, and file operations.

## Gitignore

Add to your project's `.gitignore`:

```
# Session exports and continuation prompts
AGENTS/.convos/
```

## Related

This repo provides a working solution while we wait for native CLI support:

- Feature request: [--export-on-exit flag](https://github.com/anthropics/claude-code/issues/23308)
- Feature request: [--context CLI flag](https://github.com/anthropics/claude-code/issues/18664)

## Requirements

- [Claude Code](https://github.com/anthropics/claude-code) v2.1.31+
- `jq` for JSON processing
- Bash

## License

MIT
