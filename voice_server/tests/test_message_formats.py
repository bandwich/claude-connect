# voice_server/tests/test_message_formats.py
"""
Comprehensive tests for all message formats between iOS app and server.

This ensures the WebSocket protocol contract is maintained and that
messages sent/received have the correct structure.
"""

import pytest
import json
from unittest.mock import AsyncMock, MagicMock, patch
import sys
import os

sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), '..')))


class TestServerToiOSMessageFormats:
    """Tests for messages sent FROM server TO iOS app"""

    def test_status_message_format(self):
        """Verify status message has required fields"""
        # This is the format iOS expects for StatusMessage
        message = {
            "type": "status",
            "state": "processing",
            "message": "Working on it..."
        }
        assert message["type"] == "status"
        assert message["state"] in ["idle", "processing", "speaking"]
        assert "message" in message

    def test_connection_status_message_format(self):
        """Verify connection_status message has required fields"""
        message = {
            "type": "connection_status",
            "connected": True,
            "active_session_id": "session-123"
        }
        assert message["type"] == "connection_status"
        assert isinstance(message["connected"], bool)
        # active_session_id can be None or string

    def test_audio_chunk_message_format(self):
        """Verify audio_chunk message has required fields"""
        message = {
            "type": "audio_chunk",
            "data": "base64encodedaudio==",
            "chunk_index": 0,
            "total_chunks": 3,
            "timestamp": 1704500000.0
        }
        assert message["type"] == "audio_chunk"
        assert "data" in message
        assert isinstance(message["chunk_index"], int)
        assert isinstance(message["total_chunks"], int)
        assert message["chunk_index"] < message["total_chunks"]

    def test_projects_list_message_format(self):
        """Verify projects list message has required fields"""
        message = {
            "type": "projects",
            "projects": [
                {"name": "project1", "path": "/path/to/project1", "session_count": 5},
                {"name": "project2", "path": "/path/to/project2", "session_count": 3}
            ]
        }
        assert message["type"] == "projects"
        assert isinstance(message["projects"], list)
        for project in message["projects"]:
            assert "name" in project
            assert "path" in project

    def test_sessions_list_message_format(self):
        """Verify sessions list message has required fields"""
        message = {
            "type": "sessions",
            "sessions": [
                {"id": "session-1", "preview": "Hello Claude", "timestamp": 1704500000.0},
                {"id": "session-2", "preview": "Help me code", "timestamp": 1704500100.0}
            ]
        }
        assert message["type"] == "sessions"
        assert isinstance(message["sessions"], list)
        for session in message["sessions"]:
            assert "id" in session
            assert "preview" in session

    def test_session_history_message_format(self):
        """Verify session_history message has required fields"""
        message = {
            "type": "session_history",
            "messages": [
                {"role": "user", "content": "Hello"},
                {"role": "assistant", "content": "Hi there!"}
            ]
        }
        assert message["type"] == "session_history"
        assert isinstance(message["messages"], list)
        for msg in message["messages"]:
            assert msg["role"] in ["user", "assistant"]
            assert "content" in msg

    def test_session_closed_message_format(self):
        """Verify session_closed message has required fields"""
        message = {
            "type": "session_closed",
            "success": True
        }
        assert message["type"] == "session_closed"
        assert isinstance(message["success"], bool)

    def test_session_created_message_format(self):
        """Verify session_created message has required fields"""
        message = {
            "type": "session_created",
            "success": True,
            "session_id": "new-session-123"
        }
        assert message["type"] == "session_created"
        assert isinstance(message["success"], bool)
        # session_id present on success

    def test_session_resumed_message_format(self):
        """Verify session_resumed message has required fields"""
        message = {
            "type": "session_resumed",
            "success": True,
            "session_id": "resumed-session-123"
        }
        assert message["type"] == "session_resumed"
        assert isinstance(message["success"], bool)

    def test_project_created_message_format(self):
        """Verify project_created message has required fields"""
        message = {
            "type": "project_created",
            "success": True,
            "path": "/path/to/new/project",
            "name": "my-project"
        }
        assert message["type"] == "project_created"
        assert isinstance(message["success"], bool)
        assert "path" in message
        assert "name" in message

    def test_permission_request_message_format(self):
        """Verify permission_request message has required fields"""
        message = {
            "type": "permission_request",
            "request_id": "uuid-123-456",
            "prompt_type": "bash",
            "tool_name": "Bash",
            "tool_input": {"command": "npm install"},
            "context": None,
            "question": None,
            "timestamp": 1704500000.0
        }
        assert message["type"] == "permission_request"
        assert "request_id" in message
        assert len(message["request_id"]) > 0
        assert message["prompt_type"] in ["bash", "write", "edit", "question", "task"]
        assert "tool_name" in message
        assert "timestamp" in message

    def test_permission_request_includes_suggestions(self):
        """Verify permission_request message includes permission_suggestions when present"""
        message = {
            "type": "permission_request",
            "request_id": "uuid-123-456",
            "prompt_type": "bash",
            "tool_name": "Bash",
            "tool_input": {"command": "npm install"},
            "context": None,
            "question": None,
            "timestamp": 1704500000.0,
            "permission_suggestions": [
                {
                    "type": "addRules",
                    "rules": [{"toolName": "Bash", "ruleContent": "npm install:*"}],
                    "behavior": "allow",
                    "destination": "localSettings"
                }
            ]
        }
        assert "permission_suggestions" in message
        assert len(message["permission_suggestions"]) == 1
        assert message["permission_suggestions"][0]["type"] == "addRules"

    def test_permission_resolved_message_format(self):
        """Verify permission_resolved message has required fields"""
        message = {
            "type": "permission_resolved",
            "request_id": "uuid-123-456",
            "answered_in": "terminal"
        }
        assert message["type"] == "permission_resolved"
        assert "request_id" in message
        assert message["answered_in"] in ["terminal", "ios"]

    def test_error_message_format(self):
        """Verify error message has required fields"""
        message = {
            "type": "error",
            "message": "Invalid request"
        }
        assert message["type"] == "error"
        assert "message" in message


