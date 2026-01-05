# Remote Permission Control - Part 1: Models & Core

> **For Claude:** REQUIRED SUB-SKILL: Use execute-plan to implement this plan task-by-task.

**Goal:** Build the foundational models and core permission handler for remote permission control.

**Architecture:** iOS models for decoding permission requests, Python handler for async request/response management with Event-based blocking.

**Tech Stack:** Swift/Codable, Python/asyncio

**Prerequisites:** None - this is the starting point.

---

## Task 1: Permission Models (iOS)

**Files:**
- Create: `ios-voice-app/ClaudeVoice/ClaudeVoice/Models/PermissionRequest.swift`
- Test: `ios-voice-app/ClaudeVoice/ClaudeVoiceTests/PermissionRequestTests.swift`

### Step 1: Write the failing test

```swift
// ios-voice-app/ClaudeVoice/ClaudeVoiceTests/PermissionRequestTests.swift
import XCTest
@testable import ClaudeVoice

final class PermissionRequestTests: XCTestCase {

    func testDecodeBashPermission() throws {
        let json = """
        {
            "type": "permission_request",
            "request_id": "uuid-123",
            "prompt_type": "bash",
            "tool_name": "Bash",
            "tool_input": {
                "command": "npm install",
                "description": "Install dependencies"
            },
            "timestamp": 1234567890
        }
        """.data(using: .utf8)!

        let request = try JSONDecoder().decode(PermissionRequest.self, from: json)

        XCTAssertEqual(request.requestId, "uuid-123")
        XCTAssertEqual(request.promptType, .bash)
        XCTAssertEqual(request.toolName, "Bash")
        XCTAssertEqual(request.toolInput?.command, "npm install")
    }

    func testDecodeEditPermission() throws {
        let json = """
        {
            "type": "permission_request",
            "request_id": "uuid-456",
            "prompt_type": "edit",
            "tool_name": "Edit",
            "tool_input": {},
            "context": {
                "file_path": "/path/to/file.ts",
                "old_content": "const foo = 1;",
                "new_content": "const foo = 2;"
            },
            "timestamp": 1234567890
        }
        """.data(using: .utf8)!

        let request = try JSONDecoder().decode(PermissionRequest.self, from: json)

        XCTAssertEqual(request.promptType, .edit)
        XCTAssertEqual(request.context?.filePath, "/path/to/file.ts")
        XCTAssertEqual(request.context?.oldContent, "const foo = 1;")
        XCTAssertEqual(request.context?.newContent, "const foo = 2;")
    }

    func testDecodeQuestionPermission() throws {
        let json = """
        {
            "type": "permission_request",
            "request_id": "uuid-789",
            "prompt_type": "question",
            "tool_name": "AskUserQuestion",
            "tool_input": {},
            "question": {
                "text": "Which database?",
                "options": ["PostgreSQL", "SQLite", "MongoDB"]
            },
            "timestamp": 1234567890
        }
        """.data(using: .utf8)!

        let request = try JSONDecoder().decode(PermissionRequest.self, from: json)

        XCTAssertEqual(request.promptType, .question)
        XCTAssertEqual(request.question?.text, "Which database?")
        XCTAssertEqual(request.question?.options, ["PostgreSQL", "SQLite", "MongoDB"])
    }

    func testEncodePermissionResponse() throws {
        let response = PermissionResponse(
            requestId: "uuid-123",
            decision: .allow,
            input: nil,
            selectedOption: nil
        )

        let data = try JSONEncoder().encode(response)
        let dict = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        XCTAssertEqual(dict["type"] as? String, "permission_response")
        XCTAssertEqual(dict["request_id"] as? String, "uuid-123")
        XCTAssertEqual(dict["decision"] as? String, "allow")
    }

    func testEncodeQuestionResponse() throws {
        let response = PermissionResponse(
            requestId: "uuid-789",
            decision: .allow,
            input: "calculateTotal",
            selectedOption: nil
        )

        let data = try JSONEncoder().encode(response)
        let dict = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        XCTAssertEqual(dict["input"] as? String, "calculateTotal")
    }
}
```

### Step 2: Run test to verify it fails

