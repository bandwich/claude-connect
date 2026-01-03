# voice_server/tests/test_message_handlers.py
import pytest
import json
import asyncio
import tempfile
import os
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
    async def test_close_session_kills_terminal(self):
        """close_session should kill terminal via VSCodeController"""
        from ios_server import VoiceServer

        server = VoiceServer()

        server.vscode_controller = Mock()
        server.vscode_controller.is_connected.return_value = True
        server.vscode_controller.kill_terminal = AsyncMock()

        mock_ws = AsyncMock()

        await server.handle_close_session(mock_ws)

        server.vscode_controller.kill_terminal.assert_called_once()

    @pytest.mark.asyncio
    async def test_close_session_returns_success_status(self):
        """close_session should send success status to client"""
        from ios_server import VoiceServer

        server = VoiceServer()
        server.vscode_controller = Mock()
        server.vscode_controller.is_connected.return_value = True
        server.vscode_controller.kill_terminal = AsyncMock()

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
    async def test_new_session_kills_existing_terminal_first(self):
        """new_session should kill existing terminal before creating new one"""
        from ios_server import VoiceServer

        server = VoiceServer()

        call_order = []
        server.vscode_controller = Mock()
        server.vscode_controller.is_connected.return_value = True
        server.vscode_controller.kill_terminal = AsyncMock(side_effect=lambda: call_order.append('kill'))
        server.vscode_controller.new_terminal = AsyncMock(side_effect=lambda: call_order.append('new'))
        server.vscode_controller.send_sequence = AsyncMock(return_value=True)

        mock_ws = AsyncMock()

        await server.handle_new_session(mock_ws, {"project_path": "/Users/test/myproject"})

        # Verify kill comes before new
        assert call_order == ['kill', 'new']
        server.vscode_controller.send_sequence.assert_called_with("claude\n")

    @pytest.mark.asyncio
    async def test_new_session_returns_success_status(self):
        """new_session should send success status"""
        from ios_server import VoiceServer

        server = VoiceServer()
        server.vscode_controller = Mock()
        server.vscode_controller.is_connected.return_value = True
        server.vscode_controller.kill_terminal = AsyncMock()
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


class TestResumeSession:
    """Tests for resume_session handler"""

    @pytest.mark.asyncio
    async def test_resume_session_kills_existing_terminal_first(self):
        """resume_session should kill existing terminal before creating new one"""
        from ios_server import VoiceServer

        server = VoiceServer()

        call_order = []
        server.vscode_controller = Mock()
        server.vscode_controller.is_connected.return_value = True
        server.vscode_controller.kill_terminal = AsyncMock(side_effect=lambda: call_order.append('kill'))
        server.vscode_controller.new_terminal = AsyncMock(side_effect=lambda: call_order.append('new'))
        server.vscode_controller.send_sequence = AsyncMock(return_value=True)

        mock_ws = AsyncMock()

        await server.handle_resume_session(mock_ws, {"session_id": "abc123-def456"})

        # Verify kill comes before new
        assert call_order == ['kill', 'new']
        server.vscode_controller.send_sequence.assert_called_with("claude --resume abc123-def456\n")

    @pytest.mark.asyncio
    async def test_resume_session_returns_success(self):
        """resume_session should return success status"""
        from ios_server import VoiceServer

        server = VoiceServer()
        server.vscode_controller = Mock()
        server.vscode_controller.is_connected.return_value = True
        server.vscode_controller.kill_terminal = AsyncMock()
        server.vscode_controller.new_terminal = AsyncMock()
        server.vscode_controller.send_sequence = AsyncMock(return_value=True)

        mock_ws = AsyncMock()
        sent_messages = []
        mock_ws.send = AsyncMock(side_effect=lambda msg: sent_messages.append(msg))

        await server.handle_resume_session(mock_ws, {"session_id": "test123"})

        responses = [json.loads(m) for m in sent_messages]
        resume_response = next((r for r in responses if r.get("type") == "session_resumed"), None)
        assert resume_response is not None
        assert resume_response["success"] is True
        assert resume_response["session_id"] == "test123"


