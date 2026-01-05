# Remote Permission Control - Part 4: Integration & Documentation

> **For Claude:** REQUIRED SUB-SKILL: Use execute-plan to implement this plan task-by-task.

**Goal:** Integrate all components into the main server, add dependencies, write integration tests, and document configuration.

**Architecture:** Merge HTTP server into ios_server.py startup, share WebSocket clients with PermissionHandler, handle permission_response messages.

**Tech Stack:** Python/asyncio/aiohttp, Bash

**Prerequisites:** Parts 1-3 complete (all models, handlers, UI components exist)

---

## Task 8: Integrate HTTP Server into Main Server

**Files:**
- Modify: `voice_server/ios_server.py`

### Step 1: Add imports at top of ios_server.py

Add after existing imports (around line 16):

```python
from permission_handler import PermissionHandler
from http_server import start_http_server
```

### Step 2: Add permission_handler to VoiceServer.__init__()

Add after `self.vscode_controller = VSCodeController()` (around line 223):

```python
self.permission_handler = PermissionHandler()
```

### Step 3: Add permission_response handler method

Add this method to VoiceServer class (after handle_add_project):

```python
async def handle_permission_response(self, data):
    """Handle permission response from iOS"""
    request_id = data.get('request_id', '')
    decision = data.get('decision', 'deny')

    if self.permission_handler.is_request_pending(request_id):
        # Normal flow - resolve the waiting hook
        self.permission_handler.resolve_request(request_id, {
            "decision": decision,
            "input": data.get('input'),
            "selected_option": data.get('selected_option')
        })
    elif self.permission_handler.is_request_timed_out(request_id):
        # Late response - inject into terminal
        await self.inject_terminal_response(decision, data)

async def inject_terminal_response(self, decision, data):
    """Inject permission response into terminal after timeout"""
    if decision == "allow":
        text = data.get('input', 'y')
    else:
        text = 'n'

    await self.send_to_vs_code(text)
    print(f"Injected late response: {text}")
```

### Step 4: Add message routing in handle_message()

Add to handle_message() method (around line 600):

```python
elif msg_type == 'permission_response':
    await self.handle_permission_response(data)
```

### Step 5: Share clients with PermissionHandler in handle_client()

Modify handle_client() to sync client sets:

```python
async def handle_client(self, websocket, path):
    """Handle client connection"""
    self.clients.add(websocket)
    self.permission_handler.websocket_clients.add(websocket)  # ADD THIS
    print(f"Client connected. Total clients: {len(self.clients)}")
    try:
        await self.send_status(websocket, "idle", "Connected")
        await self.send_vscode_status(websocket)
        async for message in websocket:
            print(f"Received message: {message[:100]}...")
            await self.handle_message(websocket, message)
    except Exception as e:
        print(f"Client error: {e}")
    finally:
        self.clients.discard(websocket)
        self.permission_handler.websocket_clients.discard(websocket)  # ADD THIS
        print(f"Client disconnected. Total clients: {len(self.clients)}")
```

### Step 6: Start HTTP server in start()

Modify start() method to launch HTTP server:

```python
async def start(self):
    """Start WebSocket and HTTP servers"""
    self.loop = asyncio.get_running_loop()

    # Try to connect to VSCode extension
    connected = await self.vscode_controller.connect()
    if connected:
        print("✅ Connected to VSCode extension")
    else:
        print("⚠️ VSCode extension not available, using AppleScript fallback")

    self.transcript_path = self.find_transcript_path()

    if self.transcript_path:
        self.transcript_handler = TranscriptHandler(
            self.handle_content_response,
            self.handle_claude_response,
            self.loop,
            self
        )
        self.observer = Observer()
        self.observer.schedule(self.transcript_handler, os.path.dirname(self.transcript_path))
        self.observer.start()

    # Start HTTP server for permission hooks
    http_runner = await start_http_server(self.permission_handler)

    import socket
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.connect(("8.8.8.8", 80))
    local_ip = s.getsockname()[0]
    s.close()

    print(f"WebSocket server running on ws://{local_ip}:{PORT}")

    async with websockets.serve(self.handle_client, "0.0.0.0", PORT):
        await asyncio.Future()
```

### Step 7: Run existing tests to verify no regressions

```bash
cd voice_server/tests && ./run_tests.sh
```
Expected: All tests pass

### Step 8: Commit

```bash
git add voice_server/ios_server.py
git commit -m "feat: integrate HTTP server and permission handling"
```

---

## Task 9: Add aiohttp Dependency

**Files:**
- Modify: `voice_server/requirements.txt` (create if needed)

### Step 1: Add aiohttp to requirements

```bash
echo "aiohttp>=3.9.0" >> voice_server/requirements.txt
```

