# claude-wrap

Bash wrapper and hooks for automating Claude Code CLI workflows.

## Features

### Auto-Export on Session End

Automatically exports conversations when sessions end:

- **JSONL export**: Raw conversation data at `AGENTS/convos/{timestamp}-{title}.jsonl`
- **Markdown summary**: Formatted conversation at `AGENTS/convos/{timestamp}-{title}.md`
- **Smart titles**: Derived from first user message
- **Per-project**: Exports to `./AGENTS/convos/` from working directory

**Setup**: SessionEnd hook at `~/.claude/hooks/export-session.sh`

**Format**:
- Conversation flow with User/Claude headers
- Tool uses: `🔧 ToolName` with JSON inputs
- Tool results in code blocks
- Session metadata (date, ID, exit reason)

## Structure

```
claude-wrap/
├── AGENTS/
│   └── convos/          # Exported conversations (gitignored)
├── CLAUDE.md            # This file
└── .gitignore
```

## Related

- Feature request: [--export-on-exit flag](https://github.com/anthropics/claude-code/issues/23308)
- Feature request: [--context CLI flag](https://github.com/anthropics/claude-code/issues/18664)
