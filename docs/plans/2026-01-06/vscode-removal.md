# VSCode Removal Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use execute-plan to implement this plan task-by-task.

**Goal:** Replace VSCode terminal integration with tmux for headless Claude Code control.

**Architecture:** Server will use subprocess calls to tmux instead of WebSocket connection to VSCode extension. All VSCode references in iOS/server renamed to generic "connected" terminology.

**Tech Stack:** Python (tmux subprocess), Swift (iOS app), pytest, XCTest

---

## Task 1: Create TmuxController with Tests

**Files:**
- Create: `voice_server/tmux_controller.py`
- Create: `voice_server/tests/test_tmux_controller.py`

**Step 1: Write the failing test for is_available**

```python
# voice_server/tests/test_tmux_controller.py
import pytest
from unittest.mock import patch, MagicMock


class TestTmuxControllerAvailability:
    """Tests for TmuxController availability check"""

    def test_is_available_returns_true_when_tmux_installed(self):
        """Should return True when tmux command succeeds"""
        from tmux_controller import TmuxController

        controller = TmuxController()

        with patch('subprocess.run') as mock_run:
            mock_run.return_value = MagicMock(returncode=0)
            assert controller.is_available() is True
            mock_run.assert_called_once()

    def test_is_available_returns_false_when_tmux_not_installed(self):
        """Should return False when tmux command fails"""
        from tmux_controller import TmuxController

        controller = TmuxController()

        with patch('subprocess.run') as mock_run:
            mock_run.return_value = MagicMock(returncode=1)
            assert controller.is_available() is False
```

**Step 2: Run test to verify it fails**

```bash
cd voice_server/tests && ./run_tests.sh test_tmux_controller.py -v
```

Expected: FAIL with "ModuleNotFoundError: No module named 'tmux_controller'"

**Step 3: Write minimal TmuxController implementation**

```python
# voice_server/tmux_controller.py
"""Tmux-based Claude Code session control"""

import subprocess
from typing import Optional


class TmuxController:
    """Controls Claude Code sessions via tmux subprocess calls"""

    SESSION_NAME = "claude_voice"

    def is_available(self) -> bool:
        """Check if tmux is installed and available"""
        result = subprocess.run(
            ["tmux", "-V"],
            capture_output=True,
            text=True
        )
        return result.returncode == 0
```

**Step 4: Run test to verify it passes**

```bash
cd voice_server/tests && ./run_tests.sh test_tmux_controller.py::TestTmuxControllerAvailability -v
```

Expected: PASS

**Step 5: Write test for session_exists**

Add to `test_tmux_controller.py`:

```python
class TestTmuxControllerSession:
    """Tests for TmuxController session management"""

    def test_session_exists_returns_true_when_session_running(self):
        """Should return True when tmux session exists"""
        from tmux_controller import TmuxController

        controller = TmuxController()

        with patch('subprocess.run') as mock_run:
            mock_run.return_value = MagicMock(returncode=0)
            assert controller.session_exists() is True
            mock_run.assert_called_with(
                ["tmux", "has-session", "-t", "claude_voice"],
                capture_output=True,
                text=True
            )

    def test_session_exists_returns_false_when_no_session(self):
        """Should return False when tmux session doesn't exist"""
        from tmux_controller import TmuxController

        controller = TmuxController()

        with patch('subprocess.run') as mock_run:
            mock_run.return_value = MagicMock(returncode=1)
            assert controller.session_exists() is False
```

**Step 6: Run test to verify it fails**

```bash
cd voice_server/tests && ./run_tests.sh test_tmux_controller.py::TestTmuxControllerSession -v
```

Expected: FAIL

**Step 7: Implement session_exists**

Add to `tmux_controller.py`:

```python
    def session_exists(self) -> bool:
        """Check if the claude_voice tmux session is running"""
        result = subprocess.run(
            ["tmux", "has-session", "-t", self.SESSION_NAME],
            capture_output=True,
            text=True
        )
        return result.returncode == 0
```

**Step 8: Run test to verify it passes**

```bash
cd voice_server/tests && ./run_tests.sh test_tmux_controller.py::TestTmuxControllerSession -v
```

Expected: PASS

**Step 9: Write test for start_session**

Add to `test_tmux_controller.py`:

```python
class TestTmuxControllerStartSession:
    """Tests for starting tmux sessions"""

    def test_start_session_creates_new_tmux_session(self):
        """Should create tmux session running claude"""
        from tmux_controller import TmuxController

        controller = TmuxController()

        with patch('subprocess.run') as mock_run:
            # First call: has-session (doesn't exist)
            # Second call: new-session
            mock_run.side_effect = [
                MagicMock(returncode=1),  # has-session fails
                MagicMock(returncode=0),  # new-session succeeds
            ]

            result = controller.start_session()

            assert result is True
            assert mock_run.call_count == 2

    def test_start_session_kills_existing_first(self):
        """Should kill existing session before starting new one"""
        from tmux_controller import TmuxController

        controller = TmuxController()

        with patch('subprocess.run') as mock_run:
            # First call: has-session (exists)
            # Second call: kill-session
            # Third call: new-session
            mock_run.side_effect = [
                MagicMock(returncode=0),  # has-session succeeds
                MagicMock(returncode=0),  # kill-session succeeds
                MagicMock(returncode=0),  # new-session succeeds
            ]

            result = controller.start_session()

            assert result is True
            assert mock_run.call_count == 3

    def test_start_session_with_resume_id(self):
        """Should run claude --resume when resume_id provided"""
        from tmux_controller import TmuxController

        controller = TmuxController()

        with patch('subprocess.run') as mock_run:
            mock_run.side_effect = [
                MagicMock(returncode=1),  # has-session fails
                MagicMock(returncode=0),  # new-session succeeds
            ]

            result = controller.start_session(resume_id="abc123")

            assert result is True
            # Verify the claude --resume command was used
            new_session_call = mock_run.call_args_list[1]
            assert "--resume" in str(new_session_call)
            assert "abc123" in str(new_session_call)

    def test_start_session_with_working_dir(self):
        """Should set working directory when provided"""
        from tmux_controller import TmuxController

        controller = TmuxController()

        with patch('subprocess.run') as mock_run:
            mock_run.side_effect = [
                MagicMock(returncode=1),
                MagicMock(returncode=0),
            ]

            result = controller.start_session(working_dir="/some/path")

            assert result is True
            new_session_call = mock_run.call_args_list[1]
            assert "-c" in str(new_session_call)
            assert "/some/path" in str(new_session_call)
```

