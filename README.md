# claude-wrap

Bash hooks for automating Claude Code CLI workflows.

## Features

### 🔄 Auto-Export on Session End

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

## Installation

### 1. Install the hook

```bash
# Clone or download this repo
git clone https://github.com/aharbuz/claude-wrap.git
cd claude-wrap

# Copy hook to Claude config
cp hooks/export-session.sh ~/.claude/hooks/
chmod +x ~/.claude/hooks/export-session.sh
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
    ]
  }
}
```

### 3. Use it

Just work normally in Claude Code. When you end a session (Ctrl+D or `/exit`), conversations auto-export to:
- `./AGENTS/convos/{timestamp}-{title}.jsonl`
- `./AGENTS/convos/{timestamp}-{title}.md`

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