class TestAddProject:
    """Tests for add_project handler"""

    @pytest.mark.asyncio
    async def test_add_project_kills_terminal_before_opening_folder(self):
        """add_project should kill existing terminal before opening new folder"""
        from ios_server import VoiceServer

        server = VoiceServer()

        with tempfile.TemporaryDirectory() as tmpdir:
            server.projects_base_path = tmpdir

            call_order = []
            server.vscode_controller = Mock()
            server.vscode_controller.is_connected.return_value = True
            server.vscode_controller.kill_terminal = AsyncMock(side_effect=lambda: call_order.append('kill'))
            server.vscode_controller.open_folder = AsyncMock(side_effect=lambda x: call_order.append('open'))
            server.vscode_controller.new_terminal = AsyncMock()
            server.vscode_controller.send_sequence = AsyncMock(return_value=True)

            mock_ws = AsyncMock()

            await server.handle_add_project(mock_ws, {"name": "test-project"})

            # Verify kill comes before open
            assert call_order == ['kill', 'open']

    @pytest.mark.asyncio
    async def test_add_project_creates_directory(self):
        """add_project should create project directory"""
        from ios_server import VoiceServer

        server = VoiceServer()

        with tempfile.TemporaryDirectory() as tmpdir:
            server.projects_base_path = tmpdir

            server.vscode_controller = Mock()
            server.vscode_controller.is_connected.return_value = True
            server.vscode_controller.kill_terminal = AsyncMock()
            server.vscode_controller.open_folder = AsyncMock()
            server.vscode_controller.new_terminal = AsyncMock()
            server.vscode_controller.send_sequence = AsyncMock(return_value=True)

            mock_ws = AsyncMock()

            await server.handle_add_project(mock_ws, {"name": "test-project"})

            project_path = os.path.join(tmpdir, "test-project")
            assert os.path.exists(project_path)
            assert os.path.isdir(project_path)

    @pytest.mark.asyncio
    async def test_add_project_opens_in_vscode(self):
        """add_project should open folder in VS Code"""
        from ios_server import VoiceServer

        server = VoiceServer()

        with tempfile.TemporaryDirectory() as tmpdir:
            server.projects_base_path = tmpdir

            server.vscode_controller = Mock()
            server.vscode_controller.is_connected.return_value = True
            server.vscode_controller.kill_terminal = AsyncMock()
            server.vscode_controller.open_folder = AsyncMock()
            server.vscode_controller.new_terminal = AsyncMock()
            server.vscode_controller.send_sequence = AsyncMock(return_value=True)

            mock_ws = AsyncMock()

            await server.handle_add_project(mock_ws, {"name": "my-project"})

            expected_path = f"{tmpdir}/my-project"
            server.vscode_controller.open_folder.assert_called_once_with(expected_path)

    @pytest.mark.asyncio
    async def test_add_project_starts_claude(self):
        """add_project should start claude in new terminal"""
        from ios_server import VoiceServer

        server = VoiceServer()

        with tempfile.TemporaryDirectory() as tmpdir:
            server.projects_base_path = tmpdir

            server.vscode_controller = Mock()
            server.vscode_controller.is_connected.return_value = True
            server.vscode_controller.kill_terminal = AsyncMock()
            server.vscode_controller.open_folder = AsyncMock()
            server.vscode_controller.new_terminal = AsyncMock()
            server.vscode_controller.send_sequence = AsyncMock(return_value=True)

            mock_ws = AsyncMock()

            await server.handle_add_project(mock_ws, {"name": "new-proj"})

            server.vscode_controller.new_terminal.assert_called_once()
            # send_sequence is called multiple times (claude\n, then \r for trust)
            calls = [str(c) for c in server.vscode_controller.send_sequence.call_args_list]
            assert any("claude" in c for c in calls)


class TestActiveSessionTracking:
    """Tests for active session tracking"""

    @pytest.mark.asyncio
    async def test_resume_session_sets_active_session_id(self):
        """resume_session should set active_session_id"""
        from ios_server import VoiceServer

        server = VoiceServer()
        server.vscode_controller = AsyncMock()
        server.vscode_controller.is_connected.return_value = True
        server.vscode_controller.kill_terminal = AsyncMock()
        server.vscode_controller.new_terminal = AsyncMock()
        server.vscode_controller.send_sequence = AsyncMock(return_value=True)

        mock_ws = AsyncMock()
        mock_ws.send = AsyncMock()

        await server.handle_resume_session(mock_ws, {"session_id": "abc123"})

        assert server.active_session_id == "abc123"

    @pytest.mark.asyncio
    async def test_close_session_clears_active_session_id(self):
        """close_session should clear active_session_id"""
        from ios_server import VoiceServer

        server = VoiceServer()
        server.active_session_id = "abc123"
        server.vscode_controller = AsyncMock()
        server.vscode_controller.is_connected.return_value = True
        server.vscode_controller.kill_terminal = AsyncMock()

        mock_ws = AsyncMock()
        mock_ws.send = AsyncMock()

        await server.handle_close_session(mock_ws)

        assert server.active_session_id is None

    @pytest.mark.asyncio
    async def test_new_session_clears_active_session_id(self):
        """new_session should clear active_session_id (new session has no ID yet)"""
        from ios_server import VoiceServer

        server = VoiceServer()
        server.active_session_id = "old-session"
        server.vscode_controller = AsyncMock()
        server.vscode_controller.is_connected.return_value = True
        server.vscode_controller.kill_terminal = AsyncMock()
        server.vscode_controller.new_terminal = AsyncMock()
        server.vscode_controller.send_sequence = AsyncMock(return_value=True)

        mock_ws = AsyncMock()
        mock_ws.send = AsyncMock()

        await server.handle_new_session(mock_ws, {"project_path": "/test"})

        assert server.active_session_id is None
