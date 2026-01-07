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


class TestVoiceInputWithTmux:
    """Tests for voice input via tmux controller"""

    @pytest.mark.asyncio
    async def test_voice_input_uses_tmux_controller(self):
        """Voice input should send text via TmuxController"""
        from ios_server import VoiceServer

        server = VoiceServer()

        server.tmux = Mock()
        server.tmux.session_exists.return_value = True
        server.tmux.send_input = Mock(return_value=True)

        # Mock WebSocket
        mock_ws = AsyncMock()

        # Handle voice input
        await server.handle_voice_input(mock_ws, {"text": "hello claude"})

        # Verify send_input was called with text
        server.tmux.send_input.assert_called_once_with("hello claude")


class TestCloseSession:
    """Tests for close_session handler"""

    @pytest.mark.asyncio
    async def test_close_session_kills_tmux_session(self):
        """close_session should kill tmux session via TmuxController"""
        from ios_server import VoiceServer

        server = VoiceServer()

        server.tmux = Mock()
        server.tmux.kill_session = Mock(return_value=True)

        mock_ws = AsyncMock()

        await server.handle_close_session(mock_ws)

        server.tmux.kill_session.assert_called_once()

    @pytest.mark.asyncio
    async def test_close_session_returns_success_status(self):
        """close_session should send success status to client"""
        from ios_server import VoiceServer

        server = VoiceServer()
        server.tmux = Mock()
        server.tmux.kill_session = Mock(return_value=True)

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
    async def test_new_session_starts_tmux_session(self):
        """new_session should start a new tmux session"""
        from ios_server import VoiceServer

        server = VoiceServer()

        server.tmux = Mock()
        server.tmux.start_session = Mock(return_value=True)

        mock_ws = AsyncMock()

        await server.handle_new_session(mock_ws, {"project_path": "/Users/test/myproject"})

        # Verify start_session was called with working_dir
        server.tmux.start_session.assert_called_once_with(working_dir="/Users/test/myproject")

    @pytest.mark.asyncio
    async def test_new_session_returns_success_status(self):
        """new_session should send success status"""
        from ios_server import VoiceServer

        server = VoiceServer()
        server.tmux = Mock()
        server.tmux.start_session = Mock(return_value=True)

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
    async def test_resume_session_starts_with_resume_id(self):
        """resume_session should start tmux session with resume_id"""
        from ios_server import VoiceServer

        server = VoiceServer()

        server.tmux = Mock()
        server.tmux.start_session = Mock(return_value=True)

        mock_ws = AsyncMock()

        await server.handle_resume_session(mock_ws, {"session_id": "abc123-def456"})

        # Verify start_session was called with resume_id
        server.tmux.start_session.assert_called_once_with(resume_id="abc123-def456")

    @pytest.mark.asyncio
    async def test_resume_session_returns_success(self):
        """resume_session should return success status"""
        from ios_server import VoiceServer

        server = VoiceServer()
        server.tmux = Mock()
        server.tmux.start_session = Mock(return_value=True)

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
    async def test_add_project_creates_directory(self):
        """add_project should create project directory"""
        from ios_server import VoiceServer

        server = VoiceServer()

        with tempfile.TemporaryDirectory() as tmpdir:
            server.projects_base_path = tmpdir

            server.tmux = Mock()
            server.tmux.start_session = Mock(return_value=True)
            server.tmux.send_input = Mock(return_value=True)

            mock_ws = AsyncMock()

            await server.handle_add_project(mock_ws, {"name": "test-project"})

            project_path = os.path.join(tmpdir, "test-project")
            assert os.path.exists(project_path)
            assert os.path.isdir(project_path)

    @pytest.mark.asyncio
    async def test_add_project_starts_tmux_session(self):
        """add_project should start tmux session in new project directory"""
        from ios_server import VoiceServer

        server = VoiceServer()

        with tempfile.TemporaryDirectory() as tmpdir:
            server.projects_base_path = tmpdir

            server.tmux = Mock()
            server.tmux.start_session = Mock(return_value=True)
            server.tmux.send_input = Mock(return_value=True)

            mock_ws = AsyncMock()

            await server.handle_add_project(mock_ws, {"name": "my-project"})

            expected_path = f"{tmpdir}/my-project"
            server.tmux.start_session.assert_called_once_with(working_dir=expected_path)


class TestActiveSessionTracking:
    """Tests for active session tracking"""

    @pytest.mark.asyncio
    async def test_resume_session_sets_active_session_id(self):
        """resume_session should set active_session_id"""
        from ios_server import VoiceServer

        server = VoiceServer()
        server.tmux = Mock()
        server.tmux.start_session = Mock(return_value=True)

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
        server.tmux = Mock()
        server.tmux.kill_session = Mock(return_value=True)

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
        server.tmux = Mock()
        server.tmux.start_session = Mock(return_value=True)

        mock_ws = AsyncMock()
        mock_ws.send = AsyncMock()

        await server.handle_new_session(mock_ws, {"project_path": "/test"})

        assert server.active_session_id is None


class TestConnectionStatusBroadcast:
    """Tests for connection status broadcasting"""

    @pytest.mark.asyncio
    async def test_broadcast_includes_connected_status(self):
        """broadcast_connection_status should include connected"""
        from ios_server import VoiceServer

        server = VoiceServer()
        server.tmux = Mock()
        server.tmux.session_exists = Mock(return_value=True)
        server.active_session_id = "test-session"

        mock_ws = AsyncMock()
        sent_messages = []
        mock_ws.send = AsyncMock(side_effect=lambda msg: sent_messages.append(msg))
        server.clients.add(mock_ws)

        await server.broadcast_connection_status()

        assert len(sent_messages) == 1
        response = json.loads(sent_messages[0])
        assert response["type"] == "connection_status"
        assert response["connected"] is True
        assert response["active_session_id"] == "test-session"

    @pytest.mark.asyncio
    async def test_broadcast_on_client_connect(self):
        """Should broadcast status when client connects"""
        from ios_server import VoiceServer

        server = VoiceServer()
        server.tmux = Mock()
        server.tmux.session_exists = Mock(return_value=True)
        server.active_session_id = None
        server.loop = asyncio.get_event_loop()

        mock_ws = AsyncMock()
        sent_messages = []
        mock_ws.send = AsyncMock(side_effect=lambda msg: sent_messages.append(msg))

        # Simulate initial status send
        await server.send_status(mock_ws, "idle", "Connected")
        await server.send_connection_status(mock_ws)

        # Should have status message and connection_status
        responses = [json.loads(m) for m in sent_messages]
        connection_status = next((r for r in responses if r.get("type") == "connection_status"), None)
        assert connection_status is not None
        assert "connected" in connection_status
        assert "active_session_id" in connection_status