### Step 2: Install the dependency

```bash
pip install aiohttp
```

### Step 3: Verify installation

```bash
python -c "import aiohttp; print(f'aiohttp {aiohttp.__version__}')"
```
Expected: aiohttp 3.9.x or higher

### Step 4: Commit

```bash
git add voice_server/requirements.txt
git commit -m "feat: add aiohttp dependency for HTTP server"
```

---

## Task 10: Integration Tests

**Files:**
- Create: `voice_server/tests/test_permission_integration.py`

### Step 1: Write integration tests

```python
# voice_server/tests/test_permission_integration.py
"""Integration tests for permission flow"""

import pytest
import asyncio
import json
from unittest.mock import AsyncMock
import sys
import os

sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), '..')))

from permission_handler import PermissionHandler
from http_server import create_http_app
from aiohttp.test_utils import AioHTTPTestCase, unittest_run_loop


class TestPermissionIntegration(AioHTTPTestCase):
    """End-to-end integration tests"""

    async def get_application(self):
        self.permission_handler = PermissionHandler()
        return create_http_app(self.permission_handler)

    @unittest_run_loop
    async def test_full_permission_flow_allow(self):
        """Test complete flow: hook -> server -> iOS -> response"""
        mock_ios = AsyncMock()
        self.permission_handler.websocket_clients.add(mock_ios)

        async def ios_responds():
            await asyncio.sleep(0.05)
            broadcast_call = mock_ios.send.call_args[0][0]
            data = json.loads(broadcast_call)
            request_id = data["request_id"]

            self.permission_handler.resolve_request(request_id, {
                "decision": "allow"
            })

        asyncio.create_task(ios_responds())

        resp = await self.client.post("/permission", json={
            "tool_name": "Bash",
            "tool_input": {"command": "npm test"}
        })

        assert resp.status == 200
        result = await resp.json()
        assert result["decision"] == "allow"

    @unittest_run_loop
    async def test_full_permission_flow_deny(self):
        """Test complete flow with deny response"""
        mock_ios = AsyncMock()
        self.permission_handler.websocket_clients.add(mock_ios)

        async def ios_denies():
            await asyncio.sleep(0.05)
            broadcast_call = mock_ios.send.call_args[0][0]
            data = json.loads(broadcast_call)
            self.permission_handler.resolve_request(data["request_id"], {
                "decision": "deny"
            })

        asyncio.create_task(ios_denies())

        resp = await self.client.post("/permission", json={
            "tool_name": "Bash",
            "tool_input": {"command": "rm -rf /"}
        })

        assert resp.status == 200
        result = await resp.json()
        assert result["decision"] == "deny"

    @unittest_run_loop
    async def test_question_with_text_input(self):
        """Test AskUserQuestion flow with text input"""
        mock_ios = AsyncMock()
        self.permission_handler.websocket_clients.add(mock_ios)

        async def ios_answers():
            await asyncio.sleep(0.05)
            broadcast_call = mock_ios.send.call_args[0][0]
            data = json.loads(broadcast_call)
            self.permission_handler.resolve_request(data["request_id"], {
                "decision": "allow",
                "input": "calculateTotal"
            })

        asyncio.create_task(ios_answers())

        resp = await self.client.post("/permission", json={
            "tool_name": "AskUserQuestion",
            "question": {"text": "What should the function be named?"}
        })

        assert resp.status == 200
        result = await resp.json()
        assert result["decision"] == "allow"
        assert result["input"] == "calculateTotal"

    @unittest_run_loop
    async def test_question_with_option_selection(self):
        """Test AskUserQuestion flow with option selection"""
        mock_ios = AsyncMock()
        self.permission_handler.websocket_clients.add(mock_ios)

        async def ios_selects():
            await asyncio.sleep(0.05)
            broadcast_call = mock_ios.send.call_args[0][0]
            data = json.loads(broadcast_call)
            self.permission_handler.resolve_request(data["request_id"], {
                "decision": "allow",
                "selected_option": 1
            })

        asyncio.create_task(ios_selects())

        resp = await self.client.post("/permission", json={
            "tool_name": "AskUserQuestion",
            "question": {
                "text": "Which database?",
                "options": ["PostgreSQL", "SQLite", "MongoDB"]
            }
        })

        assert resp.status == 200
        result = await resp.json()
        assert result["decision"] == "allow"
        assert result["selected_option"] == 1

    @unittest_run_loop
    async def test_timeout_returns_ask_behavior(self):
        """Test timeout returns fallback behavior"""
        resp = await self.client.post("/permission?timeout=0.1", json={
            "tool_name": "Bash",
            "tool_input": {"command": "npm install"}
        })

        assert resp.status == 200
        result = await resp.json()
        assert result["behavior"] == "ask"

    @unittest_run_loop
    async def test_edit_permission_with_context(self):
        """Test Edit permission includes context in broadcast"""
        mock_ios = AsyncMock()
        self.permission_handler.websocket_clients.add(mock_ios)

        async def ios_approves():
            await asyncio.sleep(0.05)
            broadcast_call = mock_ios.send.call_args[0][0]
            data = json.loads(broadcast_call)

            # Verify context was included
            assert data["prompt_type"] == "edit"
            assert data["context"]["file_path"] == "/src/file.ts"

            self.permission_handler.resolve_request(data["request_id"], {
                "decision": "allow"
            })

        asyncio.create_task(ios_approves())

        resp = await self.client.post("/permission", json={
            "tool_name": "Edit",
            "context": {
                "file_path": "/src/file.ts",
                "old_content": "const x = 1;",
                "new_content": "const x = 2;"
            }
        })

        assert resp.status == 200
        result = await resp.json()
        assert result["decision"] == "allow"
```

