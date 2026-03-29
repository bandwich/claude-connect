# /clear Command Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use execute-plan to implement this plan task-by-task.

**Goal:** Make `/clear` work transparently — after clear, new messages appear in the iOS app.

**Architecture:** `/clear` creates a new transcript file. The server detects this file switch (snapshot + poll), updates the watcher, and broadcasts `session_cleared` to iOS. The app clears its conversation view and resets sequence tracking.

**Tech Stack:** Python (server), Swift/SwiftUI (iOS), WebSocket protocol

**Risky Assumptions:** We can reliably detect the new transcript file after `/clear` using the same snapshot+diff approach as new sessions. Verified early in Task 3 with a manual CHECKPOINT.

---

### Task 1: Server — `/clear` detection and transcript switch

**Files:**
- Modify: `server/main.py` (add `_handle_clear_command` method)
- Modify: `server/handlers/command_handler.py` (route `/clear` to special handling)
- Test: `server/tests/test_clear_command.py`

**Step 1: Write the failing test**

Create `server/tests/test_clear_command.py`:

```python
"""Tests for /clear command handling."""

import asyncio
import json
import os
import tempfile
import time
from unittest.mock import AsyncMock, MagicMock, patch

import pytest

from server.models.session_context import SessionContext


def _make_server():
    """Create a minimal mock ConnectServer for testing."""
    server = MagicMock()
    server.active_session_id = "old-session-id"
    server.active_folder_name = "test-folder"
    server.viewed_session_id = "old-session-id"
    server._active_tmux_session = "claude-connect_old-session-id"
    server.transcript_path = "/tmp/test/old-session-id.jsonl"
    server.broadcast_message = AsyncMock()
    server.broadcast_connection_status = AsyncMock()
    server.switch_watched_session = MagicMock(return_value=True)
    server.session_manager = MagicMock()
    server.transcript_handler = MagicMock()
    server.active_sessions = {}
    return server


class TestHandleClearCommand:
    """Test _handle_clear_command detects new file and switches watcher."""

    @pytest.mark.asyncio
    async def test_detects_new_transcript_and_switches(self):
        """After /clear, server finds new session file and switches to it."""
        server = _make_server()

        # Simulate: snapshot has old ID, then new ID appears
        server.session_manager.list_session_ids.return_value = {"old-session-id", "new-session-id"}
        server.session_manager.find_new_session.return_value = "new-session-id"

        ctx = SessionContext(
            session_id="old-session-id",
            folder_name="test-folder",
            tmux_session_name="claude-connect_old-session-id",
        )
        server.active_sessions["claude-connect_old-session-id"] = ctx

        # Import and call the real method
        from server.main import ConnectServer

        # Patch poll_for_session_file to return immediately (avoid real polling delay)
        async def fast_poll(find_fn, timeout=10.0, interval=0.2):
            return find_fn()

        with patch("server.main.poll_for_session_file", side_effect=fast_poll):
            await ConnectServer._handle_clear_command(server, ctx)

        # Should switch to new session file
        server.switch_watched_session.assert_called_once_with(
            "test-folder", "new-session-id", from_beginning=True
        )

        # Should update session IDs
        assert server.active_session_id == "new-session-id"
        assert server.viewed_session_id == "new-session-id"
        assert ctx.session_id == "new-session-id"

        # Should broadcast session_cleared
        server.broadcast_message.assert_any_await(
            {"type": "session_cleared", "session_id": "new-session-id"}
        )

    @pytest.mark.asyncio
    async def test_timeout_when_no_new_file(self):
        """If no new session file appears, log warning and don't crash."""
        server = _make_server()
        server.session_manager.find_new_session.return_value = None

        ctx = SessionContext(
            session_id="old-session-id",
            folder_name="test-folder",
            tmux_session_name="claude-connect_old-session-id",
        )
        server.active_sessions["claude-connect_old-session-id"] = ctx

        from server.main import ConnectServer

        # Patch poll_for_session_file to return immediately (avoid 5s timeout)
        async def fast_poll(find_fn, timeout=10.0, interval=0.2):
            return find_fn()

        with patch("server.main.poll_for_session_file", side_effect=fast_poll):
            await ConnectServer._handle_clear_command(server, ctx)

        # Should NOT switch or broadcast
        server.switch_watched_session.assert_not_called()
        server.broadcast_message.assert_not_awaited()
```

