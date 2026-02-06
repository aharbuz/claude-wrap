# claude-wrap

Bash hooks for automating Claude Code CLI workflows.

## Features

### Auto-Export on Session End

Automatically exports conversations when sessions end to `./AGENTS/convos/`:

- **JSONL export**: Raw conversation data for reprocessing
- **Markdown summary**: Formatted conversation with tool uses and results
- **Smart titles**: Filenames derived from first user message
- **Per-project**: Exports to working directory's `AGENTS/convos/`

**Example output:**
```
AGENTS/convos/
├── 2026-02-05-1145-auto-export-hooks-setup.jsonl
└── 2026-02-05-1145-auto-export-hooks-setup.md
```

### Context Guard

Monitors real context window usage and manages session wrap-up:

- **45%**: Warns Claude to start wrapping up
- **60%**: Urgently tells Claude to save progress and write a continuation prompt
- **70%**: Blocks non-essential tools (Read, Grep, WebSearch, etc.) while still allowing Write, Edit, and Bash for saving work

At 60%+, Claude writes a continuation prompt to `AGENTS/handoff.md` so you can resume in a fresh session:

```bash
claude -p "$(cat AGENTS/handoff.md)"
```

Uses actual API token counts from the transcript — no guessing.

## Installation

### 1. Install the hook

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

Just work normally in Claude Code. When you end a session (Ctrl+D or `/exit`):
- Conversations export to `./AGENTS/convos/{timestamp}-{title}.jsonl`
- Formatted markdown at `./AGENTS/convos/{timestamp}-{title}.md`

## Markdown Format

The markdown export includes:

- **Title**: Derived from first user message
- **Metadata**: Date, session ID, exit reason
- **Conversation flow**: Clear User/Claude headers
- **Tool uses**: `🔧 ToolName` with JSON inputs
- **Tool results**: In code blocks

## Gitignore

Add to your project's `.gitignore`:

```
# Session exports
AGENTS/convos/
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