**Step 10: Run test to verify it fails**

```bash
cd voice_server/tests && ./run_tests.sh test_tmux_controller.py::TestTmuxControllerStartSession -v
```

Expected: FAIL

**Step 11: Implement start_session**

Add to `tmux_controller.py`:

```python
    def start_session(self, working_dir: Optional[str] = None, resume_id: Optional[str] = None) -> bool:
        """Start a new tmux session running Claude Code

        Args:
            working_dir: Directory to start the session in
            resume_id: If set, runs 'claude --resume <id>'

        Returns:
            True if session started successfully
        """
        # Kill existing session first (one at a time)
        if self.session_exists():
            self.kill_session()

        # Build the claude command
        if resume_id:
            cmd = f"claude --resume {resume_id}"
        else:
            cmd = "claude"

        # Build tmux command
        tmux_cmd = [
            "tmux", "new-session",
            "-d",  # Detached
            "-s", self.SESSION_NAME,
        ]

        if working_dir:
            tmux_cmd.extend(["-c", working_dir])

        tmux_cmd.append(cmd)

        result = subprocess.run(tmux_cmd, capture_output=True, text=True)
        return result.returncode == 0
```

**Step 12: Run test to verify it passes**

```bash
cd voice_server/tests && ./run_tests.sh test_tmux_controller.py::TestTmuxControllerStartSession -v
```

Expected: PASS

**Step 13: Write test for send_input**

Add to `test_tmux_controller.py`:

```python
class TestTmuxControllerInput:
    """Tests for sending input to tmux sessions"""

    def test_send_input_sends_keys_to_session(self):
        """Should send text + Enter to tmux session as separate calls"""
        from tmux_controller import TmuxController

        controller = TmuxController()

        with patch('subprocess.run') as mock_run:
            mock_run.return_value = MagicMock(returncode=0)

            result = controller.send_input("hello world")

            assert result is True
            assert mock_run.call_count == 2
            # First call: send text
            first_call = mock_run.call_args_list[0][0][0]
            assert "send-keys" in first_call
            assert "hello world" in first_call
            # Second call: send Enter
            second_call = mock_run.call_args_list[1][0][0]
            assert "Enter" in second_call

    def test_send_input_returns_false_on_failure(self):
        """Should return False when send-keys fails"""
        from tmux_controller import TmuxController

        controller = TmuxController()

        with patch('subprocess.run') as mock_run:
            mock_run.return_value = MagicMock(returncode=1)

            result = controller.send_input("test")

            assert result is False
```

**Step 14: Run test to verify it fails**

```bash
cd voice_server/tests && ./run_tests.sh test_tmux_controller.py::TestTmuxControllerInput -v
```

Expected: FAIL

**Step 15: Implement send_input**

Add to `tmux_controller.py`:

```python
    def send_input(self, text: str) -> bool:
        """Send text input to the Claude session

        Args:
            text: Text to send (Enter key added automatically)

        Returns:
            True if sent successfully
        """
        # Send text and Enter as separate calls - combining them causes
        # tmux to misinterpret Enter as a literal string
        result1 = subprocess.run(
            ["tmux", "send-keys", "-t", self.SESSION_NAME, text],
            capture_output=True,
            text=True
        )
        if result1.returncode != 0:
            return False

        result2 = subprocess.run(
            ["tmux", "send-keys", "-t", self.SESSION_NAME, "Enter"],
            capture_output=True,
            text=True
        )
        return result2.returncode == 0
```

**Step 16: Run test to verify it passes**

```bash
cd voice_server/tests && ./run_tests.sh test_tmux_controller.py::TestTmuxControllerInput -v
```

Expected: PASS

**Step 17: Write test for kill_session**

Add to `test_tmux_controller.py`:

```python
class TestTmuxControllerKill:
    """Tests for killing tmux sessions"""

    def test_kill_session_kills_tmux_session(self):
        """Should kill the claude_voice tmux session"""
        from tmux_controller import TmuxController

        controller = TmuxController()

        with patch('subprocess.run') as mock_run:
            mock_run.return_value = MagicMock(returncode=0)

            result = controller.kill_session()

            assert result is True
            mock_run.assert_called_with(
                ["tmux", "kill-session", "-t", "claude_voice"],
                capture_output=True,
                text=True
            )

    def test_kill_session_returns_false_on_failure(self):
        """Should return False when kill fails"""
        from tmux_controller import TmuxController

        controller = TmuxController()

        with patch('subprocess.run') as mock_run:
            mock_run.return_value = MagicMock(returncode=1)

            result = controller.kill_session()

            assert result is False
```

**Step 18: Run test to verify it fails**

```bash
cd voice_server/tests && ./run_tests.sh test_tmux_controller.py::TestTmuxControllerKill -v
```

Expected: FAIL

**Step 19: Implement kill_session**

Add to `tmux_controller.py`:

```python
    def kill_session(self) -> bool:
        """Kill the active Claude session

        Returns:
            True if killed successfully
        """
        result = subprocess.run(
            ["tmux", "kill-session", "-t", self.SESSION_NAME],
            capture_output=True,
            text=True
        )
        return result.returncode == 0
```

**Step 20: Run all TmuxController tests**

```bash
cd voice_server/tests && ./run_tests.sh test_tmux_controller.py -v
```

Expected: All PASS

**Step 21: Commit**

```bash
git add voice_server/tmux_controller.py voice_server/tests/test_tmux_controller.py
git commit -m "feat: add TmuxController for headless Claude Code control"
```

---

## Task 2: Update iOS Model - ConnectionStatus

**Files:**
- Modify: `ios-voice-app/ClaudeVoice/ClaudeVoice/Models/Session.swift:63-73`

**Step 1: Rename VSCodeStatus to ConnectionStatus**

Replace the VSCodeStatus struct:

```swift
struct ConnectionStatus: Codable {
    let type: String
    let connected: Bool
    let activeSessionId: String?

    enum CodingKeys: String, CodingKey {
        case type
        case connected
        case activeSessionId = "active_session_id"
    }
}
```

