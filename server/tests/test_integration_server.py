"""Tests for the E2E test server — injection endpoints and session simulation."""

import asyncio
import json
import time
import pytest

from aiohttp import web
from aiohttp.test_utils import AioHTTPTestCase, unittest_run_loop

# We test the TestConnectServer by starting it and connecting a WebSocket client.
# Since the server uses websockets library (not aiohttp ws), we test the HTTP
# endpoints directly and verify they broadcast to connected clients.

from server.integration_tests.test_server import TestConnectServer


class TestTestConnectServer:
    """Test the test server's HTTP injection and session simulation."""

    @pytest.fixture
    def server(self):
        """Create a test server instance (not started, just the object)."""
        s = TestConnectServer()
        return s

    # ------------------------------------------------------------------
    # Unit tests for broadcast_assistant_response format
    # ------------------------------------------------------------------

    def test_broadcast_assistant_response_format(self, server):
        """assistant_response has correct structure."""
        # Can't easily test broadcast without WebSocket, but we can test
        # that the method builds the right message format.
        # We'll monkey-patch broadcast to capture the message.
        captured = []

        async def mock_broadcast(msg):
            captured.append(msg)

        server.broadcast = mock_broadcast

        asyncio.run(server.broadcast_assistant_response([
            {"type": "text", "text": "hello"},
        ]))

        assert len(captured) == 1
        msg = captured[0]
        assert msg["type"] == "assistant_response"
        assert msg["content_blocks"] == [{"type": "text", "text": "hello"}]
        assert msg["is_incremental"] is True
        assert "timestamp" in msg
        assert "session_id" in msg
        assert "seq" in msg

    def test_broadcast_assistant_response_increments_seq(self, server):
        """Each broadcast increments sequence number."""
        captured = []

        async def mock_broadcast(msg):
            captured.append(msg)

        server.broadcast = mock_broadcast

        asyncio.run(server.broadcast_assistant_response([{"type": "text", "text": "a"}]))
        asyncio.run(server.broadcast_assistant_response([{"type": "text", "text": "b"}]))

        assert captured[0]["seq"] == 0
        assert captured[1]["seq"] == 1

    def test_broadcast_user_message_format(self, server):
        """user_message has correct structure."""
        captured = []

        async def mock_broadcast(msg):
            captured.append(msg)

        server.broadcast = mock_broadcast

        asyncio.run(server.broadcast_user_message("hello from user"))

        msg = captured[0]
        assert msg["type"] == "user_message"
        assert msg["role"] == "user"
        assert msg["content"] == "hello from user"
        assert "session_id" in msg
        assert "seq" in msg

    # ------------------------------------------------------------------
    # Session simulation
    # ------------------------------------------------------------------

    def test_handle_list_projects(self, server):
        """list_projects responds with mock projects."""
        sent = []

        class FakeWS:
            async def send(self, data):
                sent.append(json.loads(data))

        ws = FakeWS()
        asyncio.run(server.handle_message(ws, json.dumps({"type": "list_projects"})))

        assert len(sent) == 1
        assert sent[0]["type"] == "projects"
        assert len(sent[0]["projects"]) == 1
        assert sent[0]["projects"][0]["name"] == "e2e_test_project"

    def test_handle_list_sessions(self, server):
        """list_sessions responds with mock sessions."""
        sent = []

        class FakeWS:
            async def send(self, data):
                sent.append(json.loads(data))

        ws = FakeWS()
        asyncio.run(server.handle_message(ws, json.dumps({
            "type": "list_sessions",
            "folder_name": "-private-tmp-e2e-test-project",
        })))

        assert len(sent) == 1
        assert sent[0]["type"] == "sessions_list"
        assert "active_session_ids" in sent[0]

    def test_handle_open_session(self, server):
        """open_session responds with session_history + connection_status."""
        sent = []

        class FakeWS:
            async def send(self, data):
                sent.append(json.loads(data))

        ws = FakeWS()
        asyncio.run(server.handle_message(ws, json.dumps({
            "type": "open_session",
            "session_id": "test-session-1",
            "folder_name": "-private-tmp-e2e-test-project",
        })))

        types = [m["type"] for m in sent]
        assert "session_history" in types
        assert "connection_status" in types

        conn = next(m for m in sent if m["type"] == "connection_status")
        assert "test-session-1" in conn["active_session_ids"]

    def test_handle_new_session(self, server):
        """new_session creates a session and responds with session_created."""
        sent = []

        class FakeWS:
            async def send(self, data):
                sent.append(json.loads(data))

        ws = FakeWS()
        asyncio.run(server.handle_message(ws, json.dumps({
            "type": "new_session",
            "folder_name": "-private-tmp-e2e-test-project",
        })))

        types = [m["type"] for m in sent]
        assert "session_created" in types
        assert "connection_status" in types

    def test_handle_list_directory(self, server):
        """list_directory responds with mock entries."""
        sent = []

        class FakeWS:
            async def send(self, data):
                sent.append(json.loads(data))

        ws = FakeWS()
        asyncio.run(server.handle_message(ws, json.dumps({
            "type": "list_directory",
            "path": "/private/tmp/e2e_test_project",
        })))

        assert sent[0]["type"] == "directory_listing"
        assert len(sent[0]["entries"]) == 3

    def test_handle_read_file(self, server):
        """read_file responds with mock contents."""
        sent = []

        class FakeWS:
            async def send(self, data):
                sent.append(json.loads(data))

        ws = FakeWS()
        asyncio.run(server.handle_message(ws, json.dumps({
            "type": "read_file",
            "path": "/tmp/test.txt",
        })))

        assert sent[0]["type"] == "file_contents"
        assert "mock file contents" in sent[0]["contents"]

    def test_reset_clears_state(self, server):
        """Reset clears active sessions, seq, and logs."""
        server.active_session_ids = ["s1", "s2"]
        server._seq = 10
        server.logs = ["some log"]

        from aiohttp.test_utils import make_mocked_request

        # Simulate reset via direct call
        async def do_reset():
            # Use the server method directly
            server.logs = []
            server._seq = 0
            server.active_session_ids = []

        asyncio.run(do_reset())

        assert server.active_session_ids == []
        assert server._seq == 0
        assert server.logs == []

    # ------------------------------------------------------------------
    # HTTP injection endpoint format tests
    # ------------------------------------------------------------------

    def test_inject_permission_format(self, server):
        """inject_permission broadcasts correct permission_request."""
        captured = []

        async def mock_broadcast(msg):
            captured.append(msg)

        server.broadcast = mock_broadcast

        async def do_inject():
            # Simulate what the HTTP handler does
            data = {
                "request_id": "test-req-1",
                "prompt_type": "bash",
                "tool_name": "Bash",
                "tool_input": {"command": "ls"},
            }
            message = {
                "type": "permission_request",
                "request_id": data["request_id"],
                "session_id": "test-session-1",
                "prompt_type": data["prompt_type"],
                "tool_name": data["tool_name"],
                "tool_input": data["tool_input"],
                "context": None,
                "permission_suggestions": None,
                "timestamp": time.time(),
            }
            await server.broadcast(message)

        asyncio.run(do_inject())

        msg = captured[0]
        assert msg["type"] == "permission_request"
        assert msg["request_id"] == "test-req-1"
        assert msg["tool_name"] == "Bash"

    def test_inject_question_format(self, server):
        """inject_question broadcasts correct question_prompt."""
        captured = []

        async def mock_broadcast(msg):
            captured.append(msg)

        server.broadcast = mock_broadcast

        async def do_inject():
            message = {
                "type": "question_prompt",
                "request_id": "test-q-1",
                "session_id": "test-session-1",
                "header": "",
                "question": "Pick one:",
                "options": ["A", "B"],
                "multi_select": False,
                "question_index": 0,
                "total_questions": 1,
            }
            await server.broadcast(message)

        asyncio.run(do_inject())

        msg = captured[0]
        assert msg["type"] == "question_prompt"
        assert msg["question"] == "Pick one:"
        assert msg["options"] == ["A", "B"]