**Step 2: Run test to verify it fails**

Run: `cd /Users/aaron/Desktop/max && /Users/aaron/.local/pipx/venvs/claude-connect/bin/python -m pytest server/tests/test_clear_command.py -v`

Expected: FAIL — `ConnectServer._handle_clear_command` does not exist.

**Step 3: Implement `_handle_clear_command` in `server/main.py`**

Add this method to the `ConnectServer` class (after `_resolve_pending_session`):

```python
async def _handle_clear_command(self, ctx: SessionContext):
    """Handle /clear: detect new transcript file and switch watcher to it."""
    folder_name = ctx.folder_name
    if not folder_name:
        print("[CLEAR] No folder_name on session context, cannot detect new file")
        return

    # Snapshot current session IDs
    existing_ids = self.session_manager.list_session_ids(folder_name)
    print(f"[CLEAR] Snapshot: {len(existing_ids)} existing sessions in {folder_name}")

    # Poll for new session file (up to 5s)
    new_session_id = await poll_for_session_file(
        find_fn=lambda: self.session_manager.find_new_session(folder_name, existing_ids),
        timeout=5.0,
        interval=0.3
    )

    if not new_session_id:
        print("[CLEAR] Timeout: no new session file detected after /clear")
        return

    print(f"[CLEAR] Detected new session: {new_session_id}")

    # Update server state
    self.active_session_id = new_session_id
    self.viewed_session_id = new_session_id

    # Update SessionContext in-place (tmux session stays alive)
    ctx.session_id = new_session_id

    # Switch file watcher to new transcript
    self.switch_watched_session(folder_name, new_session_id, from_beginning=True)

    # Broadcast to iOS
    await self.broadcast_message(
        {"type": "session_cleared", "session_id": new_session_id}
    )
    await self.broadcast_connection_status()
```

**Step 4: Run test to verify it passes**

Run: `cd /Users/aaron/Desktop/max && /Users/aaron/.local/pipx/venvs/claude-connect/bin/python -m pytest server/tests/test_clear_command.py -v`

Expected: PASS

**Step 5: Commit**

```bash
cd /Users/aaron/Desktop/max && git add server/main.py server/tests/test_clear_command.py && git commit -m "feat: add _handle_clear_command for /clear transcript detection"
```

---

### Task 2: Route `/clear` through special handling in CommandHandler

**Files:**
- Modify: `server/handlers/command_handler.py` (add `/clear` routing)
- Modify: `server/handlers/input_handler.py` (no change needed — `/clear` already goes through CommandHandler)
- Test: `server/tests/test_clear_command.py` (add routing test)

**Step 1: Write the failing test**

Add to `server/tests/test_clear_command.py`:

```python
class TestClearCommandRouting:
    """Test that /clear is routed to special handling, not generic UI command."""

    @pytest.mark.asyncio
    async def test_clear_routes_to_handle_clear(self):
        """CommandHandler.execute sends /clear to tmux then triggers _handle_clear_command."""
        from server.handlers.command_handler import CommandHandler

        server = _make_server()
        server._active_tmux_session = "claude-connect_old-session-id"
        server.send_to_terminal = AsyncMock()
        server._handle_clear_command = AsyncMock()
        server._get_viewed_context = MagicMock()

        ctx = SessionContext(
            session_id="old-session-id",
            folder_name="test-folder",
            tmux_session_name="claude-connect_old-session-id",
        )
        server._get_viewed_context.return_value = ctx
        server.active_sessions["claude-connect_old-session-id"] = ctx

        handler = CommandHandler(server)
        await handler.execute("/clear")

        # Should send /clear to tmux
        server.send_to_terminal.assert_awaited_once_with("/clear")

        # Should trigger clear command handling
        server._handle_clear_command.assert_awaited_once_with(ctx)
```