### Step 2: Run integration tests

```bash
cd voice_server/tests && python -m pytest test_permission_integration.py -v
```
Expected: All 6 tests pass

### Step 3: Commit

```bash
git add voice_server/tests/test_permission_integration.py
git commit -m "test: add permission flow integration tests"
```

---

## Task 11: Documentation

**Files:**
- Modify: `CLAUDE.md`

### Step 1: Add hook configuration section to CLAUDE.md

Add after the "Commands" section:

```markdown
## Permission Hooks Configuration

To enable remote permission control from the iOS app, add hooks to your Claude Code settings.

**Location:** `~/.claude/settings.json` or project `.claude/settings.json`

```json
{
  "hooks": {
    "PermissionRequest": [
      {
        "command": "/path/to/max/voice_server/hooks/permission_hook.sh",
        "timeout": 185000
      }
    ],
    "PostToolUse": [
      {
        "command": "/path/to/max/voice_server/hooks/post_tool_hook.sh"
      }
    ]
  }
}
```

**Environment Variables:**
- `VOICE_SERVER_URL`: Override server URL (default: `http://localhost:8766`)

**Ports Used:**
- WebSocket: 8765 (iOS app connection)
- HTTP: 8766 (Hook requests from Claude Code)

**How It Works:**
1. Claude Code triggers PermissionRequest hook before showing a prompt
2. Hook POSTs to voice server, which forwards to iOS app via WebSocket
3. User approves/denies on iOS, response flows back to hook
4. Hook outputs decision JSON, Claude Code proceeds accordingly
5. If timeout (3 min), falls back to terminal prompt with late-response injection
```

### Step 2: Commit

```bash
git add CLAUDE.md
git commit -m "docs: add permission hooks configuration"
```

---

## Part 4 Complete

**Tasks Completed:** 4
**Files Created/Modified:** 4

---

## Implementation Summary

### All Parts Complete

| Part | Tasks | Description |
|------|-------|-------------|
| 1 | 1-3 | iOS models, PermissionHandler, HTTP endpoints |
| 2 | 4-5 | Hook scripts, WebSocketManager integration |
| 3 | 6-7 | DiffView, PermissionPromptView |
| 4 | 8-11 | Server integration, dependencies, tests, docs |

### Total Files Created/Modified

**Created (12):**
- `ios-voice-app/.../Models/PermissionRequest.swift`
- `ios-voice-app/.../Views/DiffView.swift`
- `ios-voice-app/.../Views/PermissionPromptView.swift`
- `ios-voice-app/.../ClaudeVoiceTests/PermissionRequestTests.swift`
- `ios-voice-app/.../ClaudeVoiceTests/DiffViewTests.swift`
- `voice_server/permission_handler.py`
- `voice_server/http_server.py`
- `voice_server/hooks/permission_hook.sh`
- `voice_server/hooks/post_tool_hook.sh`
- `voice_server/tests/test_permission_handler.py`
- `voice_server/tests/test_http_server.py`
- `voice_server/tests/test_permission_integration.py`
- `voice_server/tests/test_hooks.py`

**Modified (4):**
- `ios-voice-app/.../Services/WebSocketManager.swift`
- `ios-voice-app/.../Views/SessionView.swift`
- `voice_server/ios_server.py`
- `CLAUDE.md`

### Test Coverage

- iOS: PermissionRequest models, DiffParser
- Server: PermissionHandler, HTTP endpoints, integration flow
- Hooks: Script existence and structure

When ready to implement, run `/execute-plan` which will:
- Create feature branch
- Execute tasks in batches with checkpoints
- Run tests after each batch
- Merge back to dev when complete
