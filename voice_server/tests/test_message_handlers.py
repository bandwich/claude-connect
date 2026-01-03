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
        from ios_server import VoiceServer
        from session_manager import Project

        server = VoiceServer()

        # Mock SessionManager
        mock_session_manager = Mock()
        mock_session_manager.list_projects.return_value = [
            Project(path="/Users/test/project1", name="project1", session_count=5, folder_name="-Users-test-project1"),
            Project(path="/Users/test/project2", name="project2", session_count=3, folder_name="-Users-test-project2"),
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


class TestVoiceInputWithVSCode:
    """Tests for voice input via VSCode controller"""

    @pytest.mark.asyncio
    async def test_voice_input_uses_vscode_controller(self):
        """Voice input should send text via VSCodeController"""
        from ios_server import VoiceServer

        server = VoiceServer()

        server.vscode_controller = Mock()
        server.vscode_controller.is_connected.return_value = True
        server.vscode_controller.send_sequence = AsyncMock(return_value=True)

        # Mock WebSocket
        mock_ws = AsyncMock()

        # Handle voice input
        await server.handle_voice_input(mock_ws, {"text": "hello claude"})

        # Verify send_sequence was called with text + Enter
        server.vscode_controller.send_sequence.assert_called_once_with("hello claude\n")

    @pytest.mark.asyncio
    async def test_voice_input_falls_back_to_applescript(self):
        """Should fall back to AppleScript if VSCode not connected"""
        from ios_server import VoiceServer

        server = VoiceServer()

        server.vscode_controller = Mock()
        server.vscode_controller.is_connected.return_value = False

        # Mock AppleScript fallback
        with patch.object(server, 'send_to_vs_code_applescript', new_callable=AsyncMock) as mock_applescript:
            mock_ws = AsyncMock()
            await server.handle_voice_input(mock_ws, {"text": "hello"})
            mock_applescript.assert_called_once_with("hello")


class TestCloseSession:
    """Tests for close_session handler"""

    @pytest.mark.asyncio
    async def test_close_session_sends_ctrl_c(self):
        """close_session should send Ctrl+C via VSCodeController"""
        from ios_server import VoiceServer

        server = VoiceServer()

        server.vscode_controller = Mock()
        server.vscode_controller.is_connected.return_value = True
        server.vscode_controller.send_sequence = AsyncMock(return_value=True)

        mock_ws = AsyncMock()

        await server.handle_close_session(mock_ws)

        server.vscode_controller.send_sequence.assert_called_once_with("\x03")

    @pytest.mark.asyncio
    async def test_close_session_returns_success_status(self):
        """close_session should send success status to client"""
        from ios_server import VoiceServer

        server = VoiceServer()
        server.vscode_controller = Mock()
        server.vscode_controller.is_connected.return_value = True
        server.vscode_controller.send_sequence = AsyncMock(return_value=True)

        mock_ws = AsyncMock()
        sent_messages = []
        mock_ws.send = AsyncMock(side_effect=lambda msg: sent_messages.append(msg))

        await server.handle_close_session(mock_ws)

        responses = [json.loads(m) for m in sent_messages]
        closed_response = next((r for r in responses if r.get("type") == "session_closed"), None)
        assert closed_response is not None
        assert closed_response["success"] is True


class TestNewSession:
    """Tests for new_session handler"""

    @pytest.mark.asyncio
    async def test_new_session_opens_terminal_and_runs_claude(self):
        """new_session should open terminal and run claude"""
        from ios_server import VoiceServer

        server = VoiceServer()

        server.vscode_controller = Mock()
        server.vscode_controller.is_connected.return_value = True
        server.vscode_controller.new_terminal = AsyncMock()
        server.vscode_controller.send_sequence = AsyncMock(return_value=True)

        mock_ws = AsyncMock()

        await server.handle_new_session(mock_ws, {"project_path": "/Users/test/myproject"})

        server.vscode_controller.new_terminal.assert_called_once()
        server.vscode_controller.send_sequence.assert_called_with("claude\n")

    @pytest.mark.asyncio
    async def test_new_session_returns_success_status(self):
        """new_session should send success status"""
        from ios_server import VoiceServer

        server = VoiceServer()
        server.vscode_controller = Mock()
        server.vscode_controller.is_connected.return_value = True
        server.vscode_controller.new_terminal = AsyncMock()
        server.vscode_controller.send_sequence = AsyncMock(return_value=True)

        mock_ws = AsyncMock()
        sent_messages = []
        mock_ws.send = AsyncMock(side_effect=lambda msg: sent_messages.append(msg))

        await server.handle_new_session(mock_ws, {"project_path": "/test"})

        responses = [json.loads(m) for m in sent_messages]
        new_response = next((r for r in responses if r.get("type") == "session_created"), None)
        assert new_response is not None
        assert new_response["success"] is True
