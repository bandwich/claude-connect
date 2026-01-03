# VSCode Connections Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use execute-plan to implement this plan task-by-task.

**Goal:** Replace AppleScript with VSCodeController WebSocket and add full session management (resume, new, close, add project).

**Architecture:** Python server connects to vscode-remote-control extension via WebSocket (ws://localhost:3710). All terminal commands go through this connection instead of clipboard+AppleScript. iOS app gets new buttons for Resume, New Session, and Close Session.

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

## Task 1: Add VSCode Connection Management to Server

Add connection lifecycle management for the VSCode WebSocket.

**Files:**
- Modify: `voice_server/vscode_controller.py`
- Modify: `voice_server/tests/test_vscode_controller.py`

### Step 1: Add test for connection state tracking

```python
# Add to voice_server/tests/test_vscode_controller.py
import pytest

class TestVSCodeControllerConnection:
    """Tests for VSCodeController connection management"""

    def test_is_connected_returns_false_initially(self):
        """Should return False before connect() is called"""
        from vscode_controller import VSCodeController

        controller = VSCodeController()
        assert controller.is_connected() is False

    def test_is_connected_returns_true_after_connect(self):
        """Should return True after successful connect()"""
        from vscode_controller import VSCodeController

        controller = VSCodeController()
        # Mock successful connection
        controller._connected = True
        assert controller.is_connected() is True
```

### Step 2: Run test to verify it fails

Run: `cd /Users/aaron/Desktop/max/voice_server && python -m pytest tests/test_vscode_controller.py::TestVSCodeControllerConnection::test_is_connected_returns_false_initially -v`
Expected: FAIL with "AttributeError: 'VSCodeController' object has no attribute 'is_connected'"

### Step 3: Add is_connected method

```python
# Add to voice_server/vscode_controller.py VSCodeController class

    def is_connected(self) -> bool:
        """Check if connected to VS Code extension"""
        return self._connected
```

### Step 4: Run test to verify it passes

Run: `cd /Users/aaron/Desktop/max/voice_server && python -m pytest tests/test_vscode_controller.py::TestVSCodeControllerConnection -v`
Expected: PASS

### Step 5: Commit

```bash
git add voice_server/vscode_controller.py voice_server/tests/test_vscode_controller.py
git commit -m "feat: add is_connected method to VSCodeController"
```

---

## Task 2: Add Graceful Fallback in VSCodeController

When VSCode isn't connected, methods should fail gracefully instead of crashing.

**Files:**
- Modify: `voice_server/vscode_controller.py`
- Modify: `voice_server/tests/test_vscode_controller.py`

### Step 1: Add test for graceful failure

```python
# Add to voice_server/tests/test_vscode_controller.py
import pytest

class TestVSCodeControllerGracefulFallback:
    """Tests for graceful fallback when not connected"""

    @pytest.mark.asyncio
    async def test_send_sequence_returns_false_when_disconnected(self):
        """Should return False instead of raising when not connected"""
        from vscode_controller import VSCodeController

        controller = VSCodeController()
        # Don't connect - controller._connected is False

        result = await controller.send_sequence("test")
        assert result is False

    @pytest.mark.asyncio
    async def test_send_sequence_returns_true_when_connected(self):
        """Should return True when message is sent"""
        from vscode_controller import VSCodeController

        controller = VSCodeController()

        # Mock the WebSocket
        sent_messages = []
        class MockWS:
            async def send(self, msg):
                sent_messages.append(msg)

        controller._ws = MockWS()
        controller._connected = True

        result = await controller.send_sequence("hello")
        assert result is True
        assert len(sent_messages) == 1
```

### Step 2: Run test to verify it fails

Run: `cd /Users/aaron/Desktop/max/voice_server && python -m pytest tests/test_vscode_controller.py::TestVSCodeControllerGracefulFallback -v`
Expected: FAIL (raises ConnectionError instead of returning False)

### Step 3: Update send_sequence to return bool

```python
# Replace send_sequence in voice_server/vscode_controller.py

    async def send_sequence(self, text: str) -> bool:
        """Send text to the active terminal

        Returns:
            True if sent successfully, False if not connected
        """
        if not self._connected or not self._ws:
            return False

        try:
            await self._send_command(
                "workbench.action.terminal.sendSequence",
                {"text": text}
            )
            return True
        except Exception as e:
            print(f"Failed to send sequence: {e}")
            return False
```

### Step 4: Run test to verify it passes

Run: `cd /Users/aaron/Desktop/max/voice_server && python -m pytest tests/test_vscode_controller.py::TestVSCodeControllerGracefulFallback -v`
Expected: PASS

### Step 5: Commit

```bash
git add voice_server/vscode_controller.py voice_server/tests/test_vscode_controller.py
git commit -m "feat: add graceful fallback for disconnected VSCodeController"
```

---

## Task 3: Replace AppleScript with VSCodeController in Server

Replace the `send_to_vs_code` AppleScript method with VSCodeController.

**Files:**
- Modify: `voice_server/ios_server.py`
- Modify: `voice_server/tests/test_message_handlers.py`

### Step 1: Add test for VSCode integration

```python
# Add to voice_server/tests/test_message_handlers.py
import pytest
from unittest.mock import AsyncMock, patch

class TestVoiceInputWithVSCode:
    """Tests for voice input via VSCode controller"""

    @pytest.mark.asyncio
    async def test_voice_input_uses_vscode_controller(self):
        """Voice input should send text via VSCodeController"""
        import sys
        sys.path.insert(0, '/Users/aaron/Desktop/max/voice_server')

        from ios_server import VoiceServer

        server = VoiceServer()

        # Mock VSCodeController
        server.vscode_controller = AsyncMock()
        server.vscode_controller.is_connected.return_value = True
        server.vscode_controller.send_sequence = AsyncMock(return_value=True)

        # Mock WebSocket
        mock_ws = AsyncMock()

        # Handle voice input
        await server.handle_voice_input(mock_ws, {"text": "hello claude"})

        # Verify send_sequence was called with text + Enter
        server.vscode_controller.send_sequence.assert_called_once_with("hello claude\n")

    @pytest.mark.asyncio
    async def test_voice_input_falls_back_to_applescript(self):
        """Should fall back to AppleScript if VSCode not connected"""
        import sys
        sys.path.insert(0, '/Users/aaron/Desktop/max/voice_server')

        from ios_server import VoiceServer

        server = VoiceServer()

        # Mock VSCodeController as disconnected
        server.vscode_controller = AsyncMock()
        server.vscode_controller.is_connected.return_value = False

        # Mock AppleScript fallback
        with patch.object(server, 'send_to_vs_code_applescript') as mock_applescript:
            mock_ws = AsyncMock()
            await server.handle_voice_input(mock_ws, {"text": "hello"})
            mock_applescript.assert_called_once_with("hello")
```

### Step 2: Run test to verify it fails

Run: `cd /Users/aaron/Desktop/max/voice_server && python -m pytest tests/test_message_handlers.py::TestVoiceInputWithVSCode -v`
Expected: FAIL (vscode_controller attribute doesn't exist on server)

### Step 3: Update ios_server.py

```python
# At the top of voice_server/ios_server.py, add import:
from vscode_controller import VSCodeController

# In VoiceServer.__init__, add:
        self.vscode_controller = VSCodeController()

# Rename the existing send_to_vs_code to send_to_vs_code_applescript:
    async def send_to_vs_code_applescript(self, text):
        """Send text to VS Code via AppleScript (fallback)"""
        subprocess.run(['pbcopy'], input=text.encode('utf-8'))
        applescript = '''
tell application "Visual Studio Code"
    activate
end tell
delay 0.3
tell application "System Events"
    keystroke "v" using {command down}
    delay 0.2
    keystroke return
end tell
'''
        subprocess.run(['osascript', '-e', applescript])

# Create new send_to_vs_code that tries VSCode first:
    async def send_to_vs_code(self, text):
        """Send text to VS Code terminal

        Tries VSCodeController first, falls back to AppleScript if not connected.
        """
        if self.vscode_controller.is_connected():
            success = await self.vscode_controller.send_sequence(text + "\n")
            if success:
                return
            print("VSCode send failed, falling back to AppleScript")

        # Fallback to AppleScript
        await self.send_to_vs_code_applescript(text)

# In VoiceServer.start(), add VSCode connection after loop assignment:
        self.loop = asyncio.get_running_loop()

        # Try to connect to VSCode extension
        connected = await self.vscode_controller.connect()
        if connected:
            print("✅ Connected to VSCode extension")
        else:
            print("⚠️ VSCode extension not available, using AppleScript fallback")
```

### Step 4: Run test to verify it passes

Run: `cd /Users/aaron/Desktop/max/voice_server && python -m pytest tests/test_message_handlers.py::TestVoiceInputWithVSCode -v`
Expected: PASS

### Step 5: Commit

```bash
git add voice_server/ios_server.py voice_server/tests/test_message_handlers.py
git commit -m "feat: replace AppleScript with VSCodeController for voice input"
```

---

## Task 4: Add close_session Handler

Send Ctrl+C to terminate the current Claude session.

**Files:**
- Modify: `voice_server/ios_server.py`
- Modify: `voice_server/tests/test_message_handlers.py`

### Step 1: Add test for close_session

```python
# Add to voice_server/tests/test_message_handlers.py

class TestCloseSession:
    """Tests for close_session handler"""

    @pytest.mark.asyncio
    async def test_close_session_sends_ctrl_c(self):
        """close_session should send Ctrl+C via VSCodeController"""
        import sys
        sys.path.insert(0, '/Users/aaron/Desktop/max/voice_server')

        from ios_server import VoiceServer

        server = VoiceServer()

        # Mock VSCodeController
        server.vscode_controller = AsyncMock()
        server.vscode_controller.is_connected.return_value = True
        server.vscode_controller.send_sequence = AsyncMock(return_value=True)

        mock_ws = AsyncMock()

        await server.handle_close_session(mock_ws)

        # Ctrl+C is ASCII 0x03
        server.vscode_controller.send_sequence.assert_called_once_with("\x03")

    @pytest.mark.asyncio
    async def test_close_session_returns_success_status(self):
        """close_session should send success status to client"""
        import sys
        sys.path.insert(0, '/Users/aaron/Desktop/max/voice_server')

        from ios_server import VoiceServer
        import json

        server = VoiceServer()
        server.vscode_controller = AsyncMock()
        server.vscode_controller.is_connected.return_value = True
        server.vscode_controller.send_sequence = AsyncMock(return_value=True)

        mock_ws = AsyncMock()
        sent_messages = []
        mock_ws.send = AsyncMock(side_effect=lambda msg: sent_messages.append(msg))

        await server.handle_close_session(mock_ws)

        # Find the session_closed response
        responses = [json.loads(m) for m in sent_messages]
        closed_response = next((r for r in responses if r.get("type") == "session_closed"), None)
        assert closed_response is not None
        assert closed_response["success"] is True
```

### Step 2: Run test to verify it fails

Run: `cd /Users/aaron/Desktop/max/voice_server && python -m pytest tests/test_message_handlers.py::TestCloseSession -v`
Expected: FAIL (handle_close_session doesn't exist)

### Step 3: Add close_session handler

```python
# Add to VoiceServer class in voice_server/ios_server.py

    async def handle_close_session(self, websocket):
        """Handle close_session request - sends Ctrl+C to terminal"""
        success = False

        if self.vscode_controller.is_connected():
            # Ctrl+C is ASCII 0x03
            success = await self.vscode_controller.send_sequence("\x03")

        response = {
            "type": "session_closed",
            "success": success
        }
        await websocket.send(json.dumps(response))

# Add to handle_message dispatch:
            elif msg_type == 'close_session':
                await self.handle_close_session(websocket)
```

### Step 4: Run test to verify it passes

Run: `cd /Users/aaron/Desktop/max/voice_server && python -m pytest tests/test_message_handlers.py::TestCloseSession -v`
Expected: PASS

### Step 5: Commit

```bash
git add voice_server/ios_server.py voice_server/tests/test_message_handlers.py
git commit -m "feat: add close_session handler to send Ctrl+C"
```

---

## Task 5: Add new_session Handler

Open new terminal and start `claude` command.

**Files:**
- Modify: `voice_server/ios_server.py`
- Modify: `voice_server/tests/test_message_handlers.py`

### Step 1: Add test for new_session

```python
# Add to voice_server/tests/test_message_handlers.py

class TestNewSession:
    """Tests for new_session handler"""

    @pytest.mark.asyncio
    async def test_new_session_opens_terminal_and_runs_claude(self):
        """new_session should open terminal and run claude"""
        import sys
        sys.path.insert(0, '/Users/aaron/Desktop/max/voice_server')

        from ios_server import VoiceServer

        server = VoiceServer()

        # Mock VSCodeController
        server.vscode_controller = AsyncMock()
        server.vscode_controller.is_connected.return_value = True
        server.vscode_controller.new_terminal = AsyncMock()
        server.vscode_controller.send_sequence = AsyncMock(return_value=True)

        mock_ws = AsyncMock()

        await server.handle_new_session(mock_ws, {"project_path": "/Users/test/myproject"})

        # Should open new terminal
        server.vscode_controller.new_terminal.assert_called_once()

        # Should run claude command
        server.vscode_controller.send_sequence.assert_called_with("claude\n")

    @pytest.mark.asyncio
    async def test_new_session_returns_success_status(self):
        """new_session should send success status"""
        import sys
        sys.path.insert(0, '/Users/aaron/Desktop/max/voice_server')

        from ios_server import VoiceServer
        import json

        server = VoiceServer()
        server.vscode_controller = AsyncMock()
        server.vscode_controller.is_connected.return_value = True
        server.vscode_controller.new_terminal = AsyncMock()
        server.vscode_controller.send_sequence = AsyncMock(return_value=True)

        mock_ws = AsyncMock()
        sent_messages = []
        mock_ws.send = AsyncMock(side_effect=lambda msg: sent_messages.append(msg))

        await server.handle_new_session(mock_ws, {"project_path": "/test"})

        responses = [json.loads(m) for m in sent_messages]
        new_response = next((r for r in responses if r.get("type") == "session_created"), None)
        assert new_response is not None
        assert new_response["success"] is True
```

### Step 2: Run test to verify it fails

Run: `cd /Users/aaron/Desktop/max/voice_server && python -m pytest tests/test_message_handlers.py::TestNewSession -v`
Expected: FAIL (handle_new_session doesn't exist)

### Step 3: Add new_session handler

```python
# Add to VoiceServer class in voice_server/ios_server.py

    async def handle_new_session(self, websocket, data):
        """Handle new_session request - opens terminal and starts claude"""
        project_path = data.get("project_path", "")
        success = False

        if self.vscode_controller.is_connected():
            try:
                # Open new terminal
                await self.vscode_controller.new_terminal()

                # Give VS Code time to create the terminal
                await asyncio.sleep(0.5)

                # Run claude command
                success = await self.vscode_controller.send_sequence("claude\n")
            except Exception as e:
                print(f"Error creating new session: {e}")

        response = {
            "type": "session_created",
            "success": success
        }
        await websocket.send(json.dumps(response))

# Add to handle_message dispatch:
            elif msg_type == 'new_session':
                await self.handle_new_session(websocket, data)
```

### Step 4: Run test to verify it passes

Run: `cd /Users/aaron/Desktop/max/voice_server && python -m pytest tests/test_message_handlers.py::TestNewSession -v`
Expected: PASS

### Step 5: Commit

```bash
git add voice_server/ios_server.py voice_server/tests/test_message_handlers.py
git commit -m "feat: add new_session handler to start claude in new terminal"
```

---

## Task 6: Add resume_session Handler

Resume an existing session with `claude --resume <session_id>`.

**Files:**
- Modify: `voice_server/ios_server.py`
- Modify: `voice_server/tests/test_message_handlers.py`

### Step 1: Add test for resume_session

```python
# Add to voice_server/tests/test_message_handlers.py

class TestResumeSession:
    """Tests for resume_session handler"""

    @pytest.mark.asyncio
    async def test_resume_session_runs_claude_with_resume_flag(self):
        """resume_session should run 'claude --resume <id>'"""
        import sys
        sys.path.insert(0, '/Users/aaron/Desktop/max/voice_server')

        from ios_server import VoiceServer

        server = VoiceServer()

        server.vscode_controller = AsyncMock()
        server.vscode_controller.is_connected.return_value = True
        server.vscode_controller.new_terminal = AsyncMock()
        server.vscode_controller.send_sequence = AsyncMock(return_value=True)

        mock_ws = AsyncMock()

        await server.handle_resume_session(mock_ws, {
            "session_id": "abc123-def456"
        })

        # Should open new terminal
        server.vscode_controller.new_terminal.assert_called_once()

        # Should run claude --resume with session ID
        server.vscode_controller.send_sequence.assert_called_with(
            "claude --resume abc123-def456\n"
        )

    @pytest.mark.asyncio
    async def test_resume_session_returns_success(self):
        """resume_session should return success status"""
        import sys
        sys.path.insert(0, '/Users/aaron/Desktop/max/voice_server')

        from ios_server import VoiceServer
        import json

        server = VoiceServer()
        server.vscode_controller = AsyncMock()
        server.vscode_controller.is_connected.return_value = True
        server.vscode_controller.new_terminal = AsyncMock()
        server.vscode_controller.send_sequence = AsyncMock(return_value=True)

        mock_ws = AsyncMock()
        sent_messages = []
        mock_ws.send = AsyncMock(side_effect=lambda msg: sent_messages.append(msg))

        await server.handle_resume_session(mock_ws, {"session_id": "test123"})

        responses = [json.loads(m) for m in sent_messages]
        resume_response = next((r for r in responses if r.get("type") == "session_resumed"), None)
        assert resume_response is not None
        assert resume_response["success"] is True
        assert resume_response["session_id"] == "test123"
```

### Step 2: Run test to verify it fails

Run: `cd /Users/aaron/Desktop/max/voice_server && python -m pytest tests/test_message_handlers.py::TestResumeSession -v`
Expected: FAIL (handle_resume_session doesn't exist)

### Step 3: Add resume_session handler

```python
# Add to VoiceServer class in voice_server/ios_server.py

    async def handle_resume_session(self, websocket, data):
        """Handle resume_session request - runs 'claude --resume <id>'"""
        session_id = data.get("session_id", "")
        success = False

        if self.vscode_controller.is_connected() and session_id:
            try:
                # Open new terminal
                await self.vscode_controller.new_terminal()

                # Give VS Code time to create the terminal
                await asyncio.sleep(0.5)

                # Run claude --resume with session ID
                success = await self.vscode_controller.send_sequence(
                    f"claude --resume {session_id}\n"
                )
            except Exception as e:
                print(f"Error resuming session: {e}")

        response = {
            "type": "session_resumed",
            "success": success,
            "session_id": session_id
        }
        await websocket.send(json.dumps(response))

# Add to handle_message dispatch:
            elif msg_type == 'resume_session':
                await self.handle_resume_session(websocket, data)
```

### Step 4: Run test to verify it passes

Run: `cd /Users/aaron/Desktop/max/voice_server && python -m pytest tests/test_message_handlers.py::TestResumeSession -v`
Expected: PASS

### Step 5: Commit

```bash
git add voice_server/ios_server.py voice_server/tests/test_message_handlers.py
git commit -m "feat: add resume_session handler for --resume flag"
```

---

## Task 7: Add add_project Handler

Create a new project directory and open it in VS Code.

**Files:**
- Modify: `voice_server/ios_server.py`
- Modify: `voice_server/tests/test_message_handlers.py`

### Step 1: Add test for add_project

```python
# Add to voice_server/tests/test_message_handlers.py
import tempfile
import shutil

class TestAddProject:
    """Tests for add_project handler"""

    @pytest.mark.asyncio
    async def test_add_project_creates_directory(self):
        """add_project should create project directory"""
        import sys
        sys.path.insert(0, '/Users/aaron/Desktop/max/voice_server')

        from ios_server import VoiceServer
        import os

        server = VoiceServer()

        # Use temp directory for test
        with tempfile.TemporaryDirectory() as tmpdir:
            server.projects_base_path = tmpdir

            server.vscode_controller = AsyncMock()
            server.vscode_controller.is_connected.return_value = True
            server.vscode_controller.open_folder = AsyncMock()
            server.vscode_controller.new_terminal = AsyncMock()
            server.vscode_controller.send_sequence = AsyncMock(return_value=True)

            mock_ws = AsyncMock()

            await server.handle_add_project(mock_ws, {"name": "test-project"})

            # Verify directory was created
            project_path = os.path.join(tmpdir, "test-project")
            assert os.path.exists(project_path)
            assert os.path.isdir(project_path)

    @pytest.mark.asyncio
    async def test_add_project_opens_in_vscode(self):
        """add_project should open folder in VS Code"""
        import sys
        sys.path.insert(0, '/Users/aaron/Desktop/max/voice_server')

        from ios_server import VoiceServer

        server = VoiceServer()

        with tempfile.TemporaryDirectory() as tmpdir:
            server.projects_base_path = tmpdir

            server.vscode_controller = AsyncMock()
            server.vscode_controller.is_connected.return_value = True
            server.vscode_controller.open_folder = AsyncMock()
            server.vscode_controller.new_terminal = AsyncMock()
            server.vscode_controller.send_sequence = AsyncMock(return_value=True)

            mock_ws = AsyncMock()

            await server.handle_add_project(mock_ws, {"name": "my-project"})

            # Verify open_folder was called
            expected_path = f"{tmpdir}/my-project"
            server.vscode_controller.open_folder.assert_called_once_with(expected_path)

    @pytest.mark.asyncio
    async def test_add_project_starts_claude(self):
        """add_project should start claude in new terminal"""
        import sys
        sys.path.insert(0, '/Users/aaron/Desktop/max/voice_server')

        from ios_server import VoiceServer

        server = VoiceServer()

        with tempfile.TemporaryDirectory() as tmpdir:
            server.projects_base_path = tmpdir

            server.vscode_controller = AsyncMock()
            server.vscode_controller.is_connected.return_value = True
            server.vscode_controller.open_folder = AsyncMock()
            server.vscode_controller.new_terminal = AsyncMock()
            server.vscode_controller.send_sequence = AsyncMock(return_value=True)

            mock_ws = AsyncMock()

            await server.handle_add_project(mock_ws, {"name": "new-proj"})

            # Verify claude was started
            server.vscode_controller.new_terminal.assert_called_once()
            server.vscode_controller.send_sequence.assert_called_with("claude\n")
```

### Step 2: Run test to verify it fails

Run: `cd /Users/aaron/Desktop/max/voice_server && python -m pytest tests/test_message_handlers.py::TestAddProject -v`
Expected: FAIL (handle_add_project doesn't exist)

### Step 3: Add add_project handler and config

```python
# Add near top of voice_server/ios_server.py (after TRANSCRIPT_DIR):
PROJECTS_BASE_PATH = os.path.expanduser("~/Desktop/code")

# Add to VoiceServer.__init__:
        self.projects_base_path = PROJECTS_BASE_PATH

# Add to VoiceServer class:
    async def handle_add_project(self, websocket, data):
        """Handle add_project request - creates directory and opens in VS Code"""
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

        # Sanitize name (remove unsafe characters)
        safe_name = "".join(c for c in name if c.isalnum() or c in "-_.")
        project_path = os.path.join(self.projects_base_path, safe_name)

        try:
            # Create directory
            os.makedirs(project_path, exist_ok=True)

            if self.vscode_controller.is_connected():
                # Open in VS Code
                await self.vscode_controller.open_folder(project_path)

                # Wait for VS Code to open the folder
                await asyncio.sleep(1.0)

                # Open terminal and start claude
                await self.vscode_controller.new_terminal()
                await asyncio.sleep(0.5)
                success = await self.vscode_controller.send_sequence("claude\n")
            else:
                success = True  # Directory created, but VSCode not available

        except Exception as e:
            print(f"Error creating project: {e}")

        response = {
            "type": "project_created",
            "success": success,
            "path": project_path,
            "name": safe_name
        }
        await websocket.send(json.dumps(response))

# Add to handle_message dispatch:
            elif msg_type == 'add_project':
                await self.handle_add_project(websocket, data)
```

### Step 4: Run test to verify it passes

Run: `cd /Users/aaron/Desktop/max/voice_server && python -m pytest tests/test_message_handlers.py::TestAddProject -v`
Expected: PASS

### Step 5: Commit

```bash
git add voice_server/ios_server.py voice_server/tests/test_message_handlers.py
git commit -m "feat: add add_project handler to create and open projects"
```

---

## Task 8: Add iOS WebSocket Methods for Session Actions

Add methods to WebSocketManager for the new session commands.

**Files:**
- Modify: `ios-voice-app/ClaudeVoice/ClaudeVoice/Services/WebSocketManager.swift`

### Step 1: Add new response types to Models

```swift
// Add to ios-voice-app/ClaudeVoice/ClaudeVoice/Models/Session.swift

struct SessionActionResponse: Codable {
    let type: String
    let success: Bool
    let sessionId: String?
    let path: String?
    let name: String?
    let error: String?

    enum CodingKeys: String, CodingKey {
        case type, success, path, name, error
        case sessionId = "session_id"
    }
}
```

### Step 2: Add WebSocket methods

```swift
// Add to ios-voice-app/ClaudeVoice/ClaudeVoice/Services/WebSocketManager.swift

// Add callback for session actions
var onSessionActionResult: ((SessionActionResponse) -> Void)?

// Add request methods
func closeSession() {
    let message = ["type": "close_session"]
    sendJSON(message)
}

func newSession(projectPath: String) {
    let message: [String: Any] = [
        "type": "new_session",
        "project_path": projectPath
    ]
    sendJSON(message)
}

func resumeSession(sessionId: String) {
    let message: [String: Any] = [
        "type": "resume_session",
        "session_id": sessionId
    ]
    sendJSON(message)
}

func addProject(name: String) {
    let message: [String: Any] = [
        "type": "add_project",
        "name": name
    ]
    sendJSON(message)
}

// In handleMessage, add decoding for session action responses:
// (After the existing if/else chain for message types)
} else if let actionResponse = try? JSONDecoder().decode(SessionActionResponse.self, from: data) {
    logToFile("✅ Decoded as SessionActionResponse: \(actionResponse.type)")
    DispatchQueue.main.async {
        self.onSessionActionResult?(actionResponse)
    }
}
```

### Step 3: Build to verify

Run: `cd /Users/aaron/Desktop/max/ios-voice-app/ClaudeVoice && xcodebuild -scheme ClaudeVoice -destination 'platform=iOS Simulator,name=iPhone 16' build 2>&1 | tail -10`
Expected: BUILD SUCCEEDED

### Step 4: Commit

```bash
git add ios-voice-app/ClaudeVoice/ClaudeVoice/Services/WebSocketManager.swift ios-voice-app/ClaudeVoice/ClaudeVoice/Models/Session.swift
git commit -m "feat: add iOS WebSocket methods for session actions"
```

---

## Task 9: Add Resume Button to SessionView

Add a "Resume" button in the session view to resume the selected session.

**Files:**
- Modify: `ios-voice-app/ClaudeVoice/ClaudeVoice/Views/SessionView.swift`

### Step 1: Add Resume button to toolbar

```swift
// Replace the toolbar in SessionView with:
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                HStack(spacing: 16) {
                    Button(action: resumeSession) {
                        Image(systemName: "play.fill")
                    }
                    .accessibilityLabel("Resume Session")

                    Button(action: { showingSettings = true }) {
                        Image(systemName: "gearshape.fill")
                    }
                }
            }
        }

// Add state for resume action:
    @State private var isResuming = false

// Add resumeSession function:
    private func resumeSession() {
        guard !isResuming else { return }
        isResuming = true

        webSocketManager.onSessionActionResult = { response in
            isResuming = false
            if response.success {
                // Session resumed - voice input is now active for this session
                print("Session resumed successfully")
            } else {
                print("Failed to resume session: \(response.error ?? "Unknown error")")
            }
        }

        webSocketManager.resumeSession(sessionId: session.id)
    }
```

### Step 2: Build to verify

Run: `cd /Users/aaron/Desktop/max/ios-voice-app/ClaudeVoice && xcodebuild -scheme ClaudeVoice -destination 'platform=iOS Simulator,name=iPhone 16' build 2>&1 | tail -10`
Expected: BUILD SUCCEEDED

### Step 3: Commit

```bash
git add ios-voice-app/ClaudeVoice/ClaudeVoice/Views/SessionView.swift
git commit -m "feat: add Resume button to SessionView"
```

---

## Task 10: Add New Session Button to SessionsListView

Add a "New Session" button in the sessions list.

**Files:**
- Modify: `ios-voice-app/ClaudeVoice/ClaudeVoice/Views/SessionsListView.swift`

### Step 1: Read current SessionsListView

Run: Read the file first to see current structure.

### Step 2: Add New Session button

```swift
// Add to SessionsListView toolbar:
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button(action: createNewSession) {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("New Session")
            }
        }

// Add state:
    @State private var isCreating = false

// Add function:
    private func createNewSession() {
        guard !isCreating else { return }
        isCreating = true

        webSocketManager.onSessionActionResult = { response in
            isCreating = false
            if response.success {
                // Refresh sessions list
                webSocketManager.requestSessions(folderName: project.folderName)
            }
        }

        webSocketManager.newSession(projectPath: project.path)
    }
```

### Step 3: Build to verify

Run: `cd /Users/aaron/Desktop/max/ios-voice-app/ClaudeVoice && xcodebuild -scheme ClaudeVoice -destination 'platform=iOS Simulator,name=iPhone 16' build 2>&1 | tail -10`
Expected: BUILD SUCCEEDED

### Step 4: Commit

```bash
git add ios-voice-app/ClaudeVoice/ClaudeVoice/Views/SessionsListView.swift
git commit -m "feat: add New Session button to SessionsListView"
```

---

## Task 11: Add Close Session Button to SessionView

Add ability to close the current session from the session view.

**Files:**
- Modify: `ios-voice-app/ClaudeVoice/ClaudeVoice/Views/SessionView.swift`

### Step 1: Add Close button to toolbar

```swift
// Update the toolbar HStack to include close button:
                HStack(spacing: 16) {
                    Button(action: closeSession) {
                        Image(systemName: "stop.fill")
                    }
                    .accessibilityLabel("Close Session")

                    Button(action: resumeSession) {
                        Image(systemName: "play.fill")
                    }
                    .accessibilityLabel("Resume Session")

                    Button(action: { showingSettings = true }) {
                        Image(systemName: "gearshape.fill")
                    }
                }

// Add state:
    @State private var isClosing = false

// Add closeSession function:
    private func closeSession() {
        guard !isClosing else { return }
        isClosing = true

        webSocketManager.onSessionActionResult = { response in
            isClosing = false
            if response.success {
                print("Session closed successfully")
            }
        }

        webSocketManager.closeSession()
    }
```

### Step 2: Build to verify

Run: `cd /Users/aaron/Desktop/max/ios-voice-app/ClaudeVoice && xcodebuild -scheme ClaudeVoice -destination 'platform=iOS Simulator,name=iPhone 16' build 2>&1 | tail -10`
Expected: BUILD SUCCEEDED

### Step 3: Commit

```bash
git add ios-voice-app/ClaudeVoice/ClaudeVoice/Views/SessionView.swift
git commit -m "feat: add Close Session button to SessionView"
```

---

## Task 12: Add Add Project Button to ProjectsListView

Add ability to create new projects from the projects list.

**Files:**
- Modify: `ios-voice-app/ClaudeVoice/ClaudeVoice/Views/ProjectsListView.swift`

### Step 1: Read current ProjectsListView

Run: Read the file first.

### Step 2: Add Add Project button with alert

```swift
// Add state variables:
    @State private var showingAddProject = false
    @State private var newProjectName = ""
    @State private var isCreating = false

// Add toolbar:
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button(action: { showingAddProject = true }) {
                    Image(systemName: "folder.badge.plus")
                }
                .accessibilityLabel("Add Project")
            }
        }

// Add alert for project name input:
        .alert("New Project", isPresented: $showingAddProject) {
            TextField("Project name", text: $newProjectName)
            Button("Cancel", role: .cancel) {
                newProjectName = ""
            }
            Button("Create") {
                createProject()
            }
        } message: {
            Text("Enter a name for the new project")
        }

// Add createProject function:
    private func createProject() {
        let name = newProjectName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !isCreating else {
            newProjectName = ""
            return
        }

        isCreating = true

        webSocketManager.onSessionActionResult = { response in
            isCreating = false
            newProjectName = ""

            if response.success {
                // Refresh projects list
                webSocketManager.requestProjects()
            }
        }

        webSocketManager.addProject(name: name)
    }
```

### Step 3: Build to verify

Run: `cd /Users/aaron/Desktop/max/ios-voice-app/ClaudeVoice && xcodebuild -scheme ClaudeVoice -destination 'platform=iOS Simulator,name=iPhone 16' build 2>&1 | tail -10`
Expected: BUILD SUCCEEDED

### Step 4: Commit

```bash
git add ios-voice-app/ClaudeVoice/ClaudeVoice/Views/ProjectsListView.swift
git commit -m "feat: add Add Project button to ProjectsListView"
```

---

## Task 13: Run All Python Tests

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

## Task 14: Run iOS Build and Tests

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

## Task 15: Manual Integration Test

Test the full flow manually to verify VSCode integration works.

### Checklist:

1. **Verify extension is installed:**
   - Open VS Code
   - Run the verification script from Prerequisites
   - Should see "✅ Connected" and "✅ Command sent"

2. **Start server:**
   ```bash
   cd /Users/aaron/Desktop/max/voice_server
   source ../.venv/bin/activate
   python ios_server.py
   ```
   - Should see "✅ Connected to VSCode extension"

3. **Test voice input:**
   - Send voice input from iOS app
   - Verify text appears in VS Code terminal
   - Verify Claude responds and TTS plays

4. **Test session actions:**
   - Tap Resume on a session → should run `claude --resume <id>`
   - Tap Close → should send Ctrl+C
   - Tap New Session → should open terminal and run `claude`
   - Tap Add Project → should create folder and open in VS Code

---

## Summary

This plan implements all deferred VSCode connection features:

| Feature | Server Handler | iOS Method | UI Location |
|---------|---------------|------------|-------------|
| Replace AppleScript | Updated `send_to_vs_code()` | N/A | Transparent |
| Close Session | `handle_close_session()` | `closeSession()` | SessionView toolbar |
| New Session | `handle_new_session()` | `newSession()` | SessionsListView toolbar |
| Resume Session | `handle_resume_session()` | `resumeSession()` | SessionView toolbar |
| Add Project | `handle_add_project()` | `addProject()` | ProjectsListView toolbar |

All features have unit tests and gracefully fall back when VSCode extension is unavailable.
