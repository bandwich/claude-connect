# voice_server/tests/test_http_server.py
"""Tests for HTTP server endpoints"""

import pytest
import json
from aiohttp import web
from aiohttp.test_utils import AioHTTPTestCase, unittest_run_loop
import sys
import os

from voice_server.http_server import create_http_app
from voice_server.permission_handler import PermissionHandler


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
    async def test_health_endpoint(self):
        """Test GET /health returns ok"""
        resp = await self.client.get("/health")

        assert resp.status == 200
        data = await resp.json()
        assert data["status"] == "ok"