**Step 2: Run test to verify it fails**

Run: `cd /Users/aaron/Desktop/max && /Users/aaron/.local/pipx/venvs/claude-connect/bin/python -m pytest server/tests/test_clear_command.py::TestClearCommandRouting -v`

Expected: FAIL — CommandHandler doesn't have special `/clear` handling yet.

**Step 3: Add `/clear` routing in `command_handler.py`**

Add `'clear'` to a new set and route it in `execute()`:

```python
# At module level, after _RESPONSE_COMMANDS:
_CLEAR_COMMANDS = frozenset({'clear'})
```

Update `execute()`:

```python
async def execute(self, command_text: str) -> None:
    """Send a slash command to tmux, capture output, broadcast to iOS."""
    if not self.server._active_tmux_session:
        return

    session_name = self.server._active_tmux_session
    cmd_name = self._command_name(command_text)

    if cmd_name in _CLEAR_COMMANDS:
        await self._execute_clear_command(command_text, session_name)
    elif cmd_name in _RESPONSE_COMMANDS:
        await self._execute_response_command(command_text, session_name)
    else:
        await self._execute_ui_command(command_text, session_name)
```

Add the new method:

```python
async def _execute_clear_command(self, command_text: str, session_name: str) -> None:
    """Handle /clear — send to tmux, then detect new transcript file."""
    await self.server.send_to_terminal(command_text)

    ctx = self.server._get_viewed_context()
    if ctx:
        await self.server._handle_clear_command(ctx)
    else:
        print("[CLEAR] No viewed session context, cannot detect new file")
```

**Step 4: Run test to verify it passes**

Run: `cd /Users/aaron/Desktop/max && /Users/aaron/.local/pipx/venvs/claude-connect/bin/python -m pytest server/tests/test_clear_command.py -v`

Expected: ALL PASS

**Step 5: Commit**

```bash
cd /Users/aaron/Desktop/max && git add server/handlers/command_handler.py server/tests/test_clear_command.py && git commit -m "feat: route /clear to special handler in CommandHandler"
```

---

### Task 3: Manual verification — CHECKPOINT

**Step 1: Reinstall the server**

```bash
pipx install --force /Users/aaron/Desktop/max
```

**Step 2: Start server and connect iOS app**

Start `claude-connect`, connect the iOS app, open or create a session.

**Step 3: Send a message, then send `/clear`**

1. Send a normal message via the app — verify it appears in conversation
2. Type or say "/clear" via the app
3. Watch server logs for `[CLEAR] Detected new session: <uuid>`

**Step 4: Verify new messages appear after clear**

Send another message after `/clear`. It should appear in the app.

**CHECKPOINT:** If messages don't appear after `/clear`, debug now. Check:
- Server logs for `[CLEAR]` lines
- Whether `switch_watched_session` was called
- Whether the new transcript file exists in `~/.claude/projects/`

Do NOT proceed to iOS changes until this works.

---

### Task 4: iOS — handle `session_cleared` message

**Files:**
- Modify: `ios/ClaudeConnect/ClaudeConnect/Models/Session.swift` (add `SessionClearedMessage` struct)
- Modify: `ios/ClaudeConnect/ClaudeConnect/Services/WebSocketManager.swift` (decode + callback)
- Modify: `ios/ClaudeConnect/ClaudeConnect/Views/SessionView.swift` (clear items on callback)

**Step 1: Add `SessionClearedMessage` model**

In `Session.swift`, after `SessionActionResponse`:

```swift
struct SessionClearedMessage: Codable {
    let type: String
    let sessionId: String

    enum CodingKeys: String, CodingKey {
        case type
        case sessionId = "session_id"
    }
}
```

**Step 2: Add callback and decode in `WebSocketManager.swift`**

