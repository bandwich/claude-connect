# Slash Commands: Making All Commands Work from iOS

## Status: DESIGNED

## Goal

Every slash command the terminal can run should be usable from the iOS app and produce visible output.

## What's Already Implemented

- `CommandsProvider` service sends command list to iOS on connect
- `SlashCommand` model + `availableCommands` on `WebSocketManager`
- `CommandTextField` with blue attributed text for `/command` prefix
- `CommandDropdownView` with filtered autocomplete wired into `SessionView`

## Design Decisions

- **Interactive commands (e.g. `/model`, `/config`)**: Send-and-dismiss. Capture terminal output, auto-dismiss overlay, show as read-only. No native iOS pickers for v1.
- **Output delivery**: New `command_response` WebSocket message type. Not `assistant_response` (it's not from Claude).
- **Handler structure**: New `CommandHandler` module. `InputHandler` delegates to it for `/`-prefixed input.
- **Pane capture timing**: Poll for stability (200ms interval, 2 consecutive identical captures = done, 3s max timeout). No per-command markers.
- **Transcript noise**: Filter XML-tagged lines in `TranscriptHandler`. Pane capture provides the response for all categories.
- **iOS display**: Single `command_response` card (includes command name in header). No separate user message bubble for slash commands.
- **`/clear`**: Deferred to separate task (watcher infrastructure problem, not command display).

## Architecture

Two parallel changes:

### 1. CommandHandler (new: `handlers/command_handler.py`)

Intercepts `/`-prefixed input, captures terminal output, broadcasts result.

**Flow:**
```
iOS sends "/help" via voice_input or user_input
  -> InputHandler detects "/" prefix
  -> Delegates to CommandHandler.execute()
  -> Sends "/help" to tmux via send_to_terminal()
  -> Waits 300ms initial delay
  -> Polls pane every 200ms until stable (2 identical captures, max 3s)
  -> Captures final pane content
  -> Sends Escape to dismiss overlay
  -> Strips ANSI codes, trims command echo + trailing prompt
  -> Broadcasts command_response to iOS
  -> No delivery verification for slash commands
```

**Pane capture logic:**
1. Send command to tmux
2. Wait 300ms initial delay (let tmux process keystroke)
3. Poll loop: capture pane, compare to previous, if identical 2x in a row (200ms apart) = stable. Max 3s.
4. Send Escape to dismiss overlay
5. Wait 100ms (let overlay dismiss), but use the pre-dismiss capture as command output

**Output processing:**
- Strip ANSI escape codes via regex (`\x1b\[[0-9;]*[a-zA-Z]`)
- Trim: remove command echo line (first line) and trailing prompt line
- If output empty after trimming, send "Command executed"

**`command_response` message format:**
```json
{
  "type": "command_response",
  "command": "/help",
  "output": "cleaned terminal text",
  "session_id": "..."
}
```

### 2. Transcript Filter (modify: `TranscriptHandler`)

Suppress XML-tagged lines from reaching iOS:

```python
def _is_command_noise(self, text: str) -> bool:
    return ('<local-command-caveat>' in text or
            '<command-name>' in text or
            '<local-command-stdout>' in text)
```

User message lines matching this check are skipped for broadcast/TTS. `processed_line_count` still advances normally.

**Edge case:** `/compact` prepends a summary message (plain text starting with "This session is being continued...") before the caveat block. This passes through the filter because it has no XML tags.

### 3. iOS Changes

**New `ConversationItem` case:** `.commandResponse(command: String, output: String)`

**`WebSocketManager`:**
- Handle `"command_response"` in message router
- Append `.commandResponse` item to session conversation
- No TTS for command responses

**`SessionView`:**
- Render `.commandResponse` as a distinct card: command name header + monospace output body
- Scrollable for long output (e.g., `/help`)
- Visually distinct from assistant messages (subtle background/border)

**Input path:**
- When input starts with `/`, skip adding user message to conversation
- The `command_response` card is the only visible item for the command

### 4. InputHandler Changes

- Detect `/`-prefixed text in `handle_voice_input` and `handle_user_input`
- Delegate to `CommandHandler.execute()` instead of normal send path
- Skip `verify_delivery()` for slash commands

## Testing

**Server (`voice_server/tests/`):**
- `test_command_handler.py`: Mock tmux controller, verify pane polling, ANSI stripping, Escape dismiss, `command_response` broadcast
- `test_transcript_filter.py`: Verify caveat/command-name/stdout lines filtered, normal messages pass, `/compact` summary passes

**iOS (`ClaudeVoiceTests/`):**
- `command_response` message parsing
- `.commandResponse` conversation item creation
- `/`-prefixed input skips user echo

**Manual verification:**
- `/help` from iOS -> clean output card, overlay auto-dismissed
- `/effort` from iOS -> output card, no XML in conversation
- Normal message -> unchanged behavior

## Risk: Pane Capture Timing

This is the riskiest assumption. First implementation step should be a smoke test: send `/help` to a real tmux session, run the poll loop, print captured output. If it's garbled or partial, rethink before building everything else.

**Known limitation:** TUI commands (`/status`, `/config`) may produce box-drawing characters and layout artifacts. Acceptable for v1 — information is present, just not pretty.

## Out of Scope

- `/clear` (new transcript file detection) — separate task
- Native iOS pickers for interactive commands — future enhancement
- Pretty rendering of TUI output — future enhancement