```bash
cd ios-voice-app/ClaudeVoice && xcodebuild test \
  -scheme ClaudeVoice \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  -only-testing:ClaudeVoiceTests/PermissionRequestTests 2>&1 | tail -20
```
Expected: FAIL with "cannot find type 'PermissionRequest' in scope"

### Step 3: Write minimal implementation

```swift
// ios-voice-app/ClaudeVoice/ClaudeVoice/Models/PermissionRequest.swift
import Foundation

enum PermissionPromptType: String, Codable {
    case bash
    case write
    case edit
    case question
    case task
}

enum PermissionDecision: String, Codable {
    case allow
    case deny
}

struct ToolInput: Codable {
    let command: String?
    let description: String?

    init(command: String? = nil, description: String? = nil) {
        self.command = command
        self.description = description
    }
}

struct PermissionContext: Codable {
    let filePath: String?
    let oldContent: String?
    let newContent: String?

    enum CodingKeys: String, CodingKey {
        case filePath = "file_path"
        case oldContent = "old_content"
        case newContent = "new_content"
    }
}

struct PermissionQuestion: Codable {
    let text: String
    let options: [String]?
}

struct PermissionRequest: Codable, Identifiable {
    let type: String
    let requestId: String
    let promptType: PermissionPromptType
    let toolName: String
    let toolInput: ToolInput?
    let context: PermissionContext?
    let question: PermissionQuestion?
    let timestamp: Double

    var id: String { requestId }

    enum CodingKeys: String, CodingKey {
        case type
        case requestId = "request_id"
        case promptType = "prompt_type"
        case toolName = "tool_name"
        case toolInput = "tool_input"
        case context
        case question
        case timestamp
    }
}

struct PermissionResponse: Codable {
    let type: String
    let requestId: String
    let decision: PermissionDecision
    let input: String?
    let selectedOption: Int?
    let timestamp: Double

    init(requestId: String, decision: PermissionDecision, input: String? = nil, selectedOption: Int? = nil) {
        self.type = "permission_response"
        self.requestId = requestId
        self.decision = decision
        self.input = input
        self.selectedOption = selectedOption
        self.timestamp = Date().timeIntervalSince1970
    }

    enum CodingKeys: String, CodingKey {
        case type
        case requestId = "request_id"
        case decision
        case input
        case selectedOption = "selected_option"
        case timestamp
    }
}

struct PermissionResolved: Codable {
    let type: String
    let requestId: String
    let answeredIn: String

    enum CodingKeys: String, CodingKey {
        case type
        case requestId = "request_id"
        case answeredIn = "answered_in"
    }
}
```

### Step 4: Run test to verify it passes

```bash
cd ios-voice-app/ClaudeVoice && xcodebuild test \
  -scheme ClaudeVoice \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  -only-testing:ClaudeVoiceTests/PermissionRequestTests 2>&1 | tail -20
```
Expected: PASS

### Step 5: Commit

```bash
git add ios-voice-app/ClaudeVoice/ClaudeVoice/Models/PermissionRequest.swift \
        ios-voice-app/ClaudeVoice/ClaudeVoiceTests/PermissionRequestTests.swift
git commit -m "feat: add PermissionRequest models for iOS"
```

---

## Task 2: Server Permission Handler Module

**Files:**
- Create: `voice_server/permission_handler.py`
- Test: `voice_server/tests/test_permission_handler.py`

### Step 1: Write the failing test

