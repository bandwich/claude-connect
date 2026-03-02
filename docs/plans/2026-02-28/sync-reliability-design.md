# Sync Reliability: Fix Terminal-to-App Message Dropping

## Problem

Messages written by Claude in the terminal frequently fail to appear in the iOS app. Tool results never arrive, leaving cards stuck on "Running..." indefinitely. Interactive prompts (AskUserQuestion, permissions) are invisible in the app even though they're active in the terminal.

Root causes identified:

1. **Thread-unsafe `processed_line_count`** — watchdog thread and asyncio event loop both read/write without synchronization
2. **2-second hardcoded sleep** during session startup — messages arriving during this gap are lost or double-processed
3. **No recovery for missed watchdog events** — if watchdog misses a file modification, those lines are permanently lost
4. **Session history vs live stream conflicts** — history reload can wipe live messages; timestamp-based dedup has near-miss collisions

## Approach: Fix Transcript Watcher + Reconciliation Loop

Keep the current watchdog-based architecture but fix race conditions and add a self-healing reconciliation mechanism.

## Design

### 1. Thread Safety (Server)

Add a `threading.Lock` protecting `processed_line_count` and `expected_session_file`. Both `on_modified()` (watchdog thread) and `set_session_file()` (asyncio loop) acquire this lock before reading or writing these fields.

```python
self._lock = threading.Lock()

def on_modified(self, event):
    with self._lock:
        if self.expected_session_file:
            if os.path.realpath(event.src_path) != os.path.realpath(self.expected_session_file):
                return
        new_blocks = self.extract_new_content()
    # ... send blocks (outside lock)

def set_session_file(self, path):
    with self._lock:
        self.expected_session_file = path
        self.processed_line_count = count_lines(path)
```

### 2. Replace Sleep with File Polling (Server)

Replace the hardcoded `await asyncio.sleep(2.0)` in session resume/open with a polling loop that waits for the transcript file to exist.

```python
# In handle_resume_session / handle_open_session:
for _ in range(50):  # 10 seconds max
    session_file = find_session_file(session_id)
    if session_file:
        break
    await asyncio.sleep(0.2)
else:
    # Handle timeout - send error to client
```

This eliminates the window where early transcript lines are missed because `set_session_file()` hadn't been called yet.

### 3. Reconciliation Loop (Server)

Add an async loop that runs every 3 seconds while a session is active. It re-reads the transcript file line count and reprocesses any lines that watchdog missed.

```python
async def reconciliation_loop(self):
    """Self-healing loop that catches any lines watchdog missed."""
    while self.active_session_id:
        await asyncio.sleep(3.0)
        with self._lock:
            if not self.session_file:
                continue
            actual_lines = count_lines(self.session_file)
            if actual_lines > self.processed_line_count:
                new_blocks = extract_from_lines(
                    self.session_file,
                    self.processed_line_count,
                    actual_lines
                )
                self.processed_line_count = actual_lines
        if new_blocks:
            await self.send_content_to_clients(new_blocks)
```

- Runs alongside watchdog (watchdog = low latency, reconciliation = reliability)
- Lock ensures no race between reconciliation and normal watchdog processing
- Starts on session open, stops on session close

### 4. Sequence Numbers (Server → iOS Protocol)

Add a monotonic sequence number to every content message sent to iOS. Derived from transcript line number — natural, monotonic, no extra state needed.

```json
{"type": "assistant_response", "seq": 42, "content_blocks": [...]}
{"type": "user_message", "seq": 43, "role": "user", "content": "..."}
```

- Sequence resets when a new session is opened
- iOS tracks `lastReceivedSeq` per session

### 5. iOS Resync Protocol

Add a `resync` message type. On reconnect (or if iOS detects a sequence gap), it sends:

```json
{"type": "resync", "from_seq": 38}
```

Server responds with all content from that sequence forward. This replaces the current approach of full history reload + live stream (which can conflict).

**Replaces current flow:**
- Old: `requestSessionHistory()` → bulk load → hope live stream doesn't conflict
- New: `resync(from_seq)` → server sends exactly the missing content → no conflicts

### 6. iOS Dedup Fix

Replace timestamp-based message IDs with sequence-based IDs:
- Text messages: `"text-\(seq)"` instead of `"text-\(timestamp)"`
- Tool use items: keep existing `toolId`-based dedup (already works)
- Eliminates near-miss timestamp collisions that cause duplicates

## Implementation Order

Server-only changes first (testable with existing app):

1. **Thread lock + sleep-to-poll fix** — Immediate reliability improvement
2. **Reconciliation loop** — Catches all missed watchdog events

Then coordinated server + iOS changes:

3. **Sequence numbers on server messages** — Enables gap detection
4. **iOS resync protocol** — Client-initiated recovery on reconnect
5. **iOS dedup fix** — Sequence-based IDs eliminate duplicates

## Risk Assessment

**Riskiest assumption:** Reconciliation loop correctly re-extracts missed content without causing duplicates on iOS.

**Verification plan:**
1. Unit test: Mock transcript, simulate watchdog missing lines 5-8, verify reconciliation produces exactly those lines
2. Integration test: Rapidly write 50 transcript lines, verify iOS receives all 50 (check via sequence numbers)
3. Manual test: Open same session in terminal and app, interact from terminal, confirm app stays perfectly in sync

**Early verification:** Steps 1-2 (server-only) can be tested immediately with the existing app. The missing messages that currently plague the app should start appearing once the reconciliation loop is running.

## Files Changed

### Server (steps 1-3)
- `voice_server/ios_server.py` — Lock, reconciliation loop, sequence numbers, resync handler
- `voice_server/tests/` — New tests for reconciliation and thread safety

### iOS (steps 4-5)
- `WebSocketManager.swift` — Track `lastReceivedSeq`, send `resync` on reconnect
- `SessionView.swift` — Use sequence-based IDs for conversation items
- `Message.swift` — Add `seq` field to message models
