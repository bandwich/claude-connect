# Slash Commands Don't Produce Visible Responses in App

## Problem

When a user sends a slash command from the iOS app (e.g. `/btw what's the weather`), the command is delivered to Claude Code via tmux but no response appears in the app. The app shows "Thinking" briefly then nothing.

## Root Cause

Claude Code slash commands fall into two categories:

1. **Commands that write to the transcript JSONL** — these work fine in the app (e.g. skills like `/commit`, `/debug` which expand into user prompts)
2. **Commands that produce terminal-only output** — these show responses as transient overlays in the terminal that never appear in the transcript file. The app relies entirely on the transcript for message display, so it sees nothing.

## Verified Behavior

Tested `/btw whats the weather` in a tmux session:

```
❯ /btw whats the weather

  /btw whats the weather

    No idea, I can't check the weather.

  Press Space, Enter, or Escape to dismiss
```

- The response is an inline terminal overlay
- No new lines written to the transcript JSONL
- The pane parser could detect this text since it's visible in `tmux capture-pane`

## Affected Commands

Terminal-only output (no transcript entry):
- `/btw` — side question, transient overlay with "Press Space/Enter/Escape to dismiss"
- `/clear` — rewrites the transcript file (also breaks transcript watcher's `processed_line_count`)
- `/status`, `/cost`, `/help`, `/context`, `/diff`, `/copy`, `/export` — info display
- `/config`, `/model`, `/theme`, `/color`, `/effort` — settings UI
- `/compact` — may or may not write to transcript (needs testing)

Commands that likely DO write to transcript (expanded into user prompts):
- Skills: `/commit`, `/debug`, `/simplify`, `/loop`, `/claude-api`, etc.
- `/init` — triggers Claude to create CLAUDE.md
- `/plan` — enters plan mode

## Potential Fix Approaches

### Option A: Pane Capture for Slash Commands
After sending a `/`-prefixed message, poll `tmux capture-pane` for a few seconds to capture the response text. Send it to iOS as a new message type (e.g. `command_response`). Challenges:
- Different commands have different output formats
- Need to distinguish command output from normal Claude thinking
- Some commands show interactive UIs (menus, prompts)
- Need to auto-dismiss overlays that wait for keypress

### Option B: Filter Autocomplete to Working Commands
Only show commands in the dropdown that produce transcript output (skills + prompt-expanding commands). Hide terminal-only commands. Simpler but reduces the feature's usefulness.

### Option C: Hybrid
- Show all commands in autocomplete
- For commands known to be terminal-only, show a disclaimer or handle them specially
- For skills/prompt commands, send normally

## Additional Issue: /clear Breaks Transcript Watcher

When `/clear` is sent, Claude Code rewrites the transcript file. The transcript watcher's `processed_line_count` was set to the old file length on resume (line 326 in transcript_watcher.py). After clear, the file has new content but `processed_line_count` may be ahead, so new messages are skipped.

The watcher has a shrink check (line 186-187: `if len(lines) < self.processed_line_count: self.processed_line_count = 0`) but `/clear` may not always shrink the file — it could rewrite with similar or more lines.

## Files Involved

- `voice_server/handlers/input_handler.py` — sends text to tmux, verifies delivery via transcript
- `voice_server/services/transcript_watcher.py` — watches transcript JSONL, tracks `processed_line_count`
- `voice_server/infra/pane_parser.py` — parses tmux pane for activity state (could be extended)
- `voice_server/infra/tmux_controller.py` — `send_input()` sends text via `tmux send-keys`

## Server Logs From Failed /btw Attempt

```
[DEBUG] send_to_terminal: tmux_session=claude-connect_778566b7-a5f3-4e5f-bf0f-c82f0f7d1c80
[DEBUG] send_input returned: True
[RECONCILE] tick=10, processed=18, file_lines=18, gap=0
[RECONCILE] tick=20, processed=18, file_lines=18, gap=0
```

Message delivered to tmux, but transcript never grew — reconcile confirmed 0 gap repeatedly.