```python
# voice_server/tests/test_permission_handler.py
"""Tests for permission_handler.py"""

import pytest
import asyncio
import json
from unittest.mock import Mock, AsyncMock

import sys
import os
sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), '..')))

from permission_handler import PermissionHandler


class TestPermissionHandler:
    """Tests for PermissionHandler class"""

    def test_initialization(self):
        """Test handler initializes with empty state"""
        handler = PermissionHandler()
        assert handler.pending_permissions == {}
        assert handler.permission_responses == {}
        assert handler.websocket_clients == set()

    @pytest.mark.asyncio
    async def test_register_request_creates_event(self):
        """Test registering a permission request creates an asyncio Event"""
        handler = PermissionHandler()
        request_id = "test-uuid-123"

        event = handler.register_request(request_id)

        assert request_id in handler.pending_permissions
        assert isinstance(event, asyncio.Event)
        assert not event.is_set()

    @pytest.mark.asyncio
    async def test_resolve_request_sets_event(self):
        """Test resolving a request sets the event and stores response"""
        handler = PermissionHandler()
        request_id = "test-uuid-123"

        event = handler.register_request(request_id)
        decision = {"decision": "allow"}

        handler.resolve_request(request_id, decision)

        assert event.is_set()
        assert handler.permission_responses[request_id] == decision

    @pytest.mark.asyncio
    async def test_wait_for_response_returns_decision(self):
        """Test waiting for response returns the decision"""
        handler = PermissionHandler()
        request_id = "test-uuid-123"

        event = handler.register_request(request_id)

        async def respond_later():
            await asyncio.sleep(0.1)
            handler.resolve_request(request_id, {"decision": "allow"})

        asyncio.create_task(respond_later())

        result = await handler.wait_for_response(request_id, timeout=1.0)

        assert result == {"decision": "allow"}

    @pytest.mark.asyncio
    async def test_wait_for_response_timeout(self):
        """Test timeout returns None"""
        handler = PermissionHandler()
        request_id = "test-uuid-123"

        handler.register_request(request_id)

        result = await handler.wait_for_response(request_id, timeout=0.1)

        assert result is None

    @pytest.mark.asyncio
    async def test_is_request_pending(self):
        """Test checking if request is still pending"""
        handler = PermissionHandler()
        request_id = "test-uuid-123"

        handler.register_request(request_id)
        assert handler.is_request_pending(request_id)

        handler.resolve_request(request_id, {"decision": "allow"})
        assert not handler.is_request_pending(request_id)

    @pytest.mark.asyncio
    async def test_cleanup_request(self):
        """Test cleaning up request removes all state"""
        handler = PermissionHandler()
        request_id = "test-uuid-123"

        handler.register_request(request_id)
        handler.resolve_request(request_id, {"decision": "allow"})

        handler.cleanup_request(request_id)

        assert request_id not in handler.pending_permissions
        assert request_id not in handler.permission_responses

    @pytest.mark.asyncio
    async def test_broadcast_to_clients(self):
        """Test broadcasting message to all WebSocket clients"""
        handler = PermissionHandler()

        client1 = AsyncMock()
        client2 = AsyncMock()
        handler.websocket_clients = {client1, client2}

        message = {"type": "permission_request", "request_id": "123"}
        await handler.broadcast(message)

        client1.send.assert_called_once()
        client2.send.assert_called_once()

        sent_data = json.loads(client1.send.call_args[0][0])
        assert sent_data["type"] == "permission_request"
```

### Step 2: Run test to verify it fails

```bash
cd voice_server/tests && python -m pytest test_permission_handler.py -v 2>&1 | tail -20
```
Expected: FAIL with "ModuleNotFoundError: No module named 'permission_handler'"

### Step 3: Write minimal implementation