class TestiOSToServerMessageFormats:
    """Tests for messages sent FROM iOS app TO server"""

    def test_voice_input_message_format(self):
        """Verify voice_input message has required fields"""
        message = {
            "type": "voice_input",
            "text": "Hello Claude, help me with code",
            "timestamp": 1704500000.0
        }
        assert message["type"] == "voice_input"
        assert "text" in message
        assert len(message["text"]) > 0

    def test_list_projects_message_format(self):
        """Verify list_projects message format"""
        message = {"type": "list_projects"}
        assert message["type"] == "list_projects"

    def test_list_sessions_message_format(self):
        """Verify list_sessions message has required fields"""
        message = {
            "type": "list_sessions",
            "folder_name": "my-project"
        }
        assert message["type"] == "list_sessions"
        assert "folder_name" in message

    def test_get_session_message_format(self):
        """Verify get_session message has required fields"""
        message = {
            "type": "get_session",
            "folder_name": "my-project",
            "session_id": "session-123"
        }
        assert message["type"] == "get_session"
        assert "folder_name" in message
        assert "session_id" in message

    def test_close_session_message_format(self):
        """Verify close_session message format"""
        message = {"type": "close_session"}
        assert message["type"] == "close_session"

    def test_new_session_message_format(self):
        """Verify new_session message has required fields"""
        message = {
            "type": "new_session",
            "project_path": "/path/to/project"
        }
        assert message["type"] == "new_session"
        assert "project_path" in message

    def test_resume_session_message_format(self):
        """Verify resume_session message has required fields"""
        message = {
            "type": "resume_session",
            "session_id": "session-123"
        }
        assert message["type"] == "resume_session"
        assert "session_id" in message

    def test_add_project_message_format(self):
        """Verify add_project message has required fields"""
        message = {
            "type": "add_project",
            "name": "new-project"
        }
        assert message["type"] == "add_project"
        assert "name" in message

    def test_permission_response_message_format(self):
        """Verify permission_response message has required fields"""
        message = {
            "type": "permission_response",
            "request_id": "uuid-123-456",
            "decision": "allow",
            "input": None,
            "selected_option": None,
            "timestamp": 1704500000.0
        }
        assert message["type"] == "permission_response"
        assert "request_id" in message
        assert message["decision"] in ["allow", "deny"]

    def test_permission_response_with_updated_permissions(self):
        """Verify permission_response can include updatedPermissions"""
        message = {
            "type": "permission_response",
            "request_id": "uuid-123-456",
            "decision": "allow",
            "input": None,
            "selected_option": None,
            "updated_permissions": [
                {
                    "type": "addRules",
                    "rules": [{"toolName": "Bash", "ruleContent": "npm install:*"}],
                    "behavior": "allow",
                    "destination": "localSettings"
                }
            ],
            "timestamp": 1704500000.0
        }
        assert message["decision"] == "allow"
        assert "updated_permissions" in message