**Step 2: Build to check for errors**

```bash
cd ios-voice-app/ClaudeVoice && xcodebuild build -scheme ClaudeVoice -destination 'platform=iOS Simulator,name=iPhone 16' 2>&1 | grep -E "error:|warning:"
```

Expected: Errors about VSCodeStatus not found (will fix in next tasks)

**Step 3: Commit**

```bash
git add ios-voice-app/ClaudeVoice/ClaudeVoice/Models/Session.swift
git commit -m "refactor: rename VSCodeStatus to ConnectionStatus"
```

---

## Task 3: Update iOS WebSocketManager

**Files:**
- Modify: `ios-voice-app/ClaudeVoice/ClaudeVoice/Services/WebSocketManager.swift`

**Step 1: Rename vscodeConnected property**

Change line 13:

```swift
@Published var connected: Bool = false
```

**Step 2: Rename callback**

Change line 25:

```swift
var onConnectionStatusReceived: ((ConnectionStatus) -> Void)?
```

**Step 3: Update handleMessage for string messages**

Replace VSCodeStatus decoding (around line 333-339):

```swift
} else if let connectionStatus = try? JSONDecoder().decode(ConnectionStatus.self, from: data) {
    logToFile("Decoded as ConnectionStatus: connected=\(connectionStatus.connected), session=\(connectionStatus.activeSessionId ?? "none")")
    DispatchQueue.main.async {
        self.connected = connectionStatus.connected
        self.activeSessionId = connectionStatus.activeSessionId
        self.onConnectionStatusReceived?(connectionStatus)
    }
}
```

**Step 4: Update handleMessage for binary messages**

Replace VSCodeStatus decoding (around line 389-394):

```swift
} else if let connectionStatus = try? JSONDecoder().decode(ConnectionStatus.self, from: data) {
    DispatchQueue.main.async {
        self.connected = connectionStatus.connected
        self.activeSessionId = connectionStatus.activeSessionId
        self.onConnectionStatusReceived?(connectionStatus)
    }
}
```

**Step 5: Build to check progress**

```bash
cd ios-voice-app/ClaudeVoice && xcodebuild build -scheme ClaudeVoice -destination 'platform=iOS Simulator,name=iPhone 16' 2>&1 | grep -E "error:|warning:"
```

Expected: Errors in SessionView (will fix next)

**Step 6: Commit**

```bash
git add ios-voice-app/ClaudeVoice/ClaudeVoice/Services/WebSocketManager.swift
git commit -m "refactor: rename vscodeConnected to connected in WebSocketManager"
```

---

## Task 4: Update iOS SessionView

**Files:**
- Modify: `ios-voice-app/ClaudeVoice/ClaudeVoice/Views/SessionView.swift`

**Step 1: Update sync status text**

Change line 66:

```swift
Text("Syncing...")
```

**Step 2: Update accessibility label**

Change line 122:

```swift
.accessibilityLabel("Synced")
```

**Step 3: Update syncSession error message**

Change line 310:

```swift
syncError = "Not connected"
```

**Step 4: Update isSessionSynced to use connected**

Change line 184:

```swift
return webSocketManager.connected && webSocketManager.activeSessionId == nil
```

**Step 5: Update syncSession guard**

Change line 309:

```swift
guard webSocketManager.connected else {
```

**Step 6: Build to verify**

```bash
cd ios-voice-app/ClaudeVoice && xcodebuild build -scheme ClaudeVoice -destination 'platform=iOS Simulator,name=iPhone 16' 2>&1 | grep -E "error:|warning:"
```

Expected: No errors

**Step 7: Commit**

```bash
git add ios-voice-app/ClaudeVoice/ClaudeVoice/Views/SessionView.swift
git commit -m "refactor: update SessionView for generic connection status"
```

---

## Task 5: Update iOS SessionsListView

**Files:**
- Modify: `ios-voice-app/ClaudeVoice/ClaudeVoice/Views/SessionsListView.swift`

**Step 1: Find and update VSCode references**

Search for "VSCode" and update accessibility labels:

Change "Active in VSCode" to "Active session":

```swift
.accessibilityLabel("Active session")
```

**Step 2: Update vscodeConnected references**

Change any `vscodeConnected` to `connected`.

**Step 3: Build to verify**

```bash
cd ios-voice-app/ClaudeVoice && xcodebuild build -scheme ClaudeVoice -destination 'platform=iOS Simulator,name=iPhone 16' 2>&1 | grep -E "error:|warning:"
```

Expected: No errors

**Step 4: Commit**

```bash
git add ios-voice-app/ClaudeVoice/ClaudeVoice/Views/SessionsListView.swift
git commit -m "refactor: update SessionsListView for generic connection status"
```

---

## Task 6: Update Server - Replace VSCodeController with TmuxController

**Files:**
- Modify: `voice_server/ios_server.py`

**Step 1: Update imports**

Change line 26:

```python
from tmux_controller import TmuxController
```

**Step 2: Update VoiceServer.__init__**

Change line 188:

```python
self.tmux = TmuxController()
```

**Step 3: Remove send_to_vs_code_applescript method**

Delete lines 293-307 (the entire `send_to_vs_code_applescript` method).

**Step 4: Replace send_to_vs_code with send_to_terminal**

Replace the `send_to_vs_code` method:

```python
async def send_to_terminal(self, text: str):
    """Send text to Claude Code terminal via tmux"""
    self.tmux.send_input(text)
```

**Step 5: Update handle_voice_input**

Change line 374 to use new method:

```python
await self.send_to_terminal(text)
```

Also update print statements on lines 368 and 375:

```python
print(f"[{time.strftime('%H:%M:%S')}] Sending to terminal...")
```

```python
print(f"[{time.strftime('%H:%M:%S')}] Sent to terminal successfully")
```

**Step 6: Rename send_vscode_status to send_connection_status**

Rename method and update JSON:

```python
async def send_connection_status(self, websocket):
    """Send connection status to a single client"""
    response = {
        "type": "connection_status",
        "connected": self.tmux.session_exists(),
        "active_session_id": self.active_session_id
    }
    await websocket.send(json.dumps(response))
```

**Step 7: Rename broadcast_vscode_status to broadcast_connection_status**

