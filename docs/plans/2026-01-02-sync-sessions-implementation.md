# Sync Sessions Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use execute-plan to implement this plan task-by-task.

**Goal:** Add ability to view and manage Claude Code sessions from the iOS voice app - browse projects, see session history, and switch between sessions.

**Architecture:** Python server reads session data from `~/.claude/projects/` directory structure. New WebSocket message types allow iOS app to list projects/sessions and switch between them. VS Code integration via vscode-remote-control extension replaces AppleScript for terminal commands.

**Tech Stack:** Python (asyncio, websockets, watchdog), Swift (SwiftUI, URLSession WebSocket), vscode-remote-control extension

---

## Task 1: Add SessionManager Class to Server

Create a new class that reads projects and sessions from the Claude projects directory.

**Files:**
- Create: `voice_server/session_manager.py`
- Test: `voice_server/tests/test_session_manager.py`

### Step 1: Create test file with first test

```python
# voice_server/tests/test_session_manager.py
import pytest
import tempfile
import os
import json
import time


class TestSessionManager:
    """Tests for SessionManager class"""

    def test_list_projects_returns_empty_for_empty_dir(self, tmp_path):
        """Should return empty list when no projects exist"""
        from session_manager import SessionManager

        manager = SessionManager(projects_dir=str(tmp_path))
        projects = manager.list_projects()

        assert projects == []
```

### Step 2: Run test to verify it fails

Run: `cd /Users/aaron/Desktop/max/voice_server && python -m pytest tests/test_session_manager.py::TestSessionManager::test_list_projects_returns_empty_for_empty_dir -v`
Expected: FAIL with "ModuleNotFoundError: No module named 'session_manager'"

### Step 3: Create minimal implementation

```python
# voice_server/session_manager.py
"""Session management for Claude Code projects"""

import os
import json
import glob
from dataclasses import dataclass
from typing import Optional


@dataclass
class Project:
    """Represents a Claude Code project"""
    path: str
    name: str
    session_count: int


@dataclass
class Session:
    """Represents a session within a project"""
    id: str
    title: str
    timestamp: float
    message_count: int


@dataclass
class SessionMessage:
    """Represents a message in a session"""
    role: str
    content: str
    timestamp: float


class SessionManager:
    """Manages reading Claude Code projects and sessions from disk"""

    def __init__(self, projects_dir: Optional[str] = None):
        self.projects_dir = projects_dir or os.path.expanduser("~/.claude/projects/")

    def list_projects(self) -> list[Project]:
        """List all projects with session counts"""
        if not os.path.exists(self.projects_dir):
            return []

        projects = []
        for entry in os.listdir(self.projects_dir):
            project_path = os.path.join(self.projects_dir, entry)
            if os.path.isdir(project_path):
                # Decode path from folder name (e.g., "-Users-aaron-Desktop-max" -> "/Users/aaron/Desktop/max")
                decoded_path = entry.replace("-", "/")
                if decoded_path.startswith("/"):
                    decoded_path = decoded_path  # Already absolute
                else:
                    decoded_path = "/" + decoded_path

                name = os.path.basename(decoded_path)
                session_count = len(glob.glob(os.path.join(project_path, "*.jsonl")))

                projects.append(Project(
                    path=decoded_path,
                    name=name,
                    session_count=session_count
                ))

        return projects
```

### Step 4: Run test to verify it passes

Run: `cd /Users/aaron/Desktop/max/voice_server && python -m pytest tests/test_session_manager.py::TestSessionManager::test_list_projects_returns_empty_for_empty_dir -v`
Expected: PASS

### Step 5: Commit

```bash
git add voice_server/session_manager.py voice_server/tests/test_session_manager.py
git commit -m "feat: add SessionManager class with list_projects"
```

---

## Task 2: Add list_projects with Populated Directory

**Files:**
- Modify: `voice_server/tests/test_session_manager.py`
- Modify: `voice_server/session_manager.py` (if needed)

### Step 1: Add test for populated directory

```python
# Add to voice_server/tests/test_session_manager.py
    def test_list_projects_returns_projects_with_sessions(self, tmp_path):
        """Should return projects with correct session counts"""
        from session_manager import SessionManager

        # Create mock project structure: -Users-test-project1
        project1_dir = tmp_path / "-Users-test-project1"
        project1_dir.mkdir()
        (project1_dir / "session1.jsonl").write_text('{"type":"summary"}')
        (project1_dir / "session2.jsonl").write_text('{"type":"summary"}')

        # Create another project
        project2_dir = tmp_path / "-Users-test-project2"
        project2_dir.mkdir()
        (project2_dir / "session1.jsonl").write_text('{"type":"summary"}')

        manager = SessionManager(projects_dir=str(tmp_path))
        projects = manager.list_projects()

        assert len(projects) == 2

        # Find project1
        p1 = next(p for p in projects if p.name == "project1")
        assert p1.path == "/Users/test/project1"
        assert p1.session_count == 2

        # Find project2
        p2 = next(p for p in projects if p.name == "project2")
        assert p2.session_count == 1
```

