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

### Wrap-Up Skill (`/wrap-up`)

User-triggered session wrap-up. Replaces the previous automatic Stop hook, which was too jumpy — it fired on sub-task completions when the user intended to continue working. Also replaces the retired context-guard hook, which used to nudge wrap-up automatically at high context usage; that hook was removed for the same reason as the Stop hook — too jumpy — so wrap-up is now purely user-triggered.

**How it works**: The user says `/wrap-up` (or "wrap up", "end session", "let's wrap up") and Claude runs through the wrap-up steps: update docs, write continuation prompt, commit, push.

**Tradeoff**: Sessions that end without `/wrap-up` won't get automatic doc updates or commits. The work is still on disk (SessionEnd export captures the conversation), just not committed. This is acceptable — false-positive interruptions from the old Stop hook and context-guard nudges were worse.

**Setup**:

The skill file lives at `~/.claude/skills/wrap-up/SKILL.md`. No hook configuration needed.

If you previously had a Stop hook in `~/.claude/settings.json`, remove the `"Stop"` section:
```json
// REMOVE this from settings.json:
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
           "command": "bash \"$HOME/.claude/hooks/plan-verifier.sh\"",
           "timeout": 10
         }
       ]
     }
   ]
   ```

**Interaction with other hooks**:
- **Wrap-up skill**: Plan verification happens during active work, before the user triggers `/wrap-up`.

### Prefer pnpm

A PreToolUse hook that blocks `npm` commands and suggests `pnpm` equivalents. Enforces the global CLAUDE.md preference for pnpm over npm.

- **Blocks**: `npm install`, `npm run`, `npm test`, `npm init`, etc.
- **Allows**: `npx` (not blocked since `pnpm dlx` isn't always a drop-in)
- **Allows**: `pnpm` commands pass through untouched

**Setup**:

1. Copy hook to Claude config:
   ```bash
   cp hooks/prefer-pnpm.sh ~/.claude/hooks/
   chmod +x ~/.claude/hooks/prefer-pnpm.sh
   ```

2. Add to `~/.claude/settings.json` — chain with existing PreToolUse hooks:
   ```json
   "PreToolUse": [
     {
       "hooks": [
         {
           "type": "command",
           "command": "bash \"$HOME/.claude/hooks/prefer-pnpm.sh\"",
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
│   ├── stop-wrapup.sh       # Retired - replaced by /wrap-up skill
│   ├── plan-verifier.sh     # PreToolUse - plan audit before approval
│   └── prefer-pnpm.sh      # PreToolUse - block npm, suggest pnpm
├── AGENTS/
│   └── .convos/              # Exported conversations (gitignored)
├── CLAUDE.md                # This file
└── .gitignore
```

## Related

- Feature request: [--export-on-exit flag](https://github.com/anthropics/claude-code/issues/23308)
- Feature request: [--context CLI flag](https://github.com/anthropics/claude-code/issues/18664)
