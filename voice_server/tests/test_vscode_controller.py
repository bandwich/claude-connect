# voice_server/tests/test_vscode_controller.py
import pytest
import asyncio
from unittest.mock import AsyncMock


class TestVSCodeController:
    """Tests for VSCodeController class"""

    @pytest.mark.asyncio
    async def test_send_sequence_formats_command_correctly(self):
        """Should format sendSequence command correctly"""
        from vscode_controller import VSCodeController

        controller = VSCodeController()

        # Mock the WebSocket send with async mock
        sent_messages = []
        async def mock_send(msg):
            sent_messages.append(msg)

        controller._ws = AsyncMock()
        controller._ws.send = mock_send
        controller._connected = True

        await controller.send_sequence("hello world")

        assert len(sent_messages) == 1
        import json
        msg = json.loads(sent_messages[0])
        assert msg['command'] == 'workbench.action.terminal.sendSequence'
        assert msg['args'] == {'text': 'hello world'}


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