```python
async def broadcast_connection_status(self):
    """Broadcast connection status to all connected clients"""
    for websocket in list(self.clients):
        try:
            await self.send_connection_status(websocket)
        except Exception as e:
            print(f"Error broadcasting status: {e}")
```

**Step 8: Update handle_close_session**

```python
async def handle_close_session(self, websocket):
    """Handle close_session request - kills the active tmux session"""
    success = self.tmux.kill_session()
    if success:
        self.active_session_id = None

    response = {
        "type": "session_closed",
        "success": success
    }
    await websocket.send(json.dumps(response))

    if success:
        await self.broadcast_connection_status()
```

**Step 9: Update handle_new_session**

```python
async def handle_new_session(self, websocket, data):
    """Handle new_session request - starts claude in tmux"""
    project_path = data.get("project_path", "")
    success = self.tmux.start_session(working_dir=project_path if project_path else None)

    if success:
        self.active_session_id = None  # New session has no ID yet
        await asyncio.sleep(2.0)  # Wait for Claude to initialize

    response = {
        "type": "session_created",
        "success": success
    }
    await websocket.send(json.dumps(response))

    if success:
        await self.broadcast_connection_status()
```

**Step 10: Update handle_resume_session**

```python
async def handle_resume_session(self, websocket, data):
    """Handle resume_session request - runs 'claude --resume <id>' in tmux"""
    session_id = data.get("session_id", "")
    folder_name = data.get("folder_name", "")
    success = False

    if session_id:
        success = self.tmux.start_session(resume_id=session_id)

        if success:
            self.active_session_id = session_id
            await asyncio.sleep(2.0)  # Wait for Claude to initialize
            if folder_name:
                self.switch_watched_session(folder_name, session_id)

    response = {
        "type": "session_resumed",
        "success": success,
        "session_id": session_id
    }
    await websocket.send(json.dumps(response))

    if success:
        await self.broadcast_connection_status()
```

**Step 11: Update handle_add_project**

```python
async def handle_add_project(self, websocket, data):
    """Handle add_project request - creates directory and starts Claude"""
    name = data.get("name", "").strip()
    success = False
    project_path = ""

    if not name:
        response = {
            "type": "project_created",
            "success": False,
            "error": "Project name is required"
        }
        await websocket.send(json.dumps(response))
        return

    safe_name = "".join(c for c in name if c.isalnum() or c in "-_.")
    project_path = os.path.join(self.projects_base_path, safe_name)

    try:
        os.makedirs(project_path, exist_ok=True)
        success = self.tmux.start_session(working_dir=project_path)

        if success:
            await asyncio.sleep(2.0)  # Wait for Claude to initialize
            # Send Enter to accept any prompts
            self.tmux.send_input("")

    except Exception as e:
        print(f"Error creating project: {e}")

    response = {
        "type": "project_created",
        "success": success,
        "path": project_path,
        "name": safe_name
    }
    await websocket.send(json.dumps(response))
```

**Step 12: Update inject_terminal_response**

```python
async def inject_terminal_response(self, decision, data):
    """Inject permission response into terminal after timeout"""
    if decision == "allow":
        text = data.get('input', 'y')
    else:
        text = 'n'

    self.tmux.send_input(text)
    print(f"Injected late response: {text}")
```

**Step 13: Update handle_client**

Change line 696:

```python
await self.send_connection_status(websocket)
```

**Step 14: Update start method**

Remove VSCode connection logic. Replace lines 712-717:

```python
# Check tmux availability
if not self.tmux.is_available():
    print("WARNING: tmux not installed. Install with: brew install tmux")
else:
    print("tmux available for session management")
```

**Step 15: Run server tests**

```bash
cd voice_server/tests && ./run_tests.sh test_ios_server.py -v
```

Expected: Some failures (tests still reference VSCode)

**Step 16: Commit**

```bash
git add voice_server/ios_server.py
git commit -m "refactor: replace VSCodeController with TmuxController"
```

---

## Task 7: Update Server Tests

**Files:**
- Modify: `voice_server/tests/test_ios_server.py`
- Modify: `voice_server/tests/test_message_handlers.py`
- Modify: `voice_server/tests/test_message_formats.py`
- Modify: `voice_server/tests/test_state_validation.py`
- Delete: `voice_server/tests/test_vscode_controller.py`

**Step 1: Update test_message_formats.py**

Replace `test_vscode_status_message_format`:

```python
def test_connection_status_message_format(self):
    """Verify connection_status message has required fields"""
    message = {
        "type": "connection_status",
        "connected": True,
        "active_session_id": "abc123"
    }
    assert message["type"] == "connection_status"
    assert isinstance(message["connected"], bool)
```

**Step 2: Update test_state_validation.py**

Replace `vscode_controller` with `tmux`:

```python
server.tmux = MagicMock()
server.tmux.session_exists.return_value = False
```

**Step 3: Update test_message_handlers.py**

Replace all `vscode_controller` references with `tmux` and update method names:

- `vscode_controller.is_connected()` -> `tmux.session_exists()`
- `vscode_controller.send_sequence(text)` -> `tmux.send_input(text)`
- `vscode_controller.kill_terminal()` -> `tmux.kill_session()`
- `vscode_controller.new_terminal()` -> (remove, absorbed into start_session)
- `vscode_controller.open_folder()` -> (remove, absorbed into start_session)

Update class name `TestVoiceInputWithVSCode` -> `TestVoiceInputWithTmux`

Update class name `TestVSCodeStatusBroadcast` -> `TestConnectionStatusBroadcast`

Update message type checks: `"vscode_status"` -> `"connection_status"`
Update field checks: `"vscode_connected"` -> `"connected"`

**Step 4: Update test_ios_server.py**

Replace VSCode references:

```python
server.tmux = MagicMock()
server.tmux.session_exists.return_value = True
```

Update message type: `"vscode_status"` -> `"connection_status"`

**Step 5: Delete test_vscode_controller.py**

```bash
rm voice_server/tests/test_vscode_controller.py
```

**Step 6: Run all server tests**

```bash
cd voice_server/tests && ./run_tests.sh -v
```

Expected: All PASS

**Step 7: Commit**

```bash
git add voice_server/tests/
git rm voice_server/tests/test_vscode_controller.py
git commit -m "refactor: update server tests for tmux-based controller"
```

---

## Task 8: Update iOS Unit Tests