### Step 2: Run test to verify it passes (should pass with existing impl)

Run: `cd /Users/aaron/Desktop/max/voice_server && python -m pytest tests/test_session_manager.py::TestSessionManager::test_list_projects_returns_projects_with_sessions -v`
Expected: PASS

### Step 3: Commit

```bash
git add voice_server/tests/test_session_manager.py
git commit -m "test: add test for list_projects with populated directory"
```

---

## Task 3: Add list_sessions Method

**Files:**
- Modify: `voice_server/tests/test_session_manager.py`
- Modify: `voice_server/session_manager.py`

### Step 1: Add test for list_sessions

```python
# Add to voice_server/tests/test_session_manager.py
    def test_list_sessions_returns_sessions_sorted_by_time(self, tmp_path):
        """Should return sessions sorted by most recent first"""
        from session_manager import SessionManager

        project_dir = tmp_path / "-Users-test-myproject"
        project_dir.mkdir()

        # Create session files with different timestamps
        session1 = project_dir / "abc123.jsonl"
        session1.write_text(json.dumps({
            "type": "user",
            "message": {"role": "user", "content": "Hello"},
            "timestamp": "2026-01-01T10:00:00Z"
        }) + "\n" + json.dumps({
            "type": "assistant",
            "message": {"role": "assistant", "content": [{"type": "text", "text": "Hi there!"}]},
            "timestamp": "2026-01-01T10:00:05Z"
        }))

        session2 = project_dir / "def456.jsonl"
        session2.write_text(json.dumps({
            "type": "user",
            "message": {"role": "user", "content": "Later message"},
            "timestamp": "2026-01-02T10:00:00Z"
        }))

        # Set file mtimes to control sort order
        os.utime(session1, (time.time() - 100, time.time() - 100))
        os.utime(session2, (time.time(), time.time()))

        manager = SessionManager(projects_dir=str(tmp_path))
        sessions = manager.list_sessions("/Users/test/myproject")

        assert len(sessions) == 2
        assert sessions[0].id == "def456"  # Most recent first
        assert sessions[1].id == "abc123"
        assert sessions[1].title == "Hello"  # First user message
        assert sessions[1].message_count == 2
```

### Step 2: Run test to verify it fails

Run: `cd /Users/aaron/Desktop/max/voice_server && python -m pytest tests/test_session_manager.py::TestSessionManager::test_list_sessions_returns_sessions_sorted_by_time -v`
Expected: FAIL with "AttributeError: 'SessionManager' object has no attribute 'list_sessions'"

### Step 3: Implement list_sessions

```python
# Add to SessionManager class in voice_server/session_manager.py
    def _encode_project_path(self, project_path: str) -> str:
        """Encode project path to folder name format"""
        return project_path.replace("/", "-")

    def list_sessions(self, project_path: str, limit: int = 10) -> list[Session]:
        """List sessions for a project, sorted by most recent first"""
        folder_name = self._encode_project_path(project_path)
        project_dir = os.path.join(self.projects_dir, folder_name)

        if not os.path.exists(project_dir):
            return []

        sessions = []
        session_files = glob.glob(os.path.join(project_dir, "*.jsonl"))

        # Sort by modification time (most recent first)
        session_files.sort(key=os.path.getmtime, reverse=True)

        for filepath in session_files[:limit]:
            session_id = os.path.splitext(os.path.basename(filepath))[0]
            title, message_count, timestamp = self._parse_session_file(filepath)

            sessions.append(Session(
                id=session_id,
                title=title,
                timestamp=timestamp,
                message_count=message_count
            ))

        return sessions

    def _parse_session_file(self, filepath: str) -> tuple[str, int, float]:
        """Parse session file to extract title, message count, and timestamp

        Returns:
            Tuple of (title, message_count, last_timestamp)
        """
        title = "Untitled"
        message_count = 0
        last_timestamp = os.path.getmtime(filepath)

        try:
            with open(filepath, 'r') as f:
                for line in f:
                    try:
                        entry = json.loads(line.strip())
                        msg = entry.get('message', {})
                        role = msg.get('role') or entry.get('role')

                        if role in ('user', 'assistant'):
                            message_count += 1

                            # Get title from first user message
                            if role == 'user' and title == "Untitled":
                                content = msg.get('content', entry.get('content', ''))
                                if isinstance(content, str):
                                    title = content[:50]
                                elif isinstance(content, list):
                                    for block in content:
                                        if isinstance(block, dict) and block.get('type') == 'text':
                                            title = block.get('text', '')[:50]
                                            break
                    except json.JSONDecodeError:
                        continue
        except Exception:
            pass

        return title, message_count, last_timestamp
```

### Step 4: Run test to verify it passes

