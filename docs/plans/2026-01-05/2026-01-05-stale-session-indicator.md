# Stale Session Indicator Fix Plan

> **For Claude:** REQUIRED SUB-SKILL: Use execute-plan to implement this plan task-by-task.

**Goal:** Fix stale session indicator (checkmark) showing wrong state after app restart

**Architecture:** Reset `active_session_id` on server when client connects. Allow manual sync even if session appears synced. This ensures fresh state on reconnect.

**Tech Stack:** Python (server), Swift (iOS)

---

## Task 1: Reset Active Session on Client Connect

**Files:**
- Modify: `voice_server/ios_server.py`
- Test: `voice_server/tests/test_ios_server.py`

**Step 1: Write failing test**

Add to `test_ios_server.py`:

```python
@pytest.mark.asyncio
async def test_active_session_cleared_on_client_connect(mock_vscode_controller):
    """New client connection should clear active_session_id to avoid stale state"""
    server = VoiceServer()
    server.vscode_controller = mock_vscode_controller

    # Simulate server had a previous active session
    server.active_session_id = "old-session-123"

    # Create mock websocket
    mock_ws = AsyncMock()
    mock_ws.send = AsyncMock()

    # Simulate client connection handler start
    await server.send_vscode_status(mock_ws)

    # Verify active_session_id was sent as None (cleared on connect)
    call_args = mock_ws.send.call_args[0][0]
    status = json.loads(call_args)
    assert status["active_session_id"] is None, "Should clear active session on connect"
```

**Step 2: Run test to verify it fails**

```bash
cd voice_server/tests && ./run_tests.sh -k "test_active_session_cleared" 2>&1 | tail -20
```

Expected: FAIL - active_session_id is "old-session-123" not None

**Step 3: Clear active_session_id on client connect**

In `ios_server.py`, modify `handle_client` (around line 689):

```python
async def handle_client(self, websocket):
    self.clients.add(websocket)
    print(f"Client connected. Total clients: {len(self.clients)}")

    # Reset active session on new client connect to avoid stale indicator
    self.active_session_id = None

    try:
        await self.send_status(websocket, "idle", "Connected")
        await self.send_vscode_status(websocket)  # Send VSCode status on connect
        async for message in websocket:
            print(f"Received message: {message[:100]}...")
            await self.handle_message(websocket, message)
```

**Step 4: Run test to verify it passes**

```bash
cd voice_server/tests && ./run_tests.sh -k "test_active_session_cleared" 2>&1 | tail -20
```

Expected: PASS

**Step 5: Run all server tests**

```bash
cd voice_server/tests && ./run_tests.sh 2>&1 | tail -20
```

Expected: All pass

**Step 6: Commit**

```bash
git add voice_server/ios_server.py voice_server/tests/test_ios_server.py
git commit -m "fix: reset active session on client connect"
```

---

## Task 2: Allow Manual Sync Even If "Already Synced"

**Files:**
- Modify: `ios-voice-app/ClaudeVoice/ClaudeVoice/Views/SessionView.swift`
- Test: `ios-voice-app/ClaudeVoice/ClaudeVoiceTests/ClaudeVoiceTests.swift`

**Step 1: Remove guard in syncSession**

In `SessionView.swift`, modify `syncSession()` (around line 305):

```swift
private func syncSession() {
    // Don't skip even if appears synced - server state may be stale

    // Check if VSCode is connected
    guard webSocketManager.vscodeConnected else {
        syncError = "VSCode not connected"
        return
    }

    isSyncing = true
    syncError = nil

    webSocketManager.resumeSession(folderName: project.folderName, sessionId: session.id)

    webSocketManager.onSessionActionResult = { response in
        isSyncing = false
        if response.success {
            // Session synced - vscode_status broadcast will update activeSessionId
            print("Session synced successfully")
        } else {
            syncError = response.error ?? "Failed to sync"
        }
    }
}
```

**Step 2: Run iOS unit tests**

```bash
cd ios-voice-app/ClaudeVoice && xcodebuild test -scheme ClaudeVoice \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  -only-testing:ClaudeVoiceTests 2>&1 | tail -30
```

Expected: All pass

**Step 3: Commit**

```bash
git add ios-voice-app/ClaudeVoice/ClaudeVoice/Views/SessionView.swift
git commit -m "fix: allow session sync even if indicator shows synced"
```

---

## Verification

Run all tests:

```bash
cd voice_server/tests && ./run_tests.sh
cd ios-voice-app/ClaudeVoice && xcodebuild test -scheme ClaudeVoice \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  -only-testing:ClaudeVoiceTests 2>&1 | tail -30
```

Expected: All pass