**Files:**
- Modify: `ios-voice-app/ClaudeVoice/ClaudeVoiceTests/ClaudeVoiceTests.swift`
- Modify: `ios-voice-app/ClaudeVoice/ClaudeVoiceTests/WebSocketManagerTests.swift`

**Step 1: Update ClaudeVoiceTests.swift**

Rename test suite and update tests:

```swift
@Suite("ConnectionStatus Model Tests")
struct ConnectionStatusModelTests {

    @Test func testConnectionStatusDecoding() throws {
        let json = """
        {
            "type": "connection_status",
            "connected": true,
            "active_session_id": "abc123"
        }
        """.data(using: .utf8)!

        let status = try JSONDecoder().decode(ConnectionStatus.self, from: json)

        #expect(status.type == "connection_status")
        #expect(status.connected == true)
        #expect(status.activeSessionId == "abc123")
    }

    @Test func testConnectionStatusDecodingWithNullSession() throws {
        let json = """
        {
            "type": "connection_status",
            "connected": true,
            "active_session_id": null
        }
        """.data(using: .utf8)!

        let status = try JSONDecoder().decode(ConnectionStatus.self, from: json)

        #expect(status.connected == true)
        #expect(status.activeSessionId == nil)
    }

    @Test func testConnectionStatusDecodingDisconnected() throws {
        let json = """
        {
            "type": "connection_status",
            "connected": false,
            "active_session_id": null
        }
        """.data(using: .utf8)!

        let status = try JSONDecoder().decode(ConnectionStatus.self, from: json)

        #expect(status.connected == false)
    }
}
```

**Step 2: Update WebSocketManagerTests.swift**

Rename section and update property names:

```swift
// MARK: - Connection Status Tests

@Test func testConnectedPublishedProperty() throws {
    let manager = WebSocketManager()

    #expect(manager.connected == false)

    manager.$connected
        .sink { _ in }
        .cancel()

    manager.connected = true
    #expect(manager.connected == true)

    manager.connected = false
    #expect(manager.connected == false)
}

@Test func testOnConnectionStatusReceivedCallback() throws {
    let manager = WebSocketManager()
    var receivedStatus: ConnectionStatus?

    manager.onConnectionStatusReceived = { status in
        receivedStatus = status
    }

    #expect(manager.onConnectionStatusReceived != nil)

    let mockStatus = ConnectionStatus(
        type: "connection_status",
        connected: true,
        activeSessionId: "test-session"
    )

    manager.onConnectionStatusReceived?(mockStatus)

    #expect(receivedStatus?.connected == true)
    #expect(receivedStatus?.activeSessionId == "test-session")
}

@Test func testConnectionStatusUpdatesProperties() throws {
    let manager = WebSocketManager()

    let status = ConnectionStatus(
        type: "connection_status",
        connected: true,
        activeSessionId: "session-xyz"
    )

    manager.connected = status.connected
    manager.activeSessionId = status.activeSessionId

    #expect(manager.connected == true)
    #expect(manager.activeSessionId == "session-xyz")
}

@Test func testConnectionStatusClearsOnDisconnect() throws {
    let manager = WebSocketManager()

    manager.connected = true
    manager.activeSessionId = "test"

    #expect(manager.connected == true)

    manager.connected = false
    manager.activeSessionId = nil

    #expect(manager.connected == false)
    #expect(manager.activeSessionId == nil)
}
```

**Step 3: Run iOS unit tests**

```bash
cd ios-voice-app/ClaudeVoice && xcodebuild test -scheme ClaudeVoice -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:ClaudeVoiceTests 2>&1 | tail -20
```

Expected: All tests pass

**Step 4: Commit**

```bash
git add ios-voice-app/ClaudeVoice/ClaudeVoiceTests/
git commit -m "refactor: update iOS unit tests for ConnectionStatus"
```

---

## Task 9: Update E2E Tests

**Files:**
- Rename: `ios-voice-app/ClaudeVoice/ClaudeVoiceUITests/E2EVSCodeFlowTests.swift` -> `E2ESessionFlowTests.swift`

**Step 1: Rename file**

```bash
cd ios-voice-app/ClaudeVoice/ClaudeVoiceUITests
git mv E2EVSCodeFlowTests.swift E2ESessionFlowTests.swift
```

**Step 2: Update class name and comments**

```swift
//
//  E2ESessionFlowTests.swift
//  ClaudeVoiceUITests
//
//  Comprehensive session sync test covering all sync scenarios
//

import XCTest

final class E2ESessionFlowTests: E2ETestBase {

    /// Complete session sync flow test
    /// Tests: Connect status -> Session sync -> Active indicators -> New session -> Switch sessions
    func test_complete_session_sync_flow() throws {
        // ... (update comments to remove VSCode references)
    }
}
```

**Step 3: Update accessibility label references**

Change:

```swift
let syncedIndicator = app.images["Synced"]
```

```swift
let activeIndicator = app.images["Active session"]
```

**Step 4: Update print statements**

Remove "VSCode" from debug output:

```swift
print("Phase 1: Connection status")
print("Phase 2: Session sync")
// etc.
```

**Step 5: Commit**

```bash
git add ios-voice-app/ClaudeVoice/ClaudeVoiceUITests/
git commit -m "refactor: rename E2E tests to remove VSCode references"
```

---

## Task 10: Clean Up and Documentation

**Files:**
- Delete: `voice_server/vscode_controller.py`
- Modify: `CLAUDE.md`
- Modify: `README.md`

**Step 1: Delete vscode_controller.py**

```bash
git rm voice_server/vscode_controller.py
```

**Step 2: Update CLAUDE.md architecture diagram**

Replace the architecture section:

```markdown
## Architecture

```
iPhone App                         Mac Server
├─ Speech Recognition              ├─ WebSocket Server (port 8765)
├─ WebSocket Client ──────────────>├─ Receives voice input
├─ Audio Player <──────────────────├─ Streams TTS audio (Kokoro)
├─ Session/Project Browser         ├─ tmux session management
└─ Message History Display         └─ Transcript file watching
```
```

**Step 3: Update CLAUDE.md commands**

Update any VSCode references in debugging section if present.

**Step 4: Update README.md**

Search for "VSCode" and update or remove references.

**Step 5: Final build verification**

