# voice_server/tests/test_http_server.py
"""Tests for HTTP server endpoints — verifies permission hook behavior"""

import pytest
import json
from aiohttp import web
from aiohttp.test_utils import AioHTTPTestCase, unittest_run_loop
import sys
import os

from voice_server.infra.http_server import create_http_app, set_voice_server, _voice_server
from voice_server.services.permission_handler import PermissionHandler


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
        # Verify Claude Code hook JSON format
        assert "hookSpecificOutput" in data
        assert data["hookSpecificOutput"]["hookEventName"] == "PermissionRequest"
        assert data["hookSpecificOutput"]["decision"]["behavior"] == "allow"

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
    async def test_post_tool_use_does_not_resolve_pending_permission(self):
        """PostToolUse for a different tool must NOT resolve a pending permission.

        Reproduces the bug: Edit permission is pending (user hasn't answered yet),
        a Read tool completes and fires PostToolUse. The old code resolved the Edit
        permission as "allow" — auto-approving without user consent and dismissing
        the prompt from the iOS app.
        """
        from unittest.mock import AsyncMock

        mock_client = AsyncMock()
        self.permission_handler.websocket_clients.add(mock_client)

        # Simulate: PermissionRequest hook registers an Edit permission
        request_id = self.permission_handler.generate_request_id()
        self.permission_handler.register_request(request_id)

        # Verify it's pending
        assert self.permission_handler.is_request_pending(request_id)

        # Simulate: PostToolUse fires for a Read tool (no request_id in payload)
        # With latest_request_id removed, this hits the no_request_id path
        resp = await self.client.post(
            "/permission_resolved",
            json={"tool_name": "Read"}
        )

        assert resp.status == 200
        data = await resp.json()
        assert data["action"] == "no_request_id"

        # The permission must STILL be pending — not resolved
        assert self.permission_handler.is_request_pending(request_id)

        # No permission_resolved should have been broadcast to iOS
        mock_client.send.assert_not_called()

    @unittest_run_loop
    async def test_health_endpoint(self):
        """Test GET /health returns ok"""
        resp = await self.client.get("/health")

        assert resp.status == 200
        data = await resp.json()
        assert data["status"] == "ok"


class TestSessionFiltering:
    """Tests for is_viewed_session() which gates permission/question broadcasts."""

    def _make_mock_server(self, viewed_session_id):
        from unittest.mock import MagicMock
        mock = MagicMock()
        mock.viewed_session_id = viewed_session_id
        mock._active_tmux_session = f"claude-connect_{viewed_session_id}"
        mock.active_sessions = {}
        return mock

    def test_empty_session_id_rejected(self):
        """Empty session ID (non-claude-connect session) is not viewed."""
        from voice_server.infra.http_server import is_viewed_session
        set_voice_server(self._make_mock_server("viewed-session-123"))
        try:
            assert is_viewed_session("") == False
        finally:
            set_voice_server(None)

    def test_wrong_session_id_rejected(self):
        """Different session ID is not viewed."""
        from voice_server.infra.http_server import is_viewed_session
        set_voice_server(self._make_mock_server("viewed-session-123"))
        try:
            assert is_viewed_session("other-session-456") == False
        finally:
            set_voice_server(None)

    def test_viewed_session_id_accepted(self):
        """Matching session ID passes through."""
        from voice_server.infra.http_server import is_viewed_session
        set_voice_server(self._make_mock_server("viewed-session-123"))
        try:
            assert is_viewed_session("viewed-session-123") == True
        finally:
            set_voice_server(None)

    def test_pending_session_matches_by_tmux_name(self):
        """Pending session ID matches by tmux session name."""
        from voice_server.infra.http_server import is_viewed_session
        mock = self._make_mock_server("real-session-id")
        mock._active_tmux_session = "claude-connect_pending-abc123"
        set_voice_server(mock)
        try:
            assert is_viewed_session("pending-abc123") == True
        finally:
            set_voice_server(None)

    def test_no_voice_server_allows_through(self):
        """When voice server isn't set, allow through for backward compat."""
        from voice_server.infra.http_server import is_viewed_session
        set_voice_server(None)
        assert is_viewed_session("any-session") == True

    def test_no_viewed_session_allows_through(self):
        """When no session is being viewed, allow through."""
        from voice_server.infra.http_server import is_viewed_session
        mock = self._make_mock_server("")
        mock.viewed_session_id = None
        set_voice_server(mock)
        try:
            assert is_viewed_session("any-session") == True
        finally:
            set_voice_server(None)