```python
# voice_server/permission_handler.py
"""Permission request handler for Claude Code hooks"""

import asyncio
import json
from typing import Optional
import uuid


class PermissionHandler:
    """Manages permission requests from Claude Code hooks"""

    def __init__(self):
        self.pending_permissions: dict[str, asyncio.Event] = {}
        self.permission_responses: dict[str, dict] = {}
        self.websocket_clients: set = set()
        self.timed_out_requests: set[str] = set()

    def register_request(self, request_id: str) -> asyncio.Event:
        """Register a new permission request and return an Event to wait on"""
        event = asyncio.Event()
        self.pending_permissions[request_id] = event
        return event

    def resolve_request(self, request_id: str, decision: dict) -> bool:
        """Resolve a pending permission request with a decision"""
        if request_id in self.pending_permissions:
            self.permission_responses[request_id] = decision
            self.pending_permissions[request_id].set()
            return True
        return False

    def is_request_pending(self, request_id: str) -> bool:
        """Check if a request is still pending (event not set)"""
        if request_id not in self.pending_permissions:
            return False
        return not self.pending_permissions[request_id].is_set()

    def is_request_timed_out(self, request_id: str) -> bool:
        """Check if a request timed out (terminal fallback active)"""
        return request_id in self.timed_out_requests

    def mark_timed_out(self, request_id: str):
        """Mark a request as timed out (fell back to terminal)"""
        self.timed_out_requests.add(request_id)
        if request_id in self.pending_permissions:
            del self.pending_permissions[request_id]

    async def wait_for_response(
        self, request_id: str, timeout: float = 180.0
    ) -> Optional[dict]:
        """Wait for a response to a permission request"""
        if request_id not in self.pending_permissions:
            return None

        event = self.pending_permissions[request_id]

        try:
            await asyncio.wait_for(event.wait(), timeout=timeout)
            return self.permission_responses.get(request_id)
        except asyncio.TimeoutError:
            self.mark_timed_out(request_id)
            return None

    def cleanup_request(self, request_id: str):
        """Clean up all state for a request"""
        self.pending_permissions.pop(request_id, None)
        self.permission_responses.pop(request_id, None)
        self.timed_out_requests.discard(request_id)

    async def broadcast(self, message: dict):
        """Broadcast a message to all connected WebSocket clients"""
        json_message = json.dumps(message)
        for client in list(self.websocket_clients):
            try:
                await client.send(json_message)
            except Exception as e:
                print(f"Error broadcasting to client: {e}")
                self.websocket_clients.discard(client)

    def generate_request_id(self) -> str:
        """Generate a unique request ID"""
        return str(uuid.uuid4())
```

### Step 4: Run test to verify it passes

```bash
cd voice_server/tests && python -m pytest test_permission_handler.py -v
```
Expected: PASS (all 8 tests)

### Step 5: Commit

```bash
git add voice_server/permission_handler.py voice_server/tests/test_permission_handler.py
git commit -m "feat: add PermissionHandler for managing hook requests"
```

---

## Task 3: HTTP Endpoints for Permission Hooks

**Files:**
- Create: `voice_server/http_server.py`
- Test: `voice_server/tests/test_http_server.py`

### Step 1: Write the failing test

```python
# voice_server/tests/test_http_server.py
"""Tests for HTTP server endpoints"""

import pytest
import json
from aiohttp import web
from aiohttp.test_utils import AioHTTPTestCase, unittest_run_loop
import sys
import os

sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), '..')))

from http_server import create_http_app
from permission_handler import PermissionHandler


class TestHTTPServer(AioHTTPTestCase):
    """Tests for HTTP permission endpoints"""

    async def get_application(self):
        self.permission_handler = PermissionHandler()
        return create_http_app(self.permission_handler)

    @unittest_run_loop
    async def test_permission_endpoint_sends_to_websocket(self):
        """Test POST /permission forwards to WebSocket clients"""
        from unittest.mock import AsyncMock

        mock_client = AsyncMock()
        self.permission_handler.websocket_clients.add(mock_client)

        async def respond():
            import asyncio
            await asyncio.sleep(0.1)
            call_args = mock_client.send.call_args[0][0]
            data = json.loads(call_args)
            self.permission_handler.resolve_request(
                data["request_id"],
                {"decision": "allow"}
            )

        import asyncio
        asyncio.create_task(respond())

        payload = {
            "tool_name": "Bash",
            "tool_input": {"command": "npm install"}
        }

        resp = await self.client.post("/permission", json=payload)

        assert resp.status == 200
        data = await resp.json()
        assert data["decision"] == "allow"

    @unittest_run_loop
    async def test_permission_endpoint_timeout(self):
        """Test POST /permission returns ask behavior on timeout"""
        payload = {
            "tool_name": "Bash",
            "tool_input": {"command": "npm install"}
        }

        resp = await self.client.post("/permission?timeout=0.1", json=payload)

        assert resp.status == 200
        data = await resp.json()
        assert data["behavior"] == "ask"

    @unittest_run_loop
    async def test_permission_resolved_endpoint(self):
        """Test POST /permission_resolved notifies iOS"""
        from unittest.mock import AsyncMock

        mock_client = AsyncMock()
        self.permission_handler.websocket_clients.add(mock_client)

        request_id = "test-123"
        self.permission_handler.timed_out_requests.add(request_id)

        resp = await self.client.post(
            "/permission_resolved",
            json={"request_id": request_id}
        )

        assert resp.status == 200

        mock_client.send.assert_called_once()
        sent_data = json.loads(mock_client.send.call_args[0][0])
        assert sent_data["type"] == "permission_resolved"

    @unittest_run_loop
    async def test_health_endpoint(self):
        """Test GET /health returns ok"""
        resp = await self.client.get("/health")

        assert resp.status == 200
        data = await resp.json()
        assert data["status"] == "ok"
```