class TestHTTPHookResponseFormats:
    """Tests for HTTP responses to Claude Code hooks"""

    def test_permission_allow_response_format(self):
        """Verify allow response has correct Claude Code hook format"""
        # This is what the HTTP /permission endpoint should return
        response = {
            "hookSpecificOutput": {
                "hookEventName": "PermissionRequest",
                "decision": {
                    "behavior": "allow"
                }
            }
        }
        assert "hookSpecificOutput" in response
        assert response["hookSpecificOutput"]["hookEventName"] == "PermissionRequest"
        assert response["hookSpecificOutput"]["decision"]["behavior"] == "allow"

    def test_permission_deny_response_format(self):
        """Verify deny response has correct Claude Code hook format"""
        response = {
            "hookSpecificOutput": {
                "hookEventName": "PermissionRequest",
                "decision": {
                    "behavior": "deny"
                }
            }
        }
        assert "hookSpecificOutput" in response
        assert response["hookSpecificOutput"]["hookEventName"] == "PermissionRequest"
        assert response["hookSpecificOutput"]["decision"]["behavior"] == "deny"

    def test_permission_allow_with_updated_permissions_response_format(self):
        """Verify allow response can include updatedPermissions for 'always allow'"""
        response = {
            "hookSpecificOutput": {
                "hookEventName": "PermissionRequest",
                "decision": {
                    "behavior": "allow",
                    "updatedPermissions": [
                        {
                            "type": "addRules",
                            "rules": [{"toolName": "Bash", "ruleContent": "npm install:*"}],
                            "behavior": "allow",
                            "destination": "localSettings"
                        }
                    ]
                }
            }
        }
        assert response["hookSpecificOutput"]["decision"]["behavior"] == "allow"
        assert "updatedPermissions" in response["hookSpecificOutput"]["decision"]

    def test_permission_timeout_response_format(self):
        """Verify timeout response falls back to terminal"""
        response = {"behavior": "ask"}
        assert response["behavior"] == "ask"