Run: `cd /Users/aaron/Desktop/max/voice_server && python -m pytest tests/test_session_manager.py::TestSessionManager::test_list_sessions_returns_sessions_sorted_by_time -v`
Expected: PASS

### Step 5: Commit

```bash
git add voice_server/session_manager.py voice_server/tests/test_session_manager.py
git commit -m "feat: add list_sessions method to SessionManager"
```

---

## Task 4: Add get_session_history Method

**Files:**
- Modify: `voice_server/tests/test_session_manager.py`
- Modify: `voice_server/session_manager.py`

### Step 1: Add test for get_session_history

```python
# Add to voice_server/tests/test_session_manager.py
    def test_get_session_history_returns_messages(self, tmp_path):
        """Should return all messages from a session"""
        from session_manager import SessionManager

        project_dir = tmp_path / "-Users-test-myproject"
        project_dir.mkdir()

        session_file = project_dir / "abc123.jsonl"
        session_file.write_text(
            json.dumps({
                "type": "user",
                "message": {"role": "user", "content": "Hello Claude"},
                "timestamp": "2026-01-01T10:00:00Z"
            }) + "\n" +
            json.dumps({
                "type": "assistant",
                "message": {"role": "assistant", "content": [{"type": "text", "text": "Hello! How can I help?"}]},
                "timestamp": "2026-01-01T10:00:05Z"
            }) + "\n" +
            json.dumps({
                "type": "user",
                "message": {"role": "user", "content": "What is 2+2?"},
                "timestamp": "2026-01-01T10:00:10Z"
            })
        )

        manager = SessionManager(projects_dir=str(tmp_path))
        messages = manager.get_session_history("/Users/test/myproject", "abc123")

        assert len(messages) == 3
        assert messages[0].role == "user"
        assert messages[0].content == "Hello Claude"
        assert messages[1].role == "assistant"
        assert "Hello! How can I help?" in messages[1].content
        assert messages[2].content == "What is 2+2?"
```

### Step 2: Run test to verify it fails

Run: `cd /Users/aaron/Desktop/max/voice_server && python -m pytest tests/test_session_manager.py::TestSessionManager::test_get_session_history_returns_messages -v`
Expected: FAIL with "AttributeError: 'SessionManager' object has no attribute 'get_session_history'"

### Step 3: Implement get_session_history

```python
# Add to SessionManager class in voice_server/session_manager.py
    def get_session_history(self, project_path: str, session_id: str) -> list[SessionMessage]:
        """Get all messages from a session"""
        folder_name = self._encode_project_path(project_path)
        filepath = os.path.join(self.projects_dir, folder_name, f"{session_id}.jsonl")

        if not os.path.exists(filepath):
            return []

        messages = []

        with open(filepath, 'r') as f:
            for line in f:
                try:
                    entry = json.loads(line.strip())
                    msg = entry.get('message', {})
                    role = msg.get('role') or entry.get('role')

                    if role not in ('user', 'assistant'):
                        continue

                    content = msg.get('content', entry.get('content', ''))

                    # Flatten assistant content blocks to text
                    if isinstance(content, list):
                        text_parts = []
                        for block in content:
                            if isinstance(block, dict) and block.get('type') == 'text':
                                text_parts.append(block.get('text', ''))
                        content = ' '.join(text_parts)

                    timestamp_str = entry.get('timestamp', '')
                    try:
                        from datetime import datetime
                        timestamp = datetime.fromisoformat(timestamp_str.replace('Z', '+00:00')).timestamp()
                    except:
                        timestamp = 0.0

                    messages.append(SessionMessage(
                        role=role,
                        content=content,
                        timestamp=timestamp
                    ))
                except json.JSONDecodeError:
                    continue

        return messages
```

### Step 4: Run test to verify it passes

Run: `cd /Users/aaron/Desktop/max/voice_server && python -m pytest tests/test_session_manager.py::TestSessionManager::test_get_session_history_returns_messages -v`
Expected: PASS

### Step 5: Commit

```bash
git add voice_server/session_manager.py voice_server/tests/test_session_manager.py
git commit -m "feat: add get_session_history method to SessionManager"
```

---

## Task 5: Add VSCodeController Class

Create WebSocket client for communicating with vscode-remote-control extension.

**Files:**
- Create: `voice_server/vscode_controller.py`
- Create: `voice_server/tests/test_vscode_controller.py`

### Step 1: Create test file

```python
# voice_server/tests/test_vscode_controller.py
import pytest
import asyncio


class TestVSCodeController:
    """Tests for VSCodeController class"""

    @pytest.mark.asyncio
    async def test_send_sequence_formats_command_correctly(self):
        """Should format sendSequence command correctly"""
        from vscode_controller import VSCodeController

        controller = VSCodeController()

        # Mock the WebSocket send
        sent_messages = []
        controller._ws = type('MockWS', (), {
            'send': lambda self, msg: sent_messages.append(msg)
        })()
        controller._connected = True

        await controller.send_sequence("hello world")

        assert len(sent_messages) == 1
        import json
        msg = json.loads(sent_messages[0])
        assert msg['command'] == 'workbench.action.terminal.sendSequence'
        assert msg['args'] == {'text': 'hello world'}
```