Add callback property (near other `onSession*` callbacks around line 41):

```swift
var onSessionCleared: ((String) -> Void)?  // new session ID
```

Add decode case in `handleMessage()` — insert after the `SessionActionResponse` decode block (around line 610):

```swift
} else if let cleared = try? JSONDecoder().decode(SessionClearedMessage.self, from: data),
          cleared.type == "session_cleared" {
    logToFile("✅ Decoded as SessionClearedMessage: \(cleared.sessionId)")
    DispatchQueue.main.async {
        self.onSessionCleared?(cleared.sessionId)
    }
}
```

Also add the same decode in the binary message handler if there is one (check for duplicate `handleMessage` pattern around line 777 — the same decode chain appears twice for string vs data messages).

**Step 3: Handle callback in `SessionView.swift`**

In the `onAppear` callback chain (where other `webSocketManager.on*` callbacks are set), add:

```swift
webSocketManager.onSessionCleared = { [weak webSocketManager] newSessionId in
    guard let webSocketManager = webSocketManager else { return }
    print("[SessionView] Session cleared, new session: \(newSessionId)")

    // Clear conversation
    items.removeAll()
    permissionResolutions.removeAll()
    completedBackgroundToolIds.removeAll()

    // Reset sequence tracking
    lastProcessedSeq = -1
    webSocketManager.lastReceivedSeq = 0

    // Adopt new session ID
    effectiveSessionId = newSessionId
}
```

Also nil out the callback in `onDisappear`:

```swift
webSocketManager.onSessionCleared = nil
```

**Step 4: Build for simulator to verify compilation**

Run:
```bash
cd /Users/aaron/Desktop/max/ios/ClaudeConnect && xcodebuild build -scheme ClaudeConnect -destination 'platform=iOS Simulator,name=iPhone 16' 2>&1 | tail -5
```

Expected: BUILD SUCCEEDED

**Step 5: Commit**

```bash
cd /Users/aaron/Desktop/max && git add ios/ClaudeConnect/ClaudeConnect/Models/Session.swift ios/ClaudeConnect/ClaudeConnect/Services/WebSocketManager.swift ios/ClaudeConnect/ClaudeConnect/Views/SessionView.swift && git commit -m "feat: iOS handles session_cleared to reset conversation after /clear"
```

---

### Task 5: Reconciliation fallback for terminal-initiated `/clear`

**Files:**
- Modify: `server/main.py` (add stale file detection in `_reconciliation_loop`)
- Test: `server/tests/test_clear_command.py` (add reconciliation test)

**Step 1: Write the failing test**

Add to `server/tests/test_clear_command.py`:

```python
class TestReconciliationClearDetection:
    """Test that reconciliation loop detects /clear done in terminal."""

    @pytest.mark.asyncio
    async def test_detects_stale_file_with_active_pane(self):
        """If watched file is stale but pane is active, trigger clear detection."""
        from server.main import ConnectServer

        server = _make_server()
        server.active_session_id = "old-session-id"
        server.active_folder_name = "test-folder"
        server._active_tmux_session = "claude-connect_old-session-id"

        ctx = SessionContext(
            session_id="old-session-id",
            folder_name="test-folder",
            tmux_session_name="claude-connect_old-session-id",
        )
        server.active_sessions["claude-connect_old-session-id"] = ctx
        server._get_viewed_context = MagicMock(return_value=ctx)
        server._handle_clear_command = AsyncMock()

        # Simulate: file hasn't changed (stale_ticks >= 2) and pane is active
        result = await ConnectServer._check_stale_transcript(server, stale_ticks=2, pane_is_active=True)

        assert result is True
        server._handle_clear_command.assert_awaited_once_with(ctx)

    @pytest.mark.asyncio
    async def test_no_detection_when_pane_idle(self):
        """If pane is idle, don't trigger clear detection even if file is stale."""
        from server.main import ConnectServer

        server = _make_server()
        server._get_viewed_context = MagicMock()
        server._handle_clear_command = AsyncMock()

        result = await ConnectServer._check_stale_transcript(server, stale_ticks=2, pane_is_active=False)

        assert result is False
        server._handle_clear_command.assert_not_awaited()
```

