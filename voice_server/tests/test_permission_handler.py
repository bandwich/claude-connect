# voice_server/tests/test_permission_handler.py
"""Tests for permission_handler.py"""

import pytest
import asyncio
import json
from unittest.mock import Mock, AsyncMock

from voice_server.permission_handler import PermissionHandler


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
