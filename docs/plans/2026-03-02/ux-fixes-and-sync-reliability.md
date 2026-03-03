# UX Fixes & Sync Reliability — Design

## Problem 1: Messages occasionally lost

### Context
A user message ("Looks good to me") was sent via the app, reached the tmux terminal (confirmed by `send_input` returning True and the tmux pane showing `❯ Looks good to me`), but Claude Code never processed it — no entry appeared in the transcript. The app showed Claude was idle and ready for input. We don't know why Claude Code ignored it.

Separately, sync stopped entirely after a permission was resolved in terminal ("Answered in terminal"). The app received no further messages despite many appearing in the terminal. Restarting the app fixed it.

Both issues are hard to reproduce. We don't have enough diagnostic data to determine root causes.

### Design

**A) "Failed to send" indicator**

After sending input to tmux, the server monitors the transcript file for the user message to appear.

- Server sends input via `tmux send-keys` as usual
- Server polls the transcript for ~5 seconds, checking if a new user-type line containing the sent text appears
- If found: send `delivery_confirmed` to the app
- If not found within 5 seconds: send `delivery_failed` to the app
- App shows a "Failed to send" indicator next to the message
- No auto-retry

Server changes (ios_server.py):
- New method `verify_delivery(text, timeout=5)` that polls `transcript_handler.expected_session_file` for the text
- Called after `send_to_terminal()` in `handle_voice_input()`
- Sends `delivery_status` message to iOS: `{"type": "delivery_status", "status": "confirmed"|"failed", "text": "..."}`

iOS changes (SessionView.swift):
- `SessionHistoryMessage` or conversation item gets a `deliveryStatus` field
- When `delivery_failed` received, mark the matching message
- Show subtle red "Failed to send" text below the message bubble

**B) Sync chain integration test**

Test the full pipeline: file modification → watchdog event → content extraction → callback delivery.

- Create a temp transcript file
- Set up TranscriptHandler with mock callbacks
- Append assistant/user lines to the file
- Verify callbacks fire with correct content and sequence numbers
- Simulate permission_resolved flow, then append more lines
- Verify callbacks continue firing after permission events
- Test reconciliation: disable watchdog, append lines, call reconcile(), verify content delivered

This test runs as part of the server test suite. If it passes, the bug is in a path we haven't considered. If it fails, we've found the bug.

**C) Diagnostic logging**

Add logging at each step of the sync chain so next failure gives us evidence:
- Watchdog `on_modified`: log file path, line count before/after
- `extract_new_content`: log number of new lines, blocks extracted
- Callback scheduling: log when `run_coroutine_threadsafe` is called
- Reconciliation loop: log every tick (even when no new content)
- Track last watchdog event time; log warning if >10s gap while transcript mtime changed

---

## Problem 2: Settings shows "Connecting..." on startup, opens camera on tap

### Context
On app launch, if a server IP is saved, the app auto-connects. This sets state to `.connecting`, showing "Connecting..." with a spinner. If the server isn't reachable (IP changed, server not started), the URLSession WebSocket hangs for ~10 seconds before timing out. During this time, "Connecting..." is a tappable button that opens the QR scanner — confusing UX.

### Design

**A) TCP pre-check before WebSocket connection**

Before attempting the WebSocket handshake, do a raw TCP socket connect to the IP:port. On a local network this returns instantly: either the port is open (proceed with WebSocket) or connection refused (fail immediately).

iOS changes (WebSocketManager.swift):
- New private method `tcpCheck(host:port:) async -> Bool`
- Uses `NWConnection` (Network framework) or raw `Socket` to attempt TCP connect
- Returns true if connection succeeds, false if refused/unreachable
- Timeout of 2 seconds as safety net (should never be needed on local network)
- Called at the start of `connectToURL()` before creating the WebSocket task
- If TCP check fails: immediately set `.error("Server not reachable")`, don't attempt WebSocket

**B) "Connecting..." is non-interactive**

SettingsView changes:
- When state is `.connecting`: show non-interactive HStack with ProgressView + "Connecting..." text (not inside a Button)
- When state is `.disconnected` or `.error`: show tappable "Connect" button that opens QR scanner
- When state is `.connected`: show connected URL (current behavior)

---

## Problem 3: Mic + keyboard need to work together

### Context
Voice input and text input are completely separate paths. Voice transcription fires `onFinalTranscription` which immediately sends via `sendVoiceInput`, ignoring any text in the keyboard text field. The two inputs don't combine.

### Design

Voice becomes dictation — it appends to the text field instead of sending directly.

**Changes to `onFinalTranscription` callback (SessionView.swift):**
- Instead of calling `sendVoiceInput(text:)` and `items.append(...)`:
  - Append transcribed text to `messageText` with a space separator if there's existing text
  - Do NOT send anything
  - Do NOT add to conversation items
- User reviews combined text in the text field and taps send button

**Changes to `toggleRecording` (SessionView.swift):**
- Don't dismiss keyboard (`isTextFieldFocused = false`) — user may want to see their text while dictating
- Still disable the text field during recording (current behavior is fine)

**Changes to send flow:**
- `sendTextMessage()` already handles sending `messageText` — no changes needed
- Remove `sendVoiceInput` from WebSocketManager (or keep for backward compat but stop calling it from SessionView)

**Result:**
- Tap mic → speak → text appears in text field (appended to existing text)
- Tap mic again to add more
- Edit text if needed
- Tap send to submit

---

## Problem 4: Projects not ordered by latest activity

### Context
`list_projects()` uses `os.listdir()` which returns entries in arbitrary filesystem order. Newly created/used projects appear far down the list.

### Design

Sort projects by the most recent session file's modification time.

**Changes to `list_projects()` (session_manager.py):**

After building the projects list (line 92), before returning:

```python
def _get_project_latest_mtime(self, folder_name: str) -> float:
    """Get the mtime of the most recent session file in a project."""
    project_path = os.path.join(self.projects_dir, folder_name)
    session_files = glob.glob(os.path.join(project_path, "*.jsonl"))
    if not session_files:
        return 0
    return max(os.path.getmtime(f) for f in session_files)

# In list_projects(), before return:
projects.sort(key=lambda p: self._get_project_latest_mtime(p.folder_name), reverse=True)
```

Most recently used project appears first.

---

## Risk Assessment

**Riskiest assumption:** Problem 1's "Failed to send" indicator assumes we can reliably detect whether a message appeared in the transcript within 5 seconds. If Claude Code is slow to write (e.g., large context, API latency), we might get false "Failed to send" alerts.

**How to verify:** The sync chain integration test will tell us if the basic pipeline works. The "Failed to send" feature can be tested by sending input when no Claude Code session is running (guaranteed failure) and when one is running (should confirm quickly).

**Verify risky part early:** Build the sync chain test first (Problem 1B). If it reveals a bug in the transcript watcher, fix that before building the delivery verification.