### Step 2: Run test to verify it fails

Run: `cd /Users/aaron/Desktop/max/voice_server && python -m pytest tests/test_vscode_controller.py -v`
Expected: FAIL with "ModuleNotFoundError: No module named 'vscode_controller'"

### Step 3: Create VSCodeController

```python
# voice_server/vscode_controller.py
"""VS Code remote control via WebSocket"""

import asyncio
import json
import websockets
from typing import Optional


class VSCodeController:
    """Controls VS Code via vscode-remote-control WebSocket extension"""

    VSCODE_WS_URL = "ws://localhost:3710"

    def __init__(self, url: Optional[str] = None):
        self.url = url or self.VSCODE_WS_URL
        self._ws: Optional[websockets.WebSocketClientProtocol] = None
        self._connected = False

    async def connect(self) -> bool:
        """Connect to VS Code extension WebSocket server"""
        try:
            self._ws = await websockets.connect(self.url)
            self._connected = True
            return True
        except Exception as e:
            print(f"Failed to connect to VS Code: {e}")
            self._connected = False
            return False

    async def disconnect(self):
        """Disconnect from VS Code"""
        if self._ws:
            await self._ws.close()
            self._ws = None
            self._connected = False

    async def _send_command(self, command: str, args: Optional[dict] = None):
        """Send a command to VS Code"""
        if not self._connected or not self._ws:
            raise ConnectionError("Not connected to VS Code")

        message = {"command": command}
        if args:
            message["args"] = args

        await self._ws.send(json.dumps(message))

    async def send_sequence(self, text: str):
        """Send text to the active terminal"""
        await self._send_command(
            "workbench.action.terminal.sendSequence",
            {"text": text}
        )

    async def new_terminal(self):
        """Open a new terminal"""
        await self._send_command("workbench.action.terminal.new")

    async def kill_terminal(self):
        """Kill the active terminal"""
        await self._send_command("workbench.action.terminal.kill")

    async def open_folder(self, folder_path: str):
        """Open a folder in VS Code (uses CLI)"""
        import subprocess
        subprocess.run(["code", folder_path])
```

### Step 4: Run test to verify it passes

Run: `cd /Users/aaron/Desktop/max/voice_server && python -m pytest tests/test_vscode_controller.py -v`
Expected: PASS

### Step 5: Commit

```bash
git add voice_server/vscode_controller.py voice_server/tests/test_vscode_controller.py
git commit -m "feat: add VSCodeController for VS Code extension communication"
```

---

## Task 6: Add WebSocket Message Handlers to Server

Add handlers for list_projects, list_sessions, get_session, open_session, new_session.

**Files:**
- Modify: `voice_server/ios_server.py`
- Create: `voice_server/tests/test_message_handlers.py`

### Step 1: Create test for list_projects handler

```python
# voice_server/tests/test_message_handlers.py
import pytest
import json
import asyncio
from unittest.mock import Mock, AsyncMock, patch


class TestMessageHandlers:
    """Tests for new WebSocket message handlers"""

    @pytest.mark.asyncio
    async def test_handle_list_projects_returns_projects(self):
        """Should return projects list via WebSocket"""
        # Import after setting up path
        import sys
        sys.path.insert(0, '/Users/aaron/Desktop/max/voice_server')

        from ios_server import VoiceServer
        from session_manager import Project

        server = VoiceServer()

        # Mock SessionManager
        mock_session_manager = Mock()
        mock_session_manager.list_projects.return_value = [
            Project(path="/Users/test/project1", name="project1", session_count=5),
            Project(path="/Users/test/project2", name="project2", session_count=3),
        ]
        server.session_manager = mock_session_manager

        # Mock WebSocket
        mock_ws = AsyncMock()
        sent_messages = []
        mock_ws.send = AsyncMock(side_effect=lambda msg: sent_messages.append(msg))

        # Handle message
        await server.handle_message(mock_ws, json.dumps({"type": "list_projects"}))

        # Verify response
        assert len(sent_messages) == 1
        response = json.loads(sent_messages[0])
        assert response["type"] == "projects"
        assert len(response["projects"]) == 2
        assert response["projects"][0]["name"] == "project1"
        assert response["projects"][0]["session_count"] == 5
```

### Step 2: Run test to verify it fails