```bash
# Server tests
cd voice_server/tests && ./run_tests.sh -v

# iOS unit tests
cd ios-voice-app/ClaudeVoice && xcodebuild test -scheme ClaudeVoice -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:ClaudeVoiceTests 2>&1 | tail -20

# iOS build
cd ios-voice-app/ClaudeVoice && xcodebuild build -scheme ClaudeVoice -destination 'platform=iOS Simulator,name=iPhone 16' 2>&1 | grep -E "error:|warning:"
```

Expected: All pass, no errors

**Step 6: Commit**

```bash
git add CLAUDE.md README.md
git rm voice_server/vscode_controller.py
git commit -m "docs: update documentation for tmux-based architecture"
```

---

## Task 11: Fix Remaining VSCode References

**Files:**
- Modify: `ios-voice-app/README.md`
- Modify: `ios-voice-app/ClaudeVoice/run_e2e_tests.sh`
- Modify: `ios-voice-app/ClaudeVoice/ClaudeVoice/Views/SessionView.swift`

**Analysis:**

| File | Line | Issue | Severity |
|------|------|-------|----------|
| `ios-voice-app/README.md` | 3, 122, 168 | Describes old VSCode/AppleScript architecture | Medium |
| `run_e2e_tests.sh` | 32 | `E2EVSCodeFlowTests` in ALL_SUITES - **will break test runner** | **High** |
| `SessionView.swift` | 199 | Comment: "Auto-resume session in VSCode" | Low |
| `SessionView.swift` | 320 | Comment: "vscode_status broadcast" | Low |

**Step 1: Fix run_e2e_tests.sh (CRITICAL)**

Change line 32 from:
```bash
    "E2EVSCodeFlowTests"
```
to:
```bash
    "E2ESessionFlowTests"
```

**Step 2: Update SessionView.swift comments**

Line 199 - change:
```swift
// Auto-resume session in VSCode (only for existing sessions)
```
to:
```swift
// Auto-resume session in tmux (only for existing sessions)
```

Line 320 - change:
```swift
// Session synced - vscode_status broadcast will update activeSessionId
```
to:
```swift
// Session synced - connection_status broadcast will update activeSessionId
```

**Step 3: Update ios-voice-app/README.md**

Line 3 - change:
```markdown
iOS - hands-free voice interaction with Claude Code via VSCode
```
to:
```markdown
iOS - hands-free voice interaction with Claude Code via tmux
```

Line 122 - change:
```
├─ Sends to VS Code (AppleScript)
```
to:
```
├─ Sends to tmux session
```

Line 168 - change:
```markdown
- Sends text to VS Code via AppleScript (clipboard + paste)
```
to:
```markdown
- Sends text to Claude Code via tmux
```

**Step 4: Run iOS unit tests to verify**

```bash
cd ios-voice-app/ClaudeVoice && xcodebuild test -scheme ClaudeVoice -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:ClaudeVoiceTests 2>&1 | tail -5
```

Expected: TEST SUCCEEDED

**Step 5: Commit**

```bash
git add ios-voice-app/README.md ios-voice-app/ClaudeVoice/run_e2e_tests.sh ios-voice-app/ClaudeVoice/ClaudeVoice/Views/SessionView.swift
git commit -m "fix: update remaining VSCode references to tmux"
```

---

## Task 12: Fix E2E Tests to Test Real Behavior

**CRITICAL: If the test passes, it MUST work on a real device.**

The current E2E tests use mock injection (`injectAssistantResponse`, `transcript_injector.py`) which means tests can pass while real functionality is broken.

**Files:**
- Rewrite: `ios-voice-app/ClaudeVoice/ClaudeVoiceUITests/E2ETestBase.swift`
- Rewrite: `ios-voice-app/ClaudeVoice/ClaudeVoiceUITests/E2ESessionFlowTests.swift`
- Delete: `tests/e2e_support/transcript_injector.py`

**Step 1: Remove mock injection from E2ETestBase**

Delete these methods:
- `injectAssistantResponse`
- `injectUserMessage`
- `simulateConversationTurn`

These inject fake data into transcript files, bypassing the real flow.

**Step 2: Add real tmux verification to E2ETestBase**

Add method to verify tmux session exists:
```swift
func verifyTmuxSessionRunning() -> Bool {
    // Call server endpoint or check via shell
}
```

**Step 3: Rewrite E2ESessionFlowTests to test real flow**

