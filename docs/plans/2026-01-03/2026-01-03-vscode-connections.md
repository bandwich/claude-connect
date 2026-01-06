# VSCode Connections Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use execute-plan to implement this plan task-by-task.

**Goal:** Replace AppleScript with VSCodeController WebSocket, add session management (resume, new, close, add project), and sync VSCode session status to iOS app.

**Architecture:** Python server connects to vscode-remote-control extension via WebSocket (ws://localhost:3710). Server tracks which session is active in VSCode and broadcasts status to iOS app. iOS app shows connected indicator when session is open, otherwise shows "Open in VSCode" button.

**Tech Stack:** Python (websockets, asyncio), Swift/SwiftUI, vscode-remote-control extension

---

## Prerequisites

### Install vscode-remote-control Extension

```bash
# In VS Code, install the extension:
code --install-extension nickolay.vscode-remote-control

# Or search "Remote Control" in VS Code Extensions panel
# Publisher: Nickolay Shmaenkov
```

### Verify Extension is Running

Run this test script to confirm connectivity:

```bash
cd /Users/aaron/Desktop/max/voice_server
python -c "
import asyncio
import websockets
import json

async def test():
    try:
        ws = await asyncio.wait_for(
            websockets.connect('ws://localhost:3710'),
            timeout=3.0
        )
        print('✅ Connected to vscode-remote-control')

        # Test sending a command
        await ws.send(json.dumps({
            'command': 'workbench.action.terminal.sendSequence',
            'args': {'text': 'echo TEST'}
        }))
        print('✅ Command sent successfully')
        await ws.close()
        return True
    except Exception as e:
        print(f'❌ Connection failed: {e}')
        print('   Make sure VS Code is open with extension installed')
        return False

asyncio.run(test())
"
```

If this fails, ensure VS Code is open and the extension is installed.

---

## Task 1: Add Active Session Tracking to Server

Track which session_id is currently active in VSCode terminal.

**Files:**
- Modify: `voice_server/ios_server.py`
- Modify: `voice_server/tests/test_message_handlers.py`

### Step 1: Add test for active session tracking

```python
# Add to voice_server/tests/test_message_handlers.py
import pytest
from unittest.mock import AsyncMock

class TestActiveSessionTracking:
    """Tests for active session tracking"""

    @pytest.mark.asyncio
    async def test_resume_session_sets_active_session_id(self):
        """resume_session should set active_session_id"""
        import sys
        sys.path.insert(0, '/Users/aaron/Desktop/max/voice_server')

        from ios_server import VoiceServer

        server = VoiceServer()
        server.vscode_controller = AsyncMock()
        server.vscode_controller.is_connected.return_value = True
        server.vscode_controller.kill_terminal = AsyncMock()
        server.vscode_controller.new_terminal = AsyncMock()
        server.vscode_controller.send_sequence = AsyncMock(return_value=True)

        mock_ws = AsyncMock()
        mock_ws.send = AsyncMock()

        await server.handle_resume_session(mock_ws, {"session_id": "abc123"})

        assert server.active_session_id == "abc123"

    @pytest.mark.asyncio
    async def test_close_session_clears_active_session_id(self):
        """close_session should clear active_session_id"""
        import sys
        sys.path.insert(0, '/Users/aaron/Desktop/max/voice_server')

        from ios_server import VoiceServer

        server = VoiceServer()
        server.active_session_id = "abc123"
        server.vscode_controller = AsyncMock()
        server.vscode_controller.is_connected.return_value = True
        server.vscode_controller.kill_terminal = AsyncMock()

        mock_ws = AsyncMock()
        mock_ws.send = AsyncMock()

        await server.handle_close_session(mock_ws)

        assert server.active_session_id is None

    @pytest.mark.asyncio
    async def test_new_session_clears_active_session_id(self):
        """new_session should clear active_session_id (new session has no ID yet)"""
        import sys
        sys.path.insert(0, '/Users/aaron/Desktop/max/voice_server')

        from ios_server import VoiceServer

        server = VoiceServer()
        server.active_session_id = "old-session"
        server.vscode_controller = AsyncMock()
        server.vscode_controller.is_connected.return_value = True
        server.vscode_controller.kill_terminal = AsyncMock()
        server.vscode_controller.new_terminal = AsyncMock()
        server.vscode_controller.send_sequence = AsyncMock(return_value=True)

        mock_ws = AsyncMock()
        mock_ws.send = AsyncMock()

        await server.handle_new_session(mock_ws, {"project_path": "/test"})

        assert server.active_session_id is None
```

### Step 2: Run test to verify it fails

Run: `cd /Users/aaron/Desktop/max/voice_server && python -m pytest tests/test_message_handlers.py::TestActiveSessionTracking -v`
Expected: FAIL (active_session_id attribute doesn't exist)

### Step 3: Add active session tracking to VoiceServer

```python
# In VoiceServer.__init__, add:
        self.active_session_id = None  # Track which session is open in VSCode

# Update handle_resume_session to set active_session_id:
    async def handle_resume_session(self, websocket, data):
        """Handle resume_session request - runs 'claude --resume <id>'"""
        session_id = data.get("session_id", "")
        success = False

        if self.vscode_controller.is_connected() and session_id:
            try:
                await self.vscode_controller.kill_terminal()
                await asyncio.sleep(0.3)
                await self.vscode_controller.new_terminal()
                await asyncio.sleep(0.5)
                success = await self.vscode_controller.send_sequence(
                    f"claude --resume {session_id}\n"
                )
                if success:
                    self.active_session_id = session_id  # Track active session
            except Exception as e:
                print(f"Error resuming session: {e}")

        response = {
            "type": "session_resumed",
            "success": success,
            "session_id": session_id
        }
        await websocket.send(json.dumps(response))

        # Broadcast status to all clients
        if success:
            await self.broadcast_vscode_status()

# Update handle_close_session to clear active_session_id:
    async def handle_close_session(self, websocket):
        """Handle close_session request - kills the active terminal"""
        success = False

        if self.vscode_controller.is_connected():
            try:
                await self.vscode_controller.kill_terminal()
                success = True
                self.active_session_id = None  # Clear active session
            except Exception as e:
                print(f"Error closing session: {e}")

        response = {
            "type": "session_closed",
            "success": success
        }
        await websocket.send(json.dumps(response))

        # Broadcast status to all clients
        if success:
            await self.broadcast_vscode_status()

# Update handle_new_session to clear active_session_id:
    async def handle_new_session(self, websocket, data):
        """Handle new_session request - opens terminal and starts claude"""
        project_path = data.get("project_path", "")
        success = False

        if self.vscode_controller.is_connected():
            try:
                await self.vscode_controller.kill_terminal()
                await asyncio.sleep(0.3)
                await self.vscode_controller.new_terminal()
                await asyncio.sleep(0.5)
                success = await self.vscode_controller.send_sequence("claude\n")
                if success:
                    self.active_session_id = None  # New session has no ID yet
            except Exception as e:
                print(f"Error creating new session: {e}")

        response = {
            "type": "session_created",
            "success": success
        }
        await websocket.send(json.dumps(response))

        # Broadcast status to all clients
        if success:
            await self.broadcast_vscode_status()
```

### Step 4: Run test to verify it passes

Run: `cd /Users/aaron/Desktop/max/voice_server && python -m pytest tests/test_message_handlers.py::TestActiveSessionTracking -v`
Expected: PASS

### Step 5: Commit

```bash
git add voice_server/ios_server.py voice_server/tests/test_message_handlers.py
git commit -m "feat: add active session tracking to VoiceServer"
```

---

## Task 2: Add VSCode Status Broadcasting

Broadcast VSCode connection status and active session to all iOS clients.

**Files:**
- Modify: `voice_server/ios_server.py`
- Modify: `voice_server/tests/test_message_handlers.py`

### Step 1: Add test for status broadcasting

```python
# Add to voice_server/tests/test_message_handlers.py

class TestVSCodeStatusBroadcast:
    """Tests for VSCode status broadcasting"""

    @pytest.mark.asyncio
    async def test_broadcast_includes_vscode_connected_status(self):
        """broadcast_vscode_status should include vscode_connected"""
        import sys
        import json
        sys.path.insert(0, '/Users/aaron/Desktop/max/voice_server')

        from ios_server import VoiceServer

        server = VoiceServer()
        server.vscode_controller = AsyncMock()
        server.vscode_controller.is_connected.return_value = True
        server.active_session_id = "test-session"

        mock_ws = AsyncMock()
        sent_messages = []
        mock_ws.send = AsyncMock(side_effect=lambda msg: sent_messages.append(msg))
        server.clients.add(mock_ws)

        await server.broadcast_vscode_status()

        assert len(sent_messages) == 1
        response = json.loads(sent_messages[0])
        assert response["type"] == "vscode_status"
        assert response["vscode_connected"] is True
        assert response["active_session_id"] == "test-session"

    @pytest.mark.asyncio
    async def test_broadcast_on_client_connect(self):
        """Should broadcast status when client connects"""
        import sys
        import json
        sys.path.insert(0, '/Users/aaron/Desktop/max/voice_server')

        from ios_server import VoiceServer

        server = VoiceServer()
        server.vscode_controller = AsyncMock()
        server.vscode_controller.is_connected.return_value = True
        server.active_session_id = None
        server.loop = asyncio.get_event_loop()

        mock_ws = AsyncMock()
        sent_messages = []
        mock_ws.send = AsyncMock(side_effect=lambda msg: sent_messages.append(msg))

        # Simulate initial status send
        await server.send_status(mock_ws, "idle", "Connected")
        await server.send_vscode_status(mock_ws)

        # Should have status message and vscode_status
        responses = [json.loads(m) for m in sent_messages]
        vscode_status = next((r for r in responses if r.get("type") == "vscode_status"), None)
        assert vscode_status is not None
        assert "vscode_connected" in vscode_status
        assert "active_session_id" in vscode_status
```

### Step 2: Run test to verify it fails

Run: `cd /Users/aaron/Desktop/max/voice_server && python -m pytest tests/test_message_handlers.py::TestVSCodeStatusBroadcast -v`
Expected: FAIL (broadcast_vscode_status doesn't exist)

### Step 3: Add broadcast methods

```python
# Add to VoiceServer class in voice_server/ios_server.py

    async def send_vscode_status(self, websocket):
        """Send VSCode status to a single client"""
        response = {
            "type": "vscode_status",
            "vscode_connected": self.vscode_controller.is_connected(),
            "active_session_id": self.active_session_id
        }
        await websocket.send(json.dumps(response))

    async def broadcast_vscode_status(self):
        """Broadcast VSCode status to all connected clients"""
        for websocket in list(self.clients):
            try:
                await self.send_vscode_status(websocket)
            except Exception as e:
                print(f"Error broadcasting status: {e}")

# Update handle_client to send vscode_status on connect:
    async def handle_client(self, websocket, path):
        """Handle client connection"""
        self.clients.add(websocket)
        print(f"Client connected. Total clients: {len(self.clients)}")
        try:
            await self.send_status(websocket, "idle", "Connected")
            await self.send_vscode_status(websocket)  # Send VSCode status on connect
            async for message in websocket:
                print(f"Received message: {message[:100]}...")
                await self.handle_message(websocket, message)
        except Exception as e:
            print(f"Client error: {e}")
        finally:
            self.clients.discard(websocket)
            print(f"Client disconnected. Total clients: {len(self.clients)}")
```

### Step 4: Run test to verify it passes

Run: `cd /Users/aaron/Desktop/max/voice_server && python -m pytest tests/test_message_handlers.py::TestVSCodeStatusBroadcast -v`
Expected: PASS

### Step 5: Commit

```bash
git add voice_server/ios_server.py voice_server/tests/test_message_handlers.py
git commit -m "feat: add VSCode status broadcasting to clients"
```

---

## Task 3: Add VSCode Status Model to iOS

Add model to decode VSCode status messages.

**Files:**
- Modify: `ios-voice-app/ClaudeVoice/ClaudeVoice/Models/Session.swift`

### Step 1: Add VSCodeStatus model

```swift
// Add to ios-voice-app/ClaudeVoice/ClaudeVoice/Models/Session.swift

struct VSCodeStatus: Codable {
    let type: String
    let vscodeConnected: Bool
    let activeSessionId: String?

    enum CodingKeys: String, CodingKey {
        case type
        case vscodeConnected = "vscode_connected"
        case activeSessionId = "active_session_id"
    }
}
```

### Step 2: Build to verify

Run: `cd /Users/aaron/Desktop/max/ios-voice-app/ClaudeVoice && xcodebuild -scheme ClaudeVoice -destination 'platform=iOS Simulator,name=iPhone 16' build 2>&1 | tail -10`
Expected: BUILD SUCCEEDED

### Step 3: Commit

```bash
git add ios-voice-app/ClaudeVoice/ClaudeVoice/Models/Session.swift
git commit -m "feat: add VSCodeStatus model for sync detection"
```

---

## Task 4: Add VSCode Status Tracking to WebSocketManager

Track VSCode status and active session in WebSocketManager.

**Files:**
- Modify: `ios-voice-app/ClaudeVoice/ClaudeVoice/Services/WebSocketManager.swift`

### Step 1: Add published properties and callback

```swift
// Add published properties to WebSocketManager class:
    @Published var vscodeConnected: Bool = false
    @Published var activeSessionId: String? = nil

// Add callback:
    var onVSCodeStatusReceived: ((VSCodeStatus) -> Void)?

// In handleMessage, add decoding for VSCode status (in the if/else chain):
            } else if let vscodeStatus = try? JSONDecoder().decode(VSCodeStatus.self, from: data) {
                logToFile("✅ Decoded as VSCodeStatus: connected=\(vscodeStatus.vscodeConnected), session=\(vscodeStatus.activeSessionId ?? "none")")
                DispatchQueue.main.async {
                    self.vscodeConnected = vscodeStatus.vscodeConnected
                    self.activeSessionId = vscodeStatus.activeSessionId
                    self.onVSCodeStatusReceived?(vscodeStatus)
                }
            }
```

### Step 2: Build to verify

Run: `cd /Users/aaron/Desktop/max/ios-voice-app/ClaudeVoice && xcodebuild -scheme ClaudeVoice -destination 'platform=iOS Simulator,name=iPhone 16' build 2>&1 | tail -10`
Expected: BUILD SUCCEEDED

### Step 3: Commit

```bash
git add ios-voice-app/ClaudeVoice/ClaudeVoice/Services/WebSocketManager.swift
git commit -m "feat: add VSCode status tracking to WebSocketManager"
```

---

## Task 5: Update SessionView with Sync Detection UI

Update SessionView to show connected status and conditional open button.

**Files:**
- Modify: `ios-voice-app/ClaudeVoice/ClaudeVoice/Views/SessionView.swift`

### Step 1: Update toolbar with sync-aware buttons

Replace the toolbar in SessionView:

```swift
// Replace the toolbar section:
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                HStack(spacing: 16) {
                    // Show connected indicator OR open button based on sync state
                    if isSessionActive {
                        // Connected indicator - this session is open in VSCode
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                            .accessibilityLabel("Session Active in VSCode")
                    } else {
                        // Open button - session not active, allow opening
                        Button(action: resumeSession) {
                            Image(systemName: "arrow.up.forward.app")
                        }
                        .disabled(isResuming || !webSocketManager.vscodeConnected)
                        .accessibilityLabel("Open in VSCode")
                    }

                    // Close button - only show when this session is active
                    if isSessionActive {
                        Button(action: closeSession) {
                            Image(systemName: "xmark.circle")
                        }
                        .disabled(isClosing)
                        .accessibilityLabel("Close Session")
                    }

                    Button(action: { showingSettings = true }) {
                        Image(systemName: "gearshape.fill")
                    }
                }
            }
        }

// Add computed property:
    private var isSessionActive: Bool {
        webSocketManager.activeSessionId == session.id
    }
```

### Step 2: Build to verify

Run: `cd /Users/aaron/Desktop/max/ios-voice-app/ClaudeVoice && xcodebuild -scheme ClaudeVoice -destination 'platform=iOS Simulator,name=iPhone 16' build 2>&1 | tail -10`
Expected: BUILD SUCCEEDED

### Step 3: Commit

```bash
git add ios-voice-app/ClaudeVoice/ClaudeVoice/Views/SessionView.swift
git commit -m "feat: add sync detection UI to SessionView"
```

---

## Task 6: Update SessionsListView with Active Indicator

Show which session is active in the sessions list.

**Files:**
- Modify: `ios-voice-app/ClaudeVoice/ClaudeVoice/Views/SessionsListView.swift`

### Step 1: Read current SessionsListView

Run: Read the file first to see current structure.

### Step 2: Add active indicator to list items

```swift
// In SessionsListView, update the NavigationLink row to show active indicator:
                    NavigationLink(destination: SessionView(
                        webSocketManager: webSocketManager,
                        project: project,
                        session: session
                    )) {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(session.title)
                                    .font(.headline)
                                Text(session.formattedDate)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }

                            Spacer()

                            // Show active indicator if this session is open in VSCode
                            if webSocketManager.activeSessionId == session.id {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundColor(.green)
                                    .accessibilityLabel("Active in VSCode")
                            }
                        }
                    }
```

### Step 3: Build to verify

Run: `cd /Users/aaron/Desktop/max/ios-voice-app/ClaudeVoice && xcodebuild -scheme ClaudeVoice -destination 'platform=iOS Simulator,name=iPhone 16' build 2>&1 | tail -10`
Expected: BUILD SUCCEEDED

### Step 4: Commit

```bash
git add ios-voice-app/ClaudeVoice/ClaudeVoice/Views/SessionsListView.swift
git commit -m "feat: add active session indicator to SessionsListView"
```

---

## Task 7: Run All Python Tests

Verify all server tests pass.

### Step 1: Run all tests

Run: `cd /Users/aaron/Desktop/max/voice_server && python -m pytest tests/ -v`
Expected: All tests pass

### Step 2: Fix any failures

If tests fail, debug and fix them.

### Step 3: Commit any fixes

```bash
git add -A
git commit -m "fix: resolve test failures"
```

---

## Task 8: Run iOS Build and Tests

Verify iOS app builds and tests pass.

### Step 1: Build iOS app

Run: `cd /Users/aaron/Desktop/max/ios-voice-app/ClaudeVoice && xcodebuild -scheme ClaudeVoice -destination 'platform=iOS Simulator,name=iPhone 16' build 2>&1 | tail -20`
Expected: BUILD SUCCEEDED

### Step 2: Run iOS unit tests

Run: `cd /Users/aaron/Desktop/max/ios-voice-app/ClaudeVoice && xcodebuild test -scheme ClaudeVoice -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:ClaudeVoiceTests 2>&1 | tail -30`
Expected: Tests pass

### Step 3: Commit any fixes

```bash
git add -A
git commit -m "fix: resolve iOS build/test issues"
```

---

## Task 9: Manual Integration Test

Test the full flow manually to verify VSCode sync detection works.

### Checklist:

1. **Start server:**
   ```bash
   cd /Users/aaron/Desktop/max/voice_server
   source ../.venv/bin/activate
   python ios_server.py
   ```
   - Should see "✅ Connected to VSCode extension"

2. **Connect iOS app:**
   - Open app and connect to server
   - Should receive `vscode_status` message (check logs)

3. **Test sync detection flow:**
   - Navigate to a session in the app
   - Should see "Open in VSCode" button (arrow.up.forward.app icon)
   - Tap to open → should run `claude --resume <id>`
   - Session should now show green checkmark (checkmark.circle.fill)
   - Close button (xmark.circle) should appear

4. **Test close flow:**
   - Tap close button
   - Green checkmark should disappear
   - "Open in VSCode" button should reappear

5. **Test sessions list:**
   - Go back to sessions list
   - Active session should show green checkmark indicator
   - Other sessions should not have indicator

---

## Summary

This plan implements VSCode sync detection with these UI changes:

| State | Icon | Location |
|-------|------|----------|
| Session active in VSCode | `checkmark.circle.fill` (green) | SessionView toolbar, SessionsListView row |
| Session not active | `arrow.up.forward.app` | SessionView toolbar (Open button) |
| Close active session | `xmark.circle` | SessionView toolbar (only when active) |
| VSCode disconnected | Open button disabled | SessionView toolbar |

**Icon choices rationale:**
- `checkmark.circle.fill` - Standard iOS "active/connected" indicator
- `arrow.up.forward.app` - Standard iOS "open in app" icon
- `xmark.circle` - Standard iOS "close/dismiss" icon
- NOT using `play.fill`/`stop.fill` as those imply media playback