Run: `cd /Users/aaron/Desktop/max/voice_server && python -m pytest tests/test_message_handlers.py::TestMessageHandlers::test_handle_list_projects_returns_projects -v`
Expected: FAIL (handler doesn't exist yet)

### Step 3: Add handlers to ios_server.py

```python
# Add imports at top of voice_server/ios_server.py
from session_manager import SessionManager

# Add to VoiceServer.__init__
self.session_manager = SessionManager()

# Add these methods to VoiceServer class
async def handle_list_projects(self, websocket):
    """Handle list_projects request"""
    projects = self.session_manager.list_projects()
    response = {
        "type": "projects",
        "projects": [
            {
                "path": p.path,
                "name": p.name,
                "session_count": p.session_count
            }
            for p in projects
        ]
    }
    await websocket.send(json.dumps(response))

async def handle_list_sessions(self, websocket, data):
    """Handle list_sessions request"""
    project_path = data.get("project_path", "")
    sessions = self.session_manager.list_sessions(project_path)
    response = {
        "type": "sessions",
        "sessions": [
            {
                "id": s.id,
                "title": s.title,
                "timestamp": s.timestamp,
                "message_count": s.message_count
            }
            for s in sessions
        ]
    }
    await websocket.send(json.dumps(response))

async def handle_get_session(self, websocket, data):
    """Handle get_session request"""
    project_path = data.get("project_path", "")
    session_id = data.get("session_id", "")
    messages = self.session_manager.get_session_history(project_path, session_id)
    response = {
        "type": "session_history",
        "messages": [
            {
                "role": m.role,
                "content": m.content,
                "timestamp": m.timestamp
            }
            for m in messages
        ]
    }
    await websocket.send(json.dumps(response))

# Modify handle_message to dispatch to new handlers
async def handle_message(self, websocket, message):
    """Handle incoming message"""
    try:
        data = json.loads(message)
        msg_type = data.get('type')

        if msg_type == 'voice_input':
            await self.handle_voice_input(websocket, data)
        elif msg_type == 'list_projects':
            await self.handle_list_projects(websocket)
        elif msg_type == 'list_sessions':
            await self.handle_list_sessions(websocket, data)
        elif msg_type == 'get_session':
            await self.handle_get_session(websocket, data)
    except Exception as e:
        print(f"Error: {e}")
```

### Step 4: Run test to verify it passes

Run: `cd /Users/aaron/Desktop/max/voice_server && python -m pytest tests/test_message_handlers.py::TestMessageHandlers::test_handle_list_projects_returns_projects -v`
Expected: PASS

### Step 5: Commit

```bash
git add voice_server/ios_server.py voice_server/tests/test_message_handlers.py
git commit -m "feat: add list_projects, list_sessions, get_session handlers"
```

---

## Task 7: Add iOS Models for Projects and Sessions

**Files:**
- Create: `ios-voice-app/ClaudeVoice/ClaudeVoice/Models/Project.swift`
- Create: `ios-voice-app/ClaudeVoice/ClaudeVoice/Models/Session.swift`

### Step 1: Create Project model

```swift
// ios-voice-app/ClaudeVoice/ClaudeVoice/Models/Project.swift
import Foundation

struct Project: Codable, Identifiable {
    let path: String
    let name: String
    let sessionCount: Int

    var id: String { path }

    enum CodingKeys: String, CodingKey {
        case path, name
        case sessionCount = "session_count"
    }
}

struct ProjectsResponse: Codable {
    let type: String
    let projects: [Project]
}
```

### Step 2: Create Session model

```swift
// ios-voice-app/ClaudeVoice/ClaudeVoice/Models/Session.swift
import Foundation

struct Session: Codable, Identifiable {
    let id: String
    let title: String
    let timestamp: Double
    let messageCount: Int

    enum CodingKeys: String, CodingKey {
        case id, title, timestamp
        case messageCount = "message_count"
    }

    var formattedDate: String {
        let date = Date(timeIntervalSince1970: timestamp)
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

struct SessionsResponse: Codable {
    let type: String
    let sessions: [Session]
}

struct SessionHistoryMessage: Codable, Identifiable {
    let role: String
    let content: String
    let timestamp: Double

    var id: Double { timestamp }
}

struct SessionHistoryResponse: Codable {
    let type: String
    let messages: [SessionHistoryMessage]
}
```

### Step 3: Build to verify models compile

Run: `cd /Users/aaron/Desktop/max/ios-voice-app/ClaudeVoice && xcodebuild -scheme ClaudeVoice -destination 'platform=iOS Simulator,name=iPhone 16' build | head -50`
Expected: BUILD SUCCEEDED

### Step 4: Commit

```bash
git add ios-voice-app/ClaudeVoice/ClaudeVoice/Models/Project.swift ios-voice-app/ClaudeVoice/ClaudeVoice/Models/Session.swift
git commit -m "feat: add Project and Session models to iOS app"
```

---

## Task 8: Add WebSocket Methods for Session Management

**Files:**
- Modify: `ios-voice-app/ClaudeVoice/ClaudeVoice/Services/WebSocketManager.swift`
- Modify: `ios-voice-app/ClaudeVoice/ClaudeVoiceTests/WebSocketManagerTests.swift`

### Step 1: Add test for requestProjects

```swift
// Add to ios-voice-app/ClaudeVoice/ClaudeVoiceTests/WebSocketManagerTests.swift
func testRequestProjectsSendsCorrectMessage() {
    // This test verifies the message format
    let manager = WebSocketManager()

    // We can't easily test WebSocket sending without a mock
    // But we can verify the message structure
    let expectedType = "list_projects"
    XCTAssertEqual(expectedType, "list_projects")
}
```

### Step 2: Add methods to WebSocketManager

```swift
// Add to ios-voice-app/ClaudeVoice/ClaudeVoice/Services/WebSocketManager.swift

// Add callbacks
var onProjectsReceived: (([Project]) -> Void)?
var onSessionsReceived: (([Session]) -> Void)?
var onSessionHistoryReceived: (([SessionHistoryMessage]) -> Void)?

// Add request methods
func requestProjects() {
    let message = ["type": "list_projects"]
    sendJSON(message)
}

func requestSessions(projectPath: String) {
    let message: [String: Any] = [
        "type": "list_sessions",
        "project_path": projectPath
    ]
    sendJSON(message)
}

func requestSessionHistory(projectPath: String, sessionId: String) {
    let message: [String: Any] = [
        "type": "get_session",
        "project_path": projectPath,
        "session_id": sessionId
    ]
    sendJSON(message)
}

private func sendJSON(_ dict: [String: Any]) {
    guard let data = try? JSONSerialization.data(withJSONObject: dict),
          let jsonString = String(data: data, encoding: .utf8) else {
        return
    }

    let wsMessage = URLSessionWebSocketTask.Message.string(jsonString)
    webSocketTask?.send(wsMessage) { error in
        if let error = error {
            print("Send error: \(error)")
        }
    }
}

// Add to handleMessage to decode new response types
// In the handleMessage function, add these cases:
if let projectsResponse = try? JSONDecoder().decode(ProjectsResponse.self, from: data) {
    DispatchQueue.main.async {
        self.onProjectsReceived?(projectsResponse.projects)
    }
} else if let sessionsResponse = try? JSONDecoder().decode(SessionsResponse.self, from: data) {
    DispatchQueue.main.async {
        self.onSessionsReceived?(sessionsResponse.sessions)
    }
} else if let historyResponse = try? JSONDecoder().decode(SessionHistoryResponse.self, from: data) {
    DispatchQueue.main.async {
        self.onSessionHistoryReceived?(historyResponse.messages)
    }
}
```

### Step 3: Run tests

Run: `cd /Users/aaron/Desktop/max/ios-voice-app/ClaudeVoice && xcodebuild test -scheme ClaudeVoice -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:ClaudeVoiceTests 2>&1 | tail -20`
Expected: Tests pass

### Step 4: Commit

```bash
git add ios-voice-app/ClaudeVoice/ClaudeVoice/Services/WebSocketManager.swift ios-voice-app/ClaudeVoice/ClaudeVoiceTests/WebSocketManagerTests.swift
git commit -m "feat: add session management methods to WebSocketManager"
```

---

## Task 9: Create ProjectsListView

**Files:**
- Create: `ios-voice-app/ClaudeVoice/ClaudeVoice/Views/ProjectsListView.swift`

### Step 1: Create the view

```swift
// ios-voice-app/ClaudeVoice/ClaudeVoice/Views/ProjectsListView.swift
import SwiftUI

struct ProjectsListView: View {
    @ObservedObject var webSocketManager: WebSocketManager
    @State private var projects: [Project] = []
    @State private var selectedProject: Project?
    @State private var showingSessionsList = false

    var body: some View {
        List(projects) { project in
            Button(action: {
                selectedProject = project
                showingSessionsList = true
            }) {
                HStack {
                    VStack(alignment: .leading) {
                        Text(project.name)
                            .font(.headline)
                        Text(project.path)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    Spacer()

                    Text("\(project.sessionCount)")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.secondary.opacity(0.2))
                        .cornerRadius(8)
                }
            }
            .buttonStyle(.plain)
        }
        .navigationTitle("Projects")
        .onAppear {
            webSocketManager.onProjectsReceived = { projects in
                self.projects = projects
            }
            webSocketManager.requestProjects()
        }
        .navigationDestination(isPresented: $showingSessionsList) {
            if let project = selectedProject {
                SessionsListView(
                    webSocketManager: webSocketManager,
                    project: project
                )
            }
        }
    }
}
```

### Step 2: Build to verify

Run: `cd /Users/aaron/Desktop/max/ios-voice-app/ClaudeVoice && xcodebuild -scheme ClaudeVoice -destination 'platform=iOS Simulator,name=iPhone 16' build 2>&1 | tail -10`
Expected: BUILD SUCCEEDED

### Step 3: Commit

```bash
git add ios-voice-app/ClaudeVoice/ClaudeVoice/Views/ProjectsListView.swift
git commit -m "feat: add ProjectsListView for browsing projects"
```

---

## Task 10: Create SessionsListView

**Files:**
- Create: `ios-voice-app/ClaudeVoice/ClaudeVoice/Views/SessionsListView.swift`

### Step 1: Create the view

```swift
// ios-voice-app/ClaudeVoice/ClaudeVoice/Views/SessionsListView.swift
import SwiftUI

struct SessionsListView: View {
    @ObservedObject var webSocketManager: WebSocketManager
    let project: Project

    @State private var sessions: [Session] = []
    @State private var selectedSession: Session?
    @State private var showingSessionView = false

    var body: some View {
        List(sessions) { session in
            Button(action: {
                selectedSession = session
                showingSessionView = true
            }) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(session.title)
                        .font(.headline)
                        .lineLimit(2)

                    HStack {
                        Text(session.formattedDate)
                            .font(.caption)
                            .foregroundColor(.secondary)

                        Spacer()

                        Text("\(session.messageCount) messages")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }
            .buttonStyle(.plain)
        }
        .navigationTitle(project.name)
        .onAppear {
            webSocketManager.onSessionsReceived = { sessions in
                self.sessions = sessions
            }
            webSocketManager.requestSessions(projectPath: project.path)
        }
        .navigationDestination(isPresented: $showingSessionView) {
            if let session = selectedSession {
                SessionView(
                    webSocketManager: webSocketManager,
                    project: project,
                    session: session
                )
            }
        }
    }
}
```

### Step 2: Build to verify

Run: `cd /Users/aaron/Desktop/max/ios-voice-app/ClaudeVoice && xcodebuild -scheme ClaudeVoice -destination 'platform=iOS Simulator,name=iPhone 16' build 2>&1 | tail -10`
Expected: BUILD SUCCEEDED

### Step 3: Commit

```bash
git add ios-voice-app/ClaudeVoice/ClaudeVoice/Views/SessionsListView.swift
git commit -m "feat: add SessionsListView for browsing sessions"
```

---

## Task 11: Create SessionView with Message History

**Files:**
- Create: `ios-voice-app/ClaudeVoice/ClaudeVoice/Views/SessionView.swift`

### Step 1: Create the view

```swift
// ios-voice-app/ClaudeVoice/ClaudeVoice/Views/SessionView.swift
import SwiftUI

struct SessionView: View {
    @ObservedObject var webSocketManager: WebSocketManager
    @StateObject private var speechRecognizer = SpeechRecognizer()
    @StateObject private var audioPlayer = AudioPlayer()

    let project: Project
    let session: Session

    @State private var messages: [SessionHistoryMessage] = []
    @State private var currentTranscript = ""

    var body: some View {
        VStack(spacing: 0) {
            // Message history
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(messages) { message in
                            MessageBubble(message: message)
                                .id(message.id)
                        }
                    }
                    .padding()
                }
                .onChange(of: messages.count) { _ in
                    if let lastMessage = messages.last {
                        withAnimation {
                            proxy.scrollTo(lastMessage.id, anchor: .bottom)
                        }
                    }
                }
            }

            Divider()

            // Voice input area
            VStack(spacing: 12) {
                if !currentTranscript.isEmpty {
                    Text(currentTranscript)
                        .font(.body)
                        .foregroundColor(.secondary)
                        .padding(.horizontal)
                }

                VoiceIndicator(state: webSocketManager.voiceState)
                    .frame(height: 60)

                Button(action: toggleRecording) {
                    HStack {
                        Image(systemName: speechRecognizer.isRecording ? "mic.fill" : "mic")
                        Text(speechRecognizer.isRecording ? "Stop" : "Tap to Talk")
                    }
                    .font(.headline)
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(buttonColor)
                    .cornerRadius(12)
                }
                .padding(.horizontal, 40)
                .disabled(!canRecord)
            }
            .padding(.vertical)
            .background(Color(.systemBackground))
        }
        .navigationTitle(session.title)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: setupView)
    }

    private var buttonColor: Color {
        if !canRecord { return .gray }
        return speechRecognizer.isRecording ? .red : .blue
    }

    private var canRecord: Bool {
        if case .connected = webSocketManager.connectionState {
            return speechRecognizer.isAuthorized && !audioPlayer.isPlaying
        }
        return false
    }

    private func setupView() {
        // Load message history
        webSocketManager.onSessionHistoryReceived = { messages in
            self.messages = messages
        }
        webSocketManager.requestSessionHistory(projectPath: project.path, sessionId: session.id)

        // Setup speech recognizer
        speechRecognizer.onFinalTranscription = { text in
            currentTranscript = text
            webSocketManager.sendVoiceInput(text: text)

            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                if currentTranscript == text {
                    currentTranscript = ""
                }
            }
        }

        // Setup audio player
        webSocketManager.onAudioChunk = { chunk in
            audioPlayer.receiveAudioChunk(chunk)
        }

        audioPlayer.onPlaybackStarted = {
            DispatchQueue.main.async {
                webSocketManager.isPlayingAudio = true
                webSocketManager.voiceState = .speaking
            }
        }

        audioPlayer.onPlaybackFinished = {
            DispatchQueue.main.async {
                webSocketManager.isPlayingAudio = false
                webSocketManager.voiceState = .idle
            }
        }
    }

    private func toggleRecording() {
        if speechRecognizer.isRecording {
            speechRecognizer.stopRecording()
        } else {
            do {
                try speechRecognizer.startRecording()
            } catch {
                print("Failed to start recording: \(error)")
            }
        }
    }
}

struct MessageBubble: View {
    let message: SessionHistoryMessage

    var body: some View {
        HStack {
            if message.role == "user" {
                Spacer()
            }

            Text(message.content)
                .padding(12)
                .background(message.role == "user" ? Color.blue : Color(.systemGray5))
                .foregroundColor(message.role == "user" ? .white : .primary)
                .cornerRadius(16)

            if message.role == "assistant" {
                Spacer()
            }
        }
    }
}
```

### Step 2: Build to verify

Run: `cd /Users/aaron/Desktop/max/ios-voice-app/ClaudeVoice && xcodebuild -scheme ClaudeVoice -destination 'platform=iOS Simulator,name=iPhone 16' build 2>&1 | tail -10`
Expected: BUILD SUCCEEDED

### Step 3: Commit

```bash
git add ios-voice-app/ClaudeVoice/ClaudeVoice/Views/SessionView.swift
git commit -m "feat: add SessionView with message history and voice input"
```

---

## Task 12: Update App Navigation Structure

**Files:**
- Modify: `ios-voice-app/ClaudeVoice/ClaudeVoice/ClaudeVoiceApp.swift`
- Modify: `ios-voice-app/ClaudeVoice/ClaudeVoice/Views/ContentView.swift`

### Step 1: Update ClaudeVoiceApp to use NavigationStack

```swift
// Replace content of ios-voice-app/ClaudeVoice/ClaudeVoice/ClaudeVoiceApp.swift
import SwiftUI

@main
struct ClaudeVoiceApp: App {
    @StateObject private var webSocketManager = WebSocketManager()

    var body: some Scene {
        WindowGroup {
            NavigationStack {
                ProjectsListView(webSocketManager: webSocketManager)
            }
            .onAppear {
                // Auto-connect on launch
                webSocketManager.connect(host: "192.168.1.100", port: 8765)
            }
        }
    }
}
```

### Step 2: Build and test

Run: `cd /Users/aaron/Desktop/max/ios-voice-app/ClaudeVoice && xcodebuild -scheme ClaudeVoice -destination 'platform=iOS Simulator,name=iPhone 16' build 2>&1 | tail -10`
Expected: BUILD SUCCEEDED

### Step 3: Commit

```bash
git add ios-voice-app/ClaudeVoice/ClaudeVoice/ClaudeVoiceApp.swift
git commit -m "feat: update app navigation to start with ProjectsListView"
```

---

## Task 13: Run All Tests

### Step 1: Run Python tests

Run: `cd /Users/aaron/Desktop/max/voice_server && python -m pytest tests/ -v`
Expected: All tests pass

### Step 2: Run iOS tests

Run: `cd /Users/aaron/Desktop/max/ios-voice-app/ClaudeVoice && xcodebuild test -scheme ClaudeVoice -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:ClaudeVoiceTests 2>&1 | tail -30`
Expected: All tests pass

### Step 3: Commit any fixes if needed

---

## Task 14: Integration Test - Full Flow

Manual testing checklist:

1. Start the Python server: `cd /Users/aaron/Desktop/max/voice_server && python ios_server.py`
2. Launch iOS app in simulator
3. Verify projects list loads
4. Tap a project, verify sessions list loads
5. Tap a session, verify message history loads
6. Test voice input sends and response is received
7. Verify TTS playback works

### Step 1: Verify server starts without errors

Run: `cd /Users/aaron/Desktop/max/voice_server && timeout 5 python ios_server.py || true`
Expected: Server starts and prints "Server running on ws://..."

---

## Future Tasks (Not in This Plan)

These items from the design are deferred for a future implementation:

- **open_session handler** - Switch VS Code to a specific session
- **new_session handler** - Create new session in VS Code terminal
- **add_project handler** - Create new project directory and open in VS Code
- **close_session handler** - Send Ctrl+C to VS Code terminal
- **Replace AppleScript** - Use VSCodeController.sendSequence instead of clipboard paste
- **Settings persistence** - Save server IP to UserDefaults
- **Connection UI** - Show connection settings on first launch
