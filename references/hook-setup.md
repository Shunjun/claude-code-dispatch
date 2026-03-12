# Hook Setup Guide

The Claude Code Dispatch skill relies on Claude Code's **hook system** to automatically notify you when tasks complete.

## Hook Events Used

| Event | Purpose |
|-------|---------|
| `Stop` | Primary: fires when Claude finishes responding |
| `TaskCompleted` | Enhanced: fires when a task is explicitly marked complete (Agent Teams) |
| `SessionEnd` | Fallback: fires when session terminates |

The `notify-agi.sh` script handles all three events with built-in deduplication (`.hook-lock`, 30s window).

## Setup

### 1. Copy the hook script

```bash
mkdir -p ~/.claude/hooks
cp scripts/notify-agi.sh ~/.claude/hooks/
chmod +x ~/.claude/hooks/notify-agi.sh
```

### 2. Configure hooks in settings.json

Edit `~/.claude/settings.json` and add the hooks configuration:

```json
{
  "hooks": {
    "Stop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "~/.claude/hooks/notify-agi.sh"
          }
        ]
      }
    ],
    "TaskCompleted": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "~/.claude/hooks/notify-agi.sh"
          }
        ]
      }
    ],
    "SessionEnd": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "~/.claude/hooks/notify-agi.sh"
          }
        ]
      }
    ]
  }
}
```

### 3. Verify

```bash
# Check settings
cat ~/.claude/settings.json | jq '.hooks'

# Test a dispatch
nohup bash scripts/dispatch.sh \
  -p "echo hello world" \
  -n "test-hook" \
  --permission-mode bypassPermissions \
  > /tmp/test-dispatch.log 2>&1 &

# Watch the hook log
tail -f data/claude-code-results/hook.log
```

## Hook Input (JSON via stdin)

All events receive JSON with these common fields:

```json
{
  "session_id": "abc123",
  "transcript_path": "/home/user/.claude/projects/.../transcript.jsonl",
  "cwd": "/home/user/my-project",
  "permission_mode": "bypassPermissions",
  "hook_event_name": "Stop"
}
```

## Hook Event Details

### Stop
- Fires when Claude finishes a response turn
- Most common trigger for task completion
- No matcher support (fires on every stop)

### TaskCompleted
- Fires when a task is explicitly marked as completed
- More precise than Stop for Agent Teams workflows
- Can be blocked (exit code 2) to prevent premature completion
- No matcher support

### SessionEnd
- Fires when session terminates
- Matchers: `clear`, `logout`, `prompt_input_exit`, `bypass_permissions_disabled`, `other`
- Used as fallback; deduplication prevents double notifications

## Alternative: HTTP Hooks

Instead of a shell script, you can send task completion events to an HTTP endpoint:

```json
{
  "hooks": {
    "Stop": [
      {
        "hooks": [
          {
            "type": "http",
            "url": "http://localhost:8080/hooks/task-complete",
            "timeout": 30,
            "headers": {
              "Authorization": "Bearer $WEBHOOK_TOKEN"
            },
            "allowedEnvVars": ["WEBHOOK_TOKEN"]
          }
        ]
      }
    ]
  }
}
```

HTTP hooks receive the same JSON as the POST body. Non-2xx responses are non-blocking errors.

## Alternative: Hooks in Skill Frontmatter

Hooks can also be defined in the SKILL.md frontmatter (scoped to skill lifetime):

```yaml
---
name: my-dispatch-task
hooks:
  Stop:
    - hooks:
        - type: command
          command: "/path/to/notify-agi.sh"
  TaskCompleted:
    - hooks:
        - type: command
          command: "/path/to/notify-agi.sh"
---
```

## Deduplication

The hook script uses a `.hook-lock` file to prevent double notifications:
- Stop and SessionEnd both fire on normal completion
- Only the first event within 30s is processed
- The lock file is in `data/claude-code-results/.hook-lock`

## Troubleshooting

### Hook not firing
1. Check `~/.claude/settings.json` has valid JSON: `jq . ~/.claude/settings.json`
2. Hooks are snapshot at session start — restart Claude Code after config changes
3. Check `data/claude-code-results/hook.log` for errors

### Output is empty
1. PTY mode: hook reads from `task-output-${SESSION_ID}.txt`, not stdin
2. Hook sleeps 1s to wait for `tee` pipe flush
3. Check `data/claude-code-results/task-output-<session_id>.txt` exists and has content

### Telegram notification not sent
1. Check `openclaw` binary is accessible: `which openclaw`
2. Verify group ID: `openclaw message send --channel telegram --target "<group_id>" --message "test"`
3. Check `task-meta-<session_id>.json` has valid `telegram_group`

### Stale notifications
1. Meta file age check: >2h old meta is ignored
2. Session ID mismatch: meta session_id must match current session
3. Clear stale meta: `rm data/claude-code-results/task-meta-<session_id>.json`