Test should:
1. Connect to real server
2. Resume session (server starts real tmux with `claude --resume`)
3. Verify tmux session exists
4. Send voice input
5. Verify input arrives in tmux (via server endpoint that captures pane)
6. Write to transcript file (simulating Claude's response - this is OK)
7. Verify file watcher triggers TTS
8. Verify audio streams back to client

**Step 4: Delete transcript_injector.py**

```bash
rm tests/e2e_support/transcript_injector.py
```

This file encouraged mock injection instead of real testing.

**Step 5: Run E2E tests**

```bash
cd ios-voice-app/ClaudeVoice && ./run_e2e_tests.sh
```

**Step 6: Commit**

```bash
git add -A
git commit -m "fix: rewrite E2E tests to test real behavior"
```

---

## Task 13: Fix E2E Test Voice Input Issue

**Status:** COMPLETED

**Problem:** Voice input sent via `tmux send-keys` doesn't appear in Claude Code pane even though `send_input()` returns `True`.

**Root Causes Found:**
1. `send_input()` was sending text and Enter as separate subprocess calls - must use `&&` to chain them in a single shell command
2. E2E test fixtures used invalid encoded folder names (`-e2e_test_project1`) that decoded to non-existent paths (`/e2e_test_project1`)

**Fixes Applied:**
1. Changed `tmux_controller.py:send_input()` to use single shell command with `&&`:
   ```python
   cmd = f"tmux send-keys -t {self.SESSION_NAME} '{escaped_text}' && tmux send-keys -t {self.SESSION_NAME} Enter"
   result = subprocess.run(cmd, shell=True, capture_output=True, text=True)
   ```

2. Fixed E2E test fixtures to use valid encoded paths:
   - Folder name: `-tmp-e2e_test_project1` (decodes to `/tmp/e2e_test_project1`)
   - Test now creates actual directories at `/tmp/e2e_test_project1` and `/tmp/e2e_test_project2`

**Files Changed:**
- `voice_server/tmux_controller.py` - Fixed send_input to chain commands
- `ios-voice-app/ClaudeVoice/ClaudeVoiceUITests/E2ETestBase.swift` - Fixed test fixture paths

---

## Task 14: Fix Resume Session Flow (BLOCKING)

**Status:** COMPLETED

**Problem:** Real device testing shows resume session flow gets stuck on "Thinking" state. Server logs show content was extracted and sent, but no TTS was generated.

**Root Cause:** WebSocket disconnects after `list_projects`, then reconnects. This happens because `connect()` is called twice:
- ClaudeVoiceApp.swift calls `connect()` on appear (auto-connect)
- E2E test's manual connect fallback in Settings could tap Connect while auto-connect was in progress
- SettingsView.connectToServer() had no guard, so it called `webSocketManager.connect()` directly
- WebSocketManager.connect() disconnects existing connection before reconnecting, causing "no close frame" error

**Fix Applied:**
Added guards in `SettingsView.connectToServer()` to prevent calling connect() when already connecting or connected:
```swift
private func connectToServer() {
    // Don't attempt to connect if already connecting or connected
    if case .connecting = webSocketManager.connectionState { return }
    if case .connected = webSocketManager.connectionState { return }
    // ... rest of method
}
```

Also added `waitForSessionSyncComplete()` helper in E2ETestBase to properly wait for session sync before checking voiceState.

**Files Changed:**
- `ios-voice-app/ClaudeVoice/ClaudeVoice/Views/SettingsView.swift` - Added connection state guards
- `ios-voice-app/ClaudeVoice/ClaudeVoiceUITests/E2ETestBase.swift` - Added waitForSessionSyncComplete()

---

## Task 15: Fix E2E Test Fixtures and Project Paths (NEXT SESSION)

**Status:** IN PROGRESS

**Problem:** E2E tests fail because they can't find "e2e-test-project1" project. The test fixtures and project paths need alignment.

**What Was Done This Session:**
1. Fixed double-connect issue in `SettingsView.connectToServer()` - added guards to prevent connecting while already connecting/connected
2. Updated test fixture paths from `-tmp-e2e_test_project1` to `-private-tmp-e2e-test-project1` (macOS /tmp is /private/tmp, dashes not underscores)
3. Added `preExistingTestSessionId` constant for resume testing with real session ID `1047e029-a4db-4c17-bb3e-4f5609a95f7b`
4. Updated E2EFullConversationFlowTests to test 3 scenarios:
   - Scenario 1: Create NEW session
   - Scenario 2: Resume PRE-EXISTING session (created before tests)
   - Scenario 3: Resume session created in same app instance
5. Fixed server test `test_resume_session_starts_with_resume_id` to expect `working_dir` parameter

**Test Results (9 passed, 3 failed):**
- ✅ E2EConnectionTests (all passed)
- ✅ E2EErrorHandlingTests (all passed)
- ✅ E2EPermissionTests (all passed)
- ❌ E2EFullConversationFlowTests - Can't find "e2e-test-project1"
- ❌ E2ENavigationFlowTests - Can't find "e2e-test-project1"
- ❌ E2ESessionFlowTests - Can't find "e2e-test-project1"

**Root Cause of Remaining Failures:**
The test fixture creation in `createTestFixtures()` creates directories at:
- `/Users/aaron/.claude/projects/-private-tmp-e2e-test-project1/`

But either:
1. The directories aren't being created before the server scans for projects
2. The session files inside (session1.jsonl, session2.jsonl) have fake IDs that Claude can't resume
3. The project path encoding doesn't match what the server expects

**Next Steps:**
1. Verify the test fixture directories are created BEFORE the server starts scanning
2. The pre-existing session (`1047e029-a4db-4c17-bb3e-4f5609a95f7b`) exists in `-private-tmp-e2e-test-project1` - use this real project
3. Either:
   - Option A: Don't create fake test fixtures - use the real pre-existing project/sessions
   - Option B: Fix `createTestFixtures()` to create properly formatted session files with real-looking UUIDs
4. For resume tests, the session IDs must be real UUIDs that exist in Claude's database, OR use new sessions created during the test

**Files to Check:**
- `E2ETestBase.swift` - `createTestFixtures()` method and path constants
- `run_e2e_tests.sh` - Server startup timing
- Server's `list_projects` handler - What it actually scans/returns

**Pre-existing Test Session:**
```
Path: ~/.claude/projects/-private-tmp-e2e-test-project1/
Session ID: 1518a515-792d-4621-b93b-bae8865f2ec7
First message: "Reply with only the word 'test'"
Project name in UI: "project1"
```

---

### Session 3 Notes (Task 15 continued)

**What was done:**
1. Removed ALL mock/fake fixtures from E2E tests
2. Removed `injectAssistantResponse`, `createTestFixtures`, `cleanupTestFixtures` methods
3. Created real Claude test session: `1518a515-792d-4621-b93b-bae8865f2ec7` in project "project1"
4. Updated all E2E tests to use real Claude responses with one-word prompts to save tokens
5. Updated tests to use `testProjectName = "project1"` and `testSessionId`

**Test Results: 10/15 passing**

Passing tests:
- E2EConnectionTests.test_connection_and_voice_controls
- E2ENavigationFlowTests.test_navigation_flow
- E2EPermissionTests (all 3 tests)
- E2ESessionFlowTests.test_session_sync_flow
- E2EFullConversationFlowTests.test_permission_flow
- Plus others

Failing tests (5):
- E2EConnectionTests.test_reconnection_flow() - times out waiting for Speaking state
- E2EErrorHandlingTests.test_error_handling() - times out waiting for Speaking state
- E2EFullConversationFlowTests.test_complete_conversation_flow() - times out waiting for Speaking state
- E2EFullConversationFlowTests.test_resume_session() - times out waiting for Speaking state
- E2ESessionFlowTests.test_session_switching() - times out waiting for Speaking state

**Root Cause of Failures:**
Tests wait 30s for `Speaking` state but real Claude response + TTS takes longer. Need to either:
1. Increase timeout for Speaking state
2. Check if TTS is actually triggering from real Claude responses
3. Verify file watcher sees Claude's transcript updates

**Next Session:**
1. Check server logs to see if Claude responds and TTS triggers
2. Potentially increase Speaking timeout from 30s to 60s
3. Or debug why TTS isn't triggering from real responses

---

### Session 4 Notes (Task 15 continued)

**What was done:**
1. Fixed folder name decoding bug - added `get_session_cwd()` to read actual cwd from session file
2. Added `os.makedirs(working_dir, exist_ok=True)` in `start_session()` to create dirs if missing
3. Updated E2E test runner (`run_e2e_tests.sh`) to dynamically create Claude session at test start
4. Session config written to `/tmp/e2e_test_config.json` for tests to read
5. Updated `E2ETestBase.swift` to read config from JSON file
6. Documented E2E test flow in `tests/TESTS.md`

**Key discoveries:**
- Claude Code encodes both `/` AND `_` as `-` in folder names
  - Path `/private/tmp/e2e_test_project` → folder `-private-tmp-e2e-test-project`
  - This makes decoding ambiguous; must read cwd from session file
- `/tmp` resolves to `/private/tmp` on macOS
- xcodebuild doesn't pass build settings as environment variables to test process
  - Solution: write JSON config file that tests can read

**Current failures:**
E2EConnectionTests fails because:
1. Server initially watches wrong file (agent file instead of main session)
2. Tests try to create new session with wrong path (`/e2e_test_project` instead of `/tmp/e2e_test_project`)

**Files changed this session:**
- `voice_server/session_manager.py` - Added `get_session_cwd()`
- `voice_server/tmux_controller.py` - Added `os.makedirs()` for working_dir
- `voice_server/ios_server.py` - Use `get_session_cwd()` instead of `decode_folder_name()`
- `ios-voice-app/ClaudeVoice/run_e2e_tests.sh` - Create session dynamically, write config
- `ios-voice-app/ClaudeVoice/ClaudeVoiceUITests/E2ETestBase.swift` - Read config from JSON
- `tests/TESTS.md` - Document E2E test flow

**Next steps:**
1. Fix test config loading - tests not reading `/tmp/e2e_test_config.json`
2. Verify E2EConnectionTests can find the dynamically created project

---

### Session 5 Notes (Task 15 continued)

**What was done:**
1. Added `encode_path_to_folder()` and `find_newest_session()` to `session_manager.py`
2. Updated `handle_new_session` in `ios_server.py` to switch file watcher to new session's transcript
3. Changed E2EConnectionTests line 73 to use `resume: true`

**Root cause identified:**
- `handle_new_session` was NOT switching the file watcher to the new session's transcript
- `handle_resume_session` DID switch the watcher (line 498) - that's why resume worked
- When creating a NEW session, server kept watching the OLD transcript file

**Remaining issue - `verifyInputInTmux` fails:**
- Voice input is sent successfully (`send_input` returns True)
- But `/capture_pane` doesn't find the text in tmux pane
- Suspicious: "Claude ready after 0.0s" - Claude takes time to start, shouldn't be instant
- Likely cause: tmux pane has stale content, or Claude isn't actually running yet

**Files changed this session:**
- `voice_server/session_manager.py` - Added `encode_path_to_folder()`, `find_newest_session()`
- `voice_server/ios_server.py` - Updated `handle_new_session` to switch watcher
- `ios-voice-app/ClaudeVoice/ClaudeVoiceUITests/E2EConnectionTests.swift` - Line 73 use `resume: true`

**Next session must:**
1. Debug why `verifyInputInTmux` fails - is Claude actually running in tmux?
2. Check if `waitForClaudeReady` is actually waiting for Claude to start
3. Consider adding a real wait after `start_session` before sending input

---

### Session 6 Notes (Task 15 continued)

**Root cause found and fixed:**
The UI state issue was that when outputState is `.speaking`, the UI shows `outputStatus` with "Speaking..." instead of `voiceState` with "Speaking". Tests were checking the wrong element.

**Solution:**
Added `waitForResponseCycle()` helper that tests the OUTCOME (full cycle completes) rather than intermediate states. This is more robust than checking for "Speaking" state because:
1. It checks for ANY non-idle state to start (outputStatus exists, or voiceState != Idle)
2. Then waits for voiceState to return to "Idle" (cycle complete)
3. Doesn't care about intermediate state names

**Test results:**
- E2EConnectionTests: PASS (when run individually)
- E2EFullConversationFlowTests: Updated to use waitForResponseCycle
- E2EErrorHandlingTests: Updated to use waitForResponseCycle

**Remaining issues (unrelated to waitForResponseCycle fix):**
- E2ESessionFlowTests looking for "Synced" image that may not exist
- E2EPermissionTests have different issues
- Some test pollution when running all tests together

**Files changed this session:**
- `ios-voice-app/ClaudeVoice/ClaudeVoiceUITests/E2ETestBase.swift` - Added `waitForResponseCycle()` helper
- `ios-voice-app/ClaudeVoice/ClaudeVoiceUITests/E2EConnectionTests.swift` - Use waitForResponseCycle
- `ios-voice-app/ClaudeVoice/ClaudeVoiceUITests/E2EFullConversationFlowTests.swift` - Use waitForResponseCycle
- `ios-voice-app/ClaudeVoice/ClaudeVoiceUITests/E2EErrorHandlingTests.swift` - Use waitForResponseCycle

---

## Summary

| Task | Description | Files Changed |
|------|-------------|---------------|
| 1 | Create TmuxController | +2 files |
| 2 | Update iOS Model | 1 file |
| 3 | Update iOS WebSocketManager | 1 file |
| 4 | Update iOS SessionView | 1 file |
| 5 | Update iOS SessionsListView | 1 file |
| 6 | Update Server | 1 file |
| 7 | Update Server Tests | 4 files, -1 file |
| 8 | Update iOS Tests | 2 files |
| 9 | Update E2E Tests | 1 file (renamed) |
| 10 | Clean Up | 3 files, -1 file |
| 11 | Fix Remaining VSCode References | 3 files |
| 12 | Fix E2E Tests to Test Real Behavior | 3 files |
| 13 | **Fix E2E Test Timing Issue** | 1 file |
| 14 | **Fix Resume Session Flow** | 2 files |
| 15 | **Fix E2E Test Fixtures** | IN PROGRESS |

**Total:** ~20 files modified, 2 created, 3 deleted
