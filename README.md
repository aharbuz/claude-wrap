# claude-wrap

Bash hooks and skills for automating Claude Code CLI workflows.

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
└── my-task-8372a64f.{jsonl,md}                  # active (mid-session)
```

**How it works:**

| Hook | When | What happens |
|------|------|-------------|
| `PreCompact` | Before each context compaction | Appends only new lines since last checkpoint |
| `SessionEnd` | Normal exit (`/exit`, Ctrl+D) | Appends remaining lines, renames with timestamp + `_completed` suffix |
| `SessionEnd` | `/clear` | Skips content, creates JSONL clear marker, renames with `_cleared` suffix |
| `SessionEnd` | Logout | Skipped entirely |

### Context Guard

Monitors real context window usage from API token counts and nudges wrap-up at thresholds:

- **60-69%**: Warn — finish current task, start preparing handoff
- **70%+**: Critical — strongest warning, save work immediately

At 60%+, Claude writes a continuation prompt to `AGENTS/.convos/continue/[timestamp]-CONTINUE.md` so you can resume in a fresh session:

```bash
# Resume with the latest continuation prompt
claude -p "$(cat "$(ls -t AGENTS/.convos/continue/*-CONTINUE.md | head -1)")"
```

Uses debounced parsing (every 30 seconds) of actual API token counts from the transcript.

### Wrap-Up Skill (`/wrap-up`)

User-triggered session wrap-up. Replaces the previous automatic Stop hook, which was too jumpy — it fired on sub-task completions when the user intended to continue working.

The user says `/wrap-up` and Claude runs through the wrap-up steps: update docs, write continuation prompt, commit, push.

Context guard (60%+) still handles automatic wrap-up nudges and mentions `/wrap-up` so Claude knows the explicit command exists.

### Plan Verifier

Automatically audits plans against the original request before presenting them for approval. A PreToolUse hook intercepts `ExitPlanMode` — the first call is blocked while Claude performs a coverage audit (requirement-by-requirement scoring, gap analysis, plan patching), then the second call is allowed through with the verified plan. Resets on each revision cycle so rejected plans get re-verified.

### Prefer pnpm

A PreToolUse hook that blocks `npm` commands and suggests `pnpm` equivalents.

- **Blocks**: `npm install`, `npm run`, `npm test`, `npm init`, etc.
- **Allows**: `npx` (not blocked since `pnpm dlx` isn't always a drop-in)
- **Allows**: `pnpm` commands pass through untouched

## Installation

### 1. Install the hooks

```bash
# Clone or download this repo
git clone https://github.com/aharbuz/claude-wrap.git
cd claude-wrap

# Copy hooks to Claude config
cp hooks/export-session.sh ~/.claude/hooks/
cp hooks/context-guard.sh ~/.claude/hooks/
cp hooks/plan-verifier.sh ~/.claude/hooks/
cp hooks/prefer-pnpm.sh ~/.claude/hooks/
chmod +x ~/.claude/hooks/*.sh
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
          },
          {
            "type": "command",
            "command": "bash \"$HOME/.claude/hooks/plan-verifier.sh\"",
            "timeout": 10
          },
          {
            "type": "command",
            "command": "bash \"$HOME/.claude/hooks/prefer-pnpm.sh\"",
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

### 3. Install the wrap-up skill (optional)

The `/wrap-up` skill lives at `~/.claude/skills/wrap-up/SKILL.md`. See the [wrap-up skill docs](CLAUDE.md#wrap-up-skill-wrap-up) for setup.

### 4. Use it

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

## Structure

```
claude-wrap/
├── hooks/
│   ├── export-session.sh    # PreCompact + SessionEnd hook script
│   ├── context-guard.sh     # PreToolUse/PostToolUse context monitor
│   ├── plan-verifier.sh     # PreToolUse - plan audit before approval
│   ├── prefer-pnpm.sh       # PreToolUse - block npm, suggest pnpm
│   └── stop-wrapup.sh       # Retired - replaced by /wrap-up skill
├── AGENTS/
│   └── .convos/              # Exported conversations (gitignored)
├── CLAUDE.md
└── .gitignore
```

## Debugging

Check `/tmp/claude-export-debug.log` for detailed trace output from the export hook.

## Gitignore

Add to your project's `.gitignore`:

```
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
