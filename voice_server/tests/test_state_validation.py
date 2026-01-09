"""Tests for server-side message validation"""

import pytest
import json
from unittest.mock import AsyncMock, MagicMock

import sys
import os
sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), '..')))


class TestMessageValidation:

    @pytest.mark.asyncio
    async def test_rejects_permission_response_without_pending(self):
        """permission_response without pending request should error"""
        from ios_server import VoiceServer

        server = VoiceServer()
        websocket = AsyncMock()

        message = json.dumps({
            "type": "permission_response",
            "request_id": "nonexistent-123",
            "decision": "allow"
        })

        await server.handle_message(websocket, message)

        websocket.send.assert_called()
        sent = json.loads(websocket.send.call_args[0][0])
        assert sent["type"] == "error"

    @pytest.mark.asyncio
    async def test_rejects_voice_input_while_permission_pending(self):
        """voice_input while permission pending should error"""
        from ios_server import VoiceServer

        server = VoiceServer()
        server.tmux = MagicMock()
        server.tmux.session_exists.return_value = False
        websocket = AsyncMock()

        # Register pending permission
        server.permission_handler.register_request("pending-123")

        message = json.dumps({
            "type": "voice_input",
            "text": "hello"
        })

        await server.handle_message(websocket, message)

        websocket.send.assert_called()
        sent = json.loads(websocket.send.call_args[0][0])
        assert sent["type"] == "error"