**Step 2: Run test to verify it fails**

Run: `cd /Users/aaron/Desktop/max && /Users/aaron/.local/pipx/venvs/claude-connect/bin/python -m pytest server/tests/test_clear_command.py::TestReconciliationClearDetection -v`

Expected: FAIL — `_check_stale_transcript` does not exist.

**Step 3: Implement `_check_stale_transcript` and integrate into reconciliation loop**

Add method to `ConnectServer`:

```python
async def _check_stale_transcript(self, stale_ticks: int, pane_is_active: bool) -> bool:
    """Check if transcript file is stale while Claude is active (possible /clear).

    Args:
        stale_ticks: Number of consecutive reconciliation ticks with no file growth.
        pane_is_active: Whether the tmux pane shows non-idle activity.

    Returns:
        True if clear detection was triggered.
    """
    if stale_ticks < 2 or not pane_is_active:
        return False

    ctx = self._get_viewed_context()
    if not ctx:
        return False

    print(f"[RECONCILE] Stale transcript ({stale_ticks} ticks) with active pane — checking for /clear")
    await self._handle_clear_command(ctx)
    return True
```

In `_reconciliation_loop`, add stale tick tracking. After the existing reconciliation block (around line 259), add:

```python
# Track stale file ticks for /clear detection
if not new_blocks and not user_texts:
    stale_ticks += 1
else:
    stale_ticks = 0

# Check for terminal-initiated /clear (stale file + active pane)
if stale_ticks >= 2 and self._active_tmux_session:
    from server.infra.pane_parser import parse_pane_status
    pane_text = self.tmux.capture_pane(self._active_tmux_session, include_history=False)
    if pane_text:
        activity = parse_pane_status(pane_text)
        pane_is_active = activity.state != "idle"
        if await self._check_stale_transcript(stale_ticks, pane_is_active):
            stale_ticks = 0  # Reset after detection
```

Initialize `stale_ticks = 0` at the top of `_reconciliation_loop` (alongside `tick = 0`).

**Step 4: Run all tests**

Run: `cd /Users/aaron/Desktop/max && /Users/aaron/.local/pipx/venvs/claude-connect/bin/python -m pytest server/tests/test_clear_command.py -v`

Expected: ALL PASS

**Step 5: Commit**

```bash
cd /Users/aaron/Desktop/max && git add server/main.py server/tests/test_clear_command.py && git commit -m "feat: reconciliation loop detects terminal-initiated /clear"
```

---

### Task 6: End-to-end verification

**Step 1: Run all server tests**

Run: `cd /Users/aaron/Desktop/max/server/tests && ./run_tests.sh`

Expected: All pass, no regressions.

**Step 2: Reinstall and test iOS-initiated `/clear`**

```bash
pipx install --force /Users/aaron/Desktop/max
```

1. Start `claude-connect`, connect iOS app
2. Open a session, send a message, see it in app
3. Type "/clear" in the app
4. Verify: conversation clears, send another message, see it appear

**Step 3: Test terminal-initiated `/clear`**

1. With server running and iOS connected
2. In the tmux terminal, type `/clear` directly
3. Wait ~6-9 seconds (2-3 reconciliation ticks)
4. Send a message from iOS — verify it appears

**Step 4: Build and install iOS on device**

```bash
cd /Users/aaron/Desktop/max/ios/ClaudeConnect
xcodebuild -target ClaudeConnect -sdk iphoneos build
xcrun devicectl list devices
xcrun devicectl device install app --device "<DEVICE_ID>" build/Release-iphoneos/ClaudeConnect.app
```

Repeat steps 2-3 on physical device.

**CHECKPOINT:** Both iOS-initiated and terminal-initiated `/clear` must work before merging.

**Step 5: Final commit (if any fixups needed)**

Only if fixes were needed during verification.
