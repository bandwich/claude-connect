# /clear Command Support

## Problem

When the user runs `/clear` in Claude Code, it creates a new transcript file with a new session ID. The old file is left untouched. The transcript watcher keeps watching the stale old file, so no new messages ever appear in the iOS app. The app appears frozen.

## Design

### Detection Mechanism

The primary detection path is triggered by input from the iOS app:

1. User says or types "/clear" via iOS
2. `input_handler.py` delivers it to tmux as normal
3. After delivery, if the input text is `/clear`, call `server._handle_clear_command(session_context)`
4. That method snapshots current session file IDs in the project directory
5. Polls for ~5s to find a new `.jsonl` file that wasn't in the snapshot
6. Once found: updates `SessionContext` with the new transcript path and session ID, calls `set_session_file()` on the watcher, broadcasts `session_cleared` to iOS

**Fallback for terminal-initiated `/clear`:** The reconciliation loop (every 3s) detects staleness — if the watched file hasn't grown in 2+ cycles (~6s) but the tmux pane shows non-idle activity, rescan the session directory for a newer file. If found, perform the same switch.

### iOS App Behavior

Server broadcasts a new message type:

```json
{"type": "session_cleared", "session_id": "new-uuid"}
```

On receiving this, the iOS app:

1. Clears all `conversationItems` from the current session
2. Updates the stored `session_id` to the new one
3. Resets sequence tracking (`lastSeq`) so resync works against the new file

No new UI elements. The conversation view simply empties, matching the terminal experience. The user stays in the same session view.

The old session remains on disk and appears separately in the session browser (different session ID). This is correct — they are different conversations.

### Files Changed

- **`input_handler.py`** — after delivering input, check if text is `/clear` (stripped, case-insensitive). If so, trigger detection flow.
- **`server.py`** — new method `_handle_clear_command(session_context)`: snapshot files, poll for new one, update SessionContext, switch watcher, broadcast `session_cleared`.
- **`session_context.py`** — method to update session ID and transcript path in-place (tmux session stays alive, so we update rather than replace the SessionContext).
- **`transcript_watcher.py`** — no changes needed. `set_session_file()` already handles switching files.
- **iOS `WebSocketManager.swift`** — handle `session_cleared` message type: clear conversation items, update session ID, reset sequence number.
- **iOS `Message.swift`** — add `session_cleared` to received message types if needed.

### Testing

- **Unit tests:** mock file detection, verify `session_cleared` is broadcast and watcher switches files
- **Manual verification (risky part):** run server, connect iOS, send `/clear` via app, confirm new messages appear after clear. Also test `/clear` typed directly in terminal.

### Out of Scope

- No UI button for clear
- No confirmation dialog
- No undo
- Just make the existing `/clear` command work transparently