class TestHTTPServerActualResponses:
    """Integration tests for actual HTTP server responses"""

    @pytest.fixture
    def permission_handler(self):
        from permission_handler import PermissionHandler
        return PermissionHandler()

    @pytest.fixture
    def http_app(self, permission_handler):
        from http_server import create_http_app
        return create_http_app(permission_handler)

    @pytest.mark.asyncio
    async def test_permission_endpoint_returns_hook_format_on_allow(self, http_app, permission_handler):
        """Test /permission returns correct hook format when iOS allows"""
        from aiohttp.test_utils import TestClient, TestServer
        import asyncio

        mock_client = AsyncMock()
        permission_handler.websocket_clients.add(mock_client)

        async def respond_allow():
            await asyncio.sleep(0.1)
            call_args = mock_client.send.call_args[0][0]
            data = json.loads(call_args)
            permission_handler.resolve_request(data["request_id"], {"decision": "allow"})

        async with TestClient(TestServer(http_app)) as client:
            asyncio.create_task(respond_allow())

            resp = await client.post("/permission?timeout=5", json={
                "tool_name": "Bash",
                "tool_input": {"command": "npm install"}
            })

            assert resp.status == 200
            data = await resp.json()

            # Verify Claude Code hook format
            assert "hookSpecificOutput" in data, f"Missing hookSpecificOutput in: {data}"
            assert data["hookSpecificOutput"]["hookEventName"] == "PermissionRequest"
            assert data["hookSpecificOutput"]["decision"]["behavior"] == "allow"

    @pytest.mark.asyncio
    async def test_permission_endpoint_returns_hook_format_on_deny(self, http_app, permission_handler):
        """Test /permission returns correct hook format when iOS denies"""
        from aiohttp.test_utils import TestClient, TestServer
        import asyncio

        mock_client = AsyncMock()
        permission_handler.websocket_clients.add(mock_client)

        async def respond_deny():
            await asyncio.sleep(0.1)
            call_args = mock_client.send.call_args[0][0]
            data = json.loads(call_args)
            permission_handler.resolve_request(data["request_id"], {"decision": "deny"})

        async with TestClient(TestServer(http_app)) as client:
            asyncio.create_task(respond_deny())

            resp = await client.post("/permission?timeout=5", json={
                "tool_name": "Bash",
                "tool_input": {"command": "rm -rf /"}
            })

            assert resp.status == 200
            data = await resp.json()

            # Verify Claude Code hook format
            assert "hookSpecificOutput" in data
            assert data["hookSpecificOutput"]["hookEventName"] == "PermissionRequest"
            assert data["hookSpecificOutput"]["decision"]["behavior"] == "deny"

    @pytest.mark.asyncio
    async def test_permission_endpoint_returns_ask_on_timeout(self, http_app, permission_handler):
        """Test /permission returns ask behavior on timeout"""
        from aiohttp.test_utils import TestClient, TestServer

        async with TestClient(TestServer(http_app)) as client:
            resp = await client.post("/permission?timeout=0.1", json={
                "tool_name": "Bash",
                "tool_input": {"command": "npm install"}
            })

            assert resp.status == 200
            data = await resp.json()

            # Timeout should return ask behavior (no hookSpecificOutput)
            assert data == {"behavior": "ask"}

    @pytest.mark.asyncio
    async def test_permission_websocket_broadcast_contains_request_id(self, http_app, permission_handler):
        """Test WebSocket broadcast includes request_id for iOS to respond with"""
        from aiohttp.test_utils import TestClient, TestServer
        import asyncio

        mock_client = AsyncMock()
        permission_handler.websocket_clients.add(mock_client)
        captured_request_id = None

        async def capture_and_respond():
            nonlocal captured_request_id
            await asyncio.sleep(0.1)
            call_args = mock_client.send.call_args[0][0]
            data = json.loads(call_args)
            captured_request_id = data.get("request_id")
            permission_handler.resolve_request(data["request_id"], {"decision": "allow"})

        async with TestClient(TestServer(http_app)) as client:
            asyncio.create_task(capture_and_respond())

            await client.post("/permission?timeout=5", json={
                "tool_name": "Bash",
                "tool_input": {"command": "npm install"}
            })

            # Verify WebSocket received message with request_id
            assert captured_request_id is not None
            assert len(captured_request_id) > 0

            # Verify full WebSocket message format
            call_args = mock_client.send.call_args[0][0]
            ws_message = json.loads(call_args)
            assert ws_message["type"] == "permission_request"
            assert ws_message["request_id"] == captured_request_id
            assert ws_message["tool_name"] == "Bash"
            assert ws_message["prompt_type"] == "bash"

    @pytest.mark.asyncio
    async def test_permission_endpoint_forwards_suggestions(self, http_app, permission_handler):
        """Test /permission forwards permission_suggestions to WebSocket broadcast"""
        from aiohttp.test_utils import TestClient, TestServer
        import asyncio

        mock_client = AsyncMock()
        permission_handler.websocket_clients.add(mock_client)
        captured_ws_message = None

        async def capture_and_respond():
            nonlocal captured_ws_message
            await asyncio.sleep(0.1)
            call_args = mock_client.send.call_args[0][0]
            captured_ws_message = json.loads(call_args)
            permission_handler.resolve_request(captured_ws_message["request_id"], {"decision": "allow"})

        async with TestClient(TestServer(http_app)) as client:
            asyncio.create_task(capture_and_respond())

            await client.post("/permission?timeout=5", json={
                "tool_name": "Bash",
                "tool_input": {"command": "npm install"},
                "permission_suggestions": [
                    {
                        "type": "addRules",
                        "rules": [{"toolName": "Bash", "ruleContent": "npm install:*"}],
                        "behavior": "allow",
                        "destination": "localSettings"
                    }
                ]
            })

            # Verify WebSocket message includes permission_suggestions
            assert captured_ws_message is not None
            assert "permission_suggestions" in captured_ws_message
            assert len(captured_ws_message["permission_suggestions"]) == 1

    @pytest.mark.asyncio
    async def test_permission_endpoint_forwards_updated_permissions(self, http_app, permission_handler):
        """Test /permission includes updatedPermissions in hook response when iOS sends them"""
        from aiohttp.test_utils import TestClient, TestServer
        import asyncio

        mock_client = AsyncMock()
        permission_handler.websocket_clients.add(mock_client)

        updated_perms = [
            {
                "type": "addRules",
                "rules": [{"toolName": "Bash", "ruleContent": "npm install:*"}],
                "behavior": "allow",
                "destination": "localSettings"
            }
        ]

        async def respond_with_perms():
            await asyncio.sleep(0.1)
            call_args = mock_client.send.call_args[0][0]
            data = json.loads(call_args)
            permission_handler.resolve_request(data["request_id"], {
                "decision": "allow",
                "updated_permissions": updated_perms
            })

        async with TestClient(TestServer(http_app)) as client:
            asyncio.create_task(respond_with_perms())

            resp = await client.post("/permission?timeout=5", json={
                "tool_name": "Bash",
                "tool_input": {"command": "npm install"}
            })

            data = await resp.json()
            decision = data["hookSpecificOutput"]["decision"]
            assert decision["behavior"] == "allow"
            assert "updatedPermissions" in decision
            assert decision["updatedPermissions"] == updated_perms