### Step 2: Run test to verify it fails

```bash
cd voice_server/tests && python -m pytest test_http_server.py -v 2>&1 | tail -20
```
Expected: FAIL with "ModuleNotFoundError: No module named 'http_server'"

### Step 3: Write minimal implementation

```python
# voice_server/http_server.py
"""HTTP server for Claude Code permission hooks"""

import json
from aiohttp import web
from permission_handler import PermissionHandler

HTTP_PORT = 8766


def create_http_app(permission_handler: PermissionHandler) -> web.Application:
    """Create the aiohttp application with permission endpoints"""

    async def handle_permission(request: web.Request) -> web.Response:
        """Handle POST /permission from PermissionRequest hook"""
        try:
            payload = await request.json()
        except json.JSONDecodeError:
            return web.json_response({"error": "Invalid JSON"}, status=400)

        timeout = float(request.query.get("timeout", "180"))

        request_id = permission_handler.generate_request_id()
        permission_handler.register_request(request_id)

        tool_name = payload.get("tool_name", "")
        prompt_type_map = {
            "Bash": "bash",
            "Write": "write",
            "Edit": "edit",
            "AskUserQuestion": "question",
            "Task": "task",
        }
        prompt_type = prompt_type_map.get(tool_name, "bash")

        ios_message = {
            "type": "permission_request",
            "request_id": request_id,
            "prompt_type": prompt_type,
            "tool_name": tool_name,
            "tool_input": payload.get("tool_input", {}),
            "context": payload.get("context"),
            "question": payload.get("question"),
            "timestamp": payload.get("timestamp", 0),
        }

        await permission_handler.broadcast(ios_message)

        response = await permission_handler.wait_for_response(request_id, timeout=timeout)

        if response is None:
            return web.json_response({"behavior": "ask"})

        permission_handler.cleanup_request(request_id)
        return web.json_response(response)

    async def handle_permission_resolved(request: web.Request) -> web.Response:
        """Handle POST /permission_resolved from PostToolUse hook"""
        try:
            payload = await request.json()
        except json.JSONDecodeError:
            return web.json_response({"error": "Invalid JSON"}, status=400)

        request_id = payload.get("request_id", "")

        await permission_handler.broadcast({
            "type": "permission_resolved",
            "request_id": request_id,
            "answered_in": "terminal"
        })

        permission_handler.cleanup_request(request_id)

        return web.json_response({"status": "ok"})

    async def handle_health(request: web.Request) -> web.Response:
        """Health check endpoint"""
        return web.json_response({"status": "ok"})

    app = web.Application()
    app.router.add_post("/permission", handle_permission)
    app.router.add_post("/permission_resolved", handle_permission_resolved)
    app.router.add_get("/health", handle_health)

    return app


async def start_http_server(
    permission_handler: PermissionHandler,
    port: int = HTTP_PORT
) -> web.AppRunner:
    """Start the HTTP server"""
    app = create_http_app(permission_handler)
    runner = web.AppRunner(app)
    await runner.setup()
    site = web.TCPSite(runner, "0.0.0.0", port)
    await site.start()
    print(f"HTTP server running on http://0.0.0.0:{port}")
    return runner
```

### Step 4: Run test to verify it passes

```bash
cd voice_server/tests && python -m pytest test_http_server.py -v
```
Expected: PASS (all 4 tests)

### Step 5: Commit

```bash
git add voice_server/http_server.py voice_server/tests/test_http_server.py
git commit -m "feat: add HTTP endpoints for permission hooks"
```

---

## Part 1 Complete

**Tasks Completed:** 3
**Files Created:** 6

**Next:** Continue with Part 2 (Hook Scripts & WebSocket Integration)
