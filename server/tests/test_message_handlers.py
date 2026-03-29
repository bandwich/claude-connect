# server/tests/test_message_handlers.py
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
        from server.main import ConnectServer
        from server.services.session_manager import Project

        server = ConnectServer()
        server.projects_base_path = "/nonexistent"

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
        from server.main import ConnectServer

        server = ConnectServer()

        server.tmux = Mock()
        server._active_tmux_session = "claude-connect_test"
        server.tmux.session_exists.return_value = True
        server.tmux.send_input = Mock(return_value=True)

        # Mock WebSocket
        mock_ws = AsyncMock()

        # Handle voice input
        await server.handle_voice_input(mock_ws, {"text": "hello claude"})

        # Verify send_input was called with session name and text
        server.tmux.send_input.assert_called_once_with("claude-connect_test", "hello claude")


class TestNewSession:
    """Tests for new_session handler"""

    @pytest.mark.asyncio
    async def test_new_session_starts_tmux_session(self):
        """new_session should start a new tmux session"""
        from server.main import ConnectServer

        server = ConnectServer()

        server.tmux = Mock()
        server.tmux.start_session = Mock(return_value=True)
        server.poll_claude_ready = AsyncMock(return_value=True)
        server.broadcast_connection_status = AsyncMock()

        mock_ws = AsyncMock()

        await server.handle_new_session(mock_ws, {"project_path": "/Users/test/myproject"})

        # Verify start_session was called with a tmux name and working_dir
        server.tmux.start_session.assert_called_once()
        call_args = server.tmux.start_session.call_args
        assert call_args[1]["working_dir"] == "/Users/test/myproject"
        assert call_args[0][0].startswith("claude-connect_pending-")

    @pytest.mark.asyncio
    async def test_new_session_returns_success_status(self):
        """new_session should send success status"""
        from server.main import ConnectServer

        server = ConnectServer()
        server.tmux = Mock()
        server.tmux.start_session = Mock(return_value=True)
        server.poll_claude_ready = AsyncMock(return_value=True)
        server.broadcast_connection_status = AsyncMock()

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
        from server.main import ConnectServer

        server = ConnectServer()

        server.tmux = Mock()
        server.tmux.start_session = Mock(return_value=True)
        server.poll_claude_ready = AsyncMock(return_value=True)
        server.broadcast_connection_status = AsyncMock()

        mock_ws = AsyncMock()

        await server.handle_resume_session(mock_ws, {"session_id": "abc123-def456"})

        # Verify start_session was called with tmux name, working_dir, resume_id, and env
        server.tmux.start_session.assert_called_once_with(
            "claude-connect_abc123-def456", working_dir=None, resume_id="abc123-def456",
            env={"CLAUDE_CONNECT_SESSION_ID": "abc123-def456"}
        )

    @pytest.mark.asyncio
    async def test_resume_session_returns_success(self):
        """resume_session should return success status"""
        from server.main import ConnectServer

        server = ConnectServer()
        server.tmux = Mock()
        server.tmux.start_session = Mock(return_value=True)
        server.poll_claude_ready = AsyncMock(return_value=True)
        server.broadcast_connection_status = AsyncMock()

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
        from server.main import ConnectServer

        server = ConnectServer()

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
    async def test_add_project_does_not_start_tmux(self):
        """add_project should only create directory, not start tmux"""
        from server.main import ConnectServer

        server = ConnectServer()

        with tempfile.TemporaryDirectory() as tmpdir:
            server.projects_base_path = tmpdir
            server.tmux = Mock()
            mock_ws = AsyncMock()

            await server.handle_add_project(mock_ws, {"name": "my-project"})

            server.tmux.start_session.assert_not_called()

    @pytest.mark.asyncio
    async def test_add_project_preserves_spaces_in_name(self):
        """add_project should preserve spaces in the project name"""
        from server.main import ConnectServer

        server = ConnectServer()

        with tempfile.TemporaryDirectory() as tmpdir:
            server.projects_base_path = tmpdir
            mock_ws = AsyncMock()

            await server.handle_add_project(mock_ws, {"name": "Test project"})

            expected_path = os.path.join(tmpdir, "Test project")
            assert os.path.exists(expected_path)
            assert os.path.isdir(expected_path)


class TestActiveSessionTracking:
    """Tests for active session tracking"""

    @pytest.mark.asyncio
    async def test_resume_session_sets_active_session_id(self):
        """resume_session should set active_session_id"""
        from server.main import ConnectServer

        server = ConnectServer()
        server.tmux = Mock()
        server.tmux.start_session = Mock(return_value=True)
        server.poll_claude_ready = AsyncMock(return_value=True)
        server.broadcast_connection_status = AsyncMock()

        mock_ws = AsyncMock()
        mock_ws.send = AsyncMock()

        await server.handle_resume_session(mock_ws, {"session_id": "abc123"})

        assert server.active_session_id == "abc123"

    @pytest.mark.asyncio
    async def test_stop_session_clears_active_session_id(self):
        """stop_session should clear active_session_id when stopping the active session"""
        from server.main import ConnectServer
        from server.models.session_context import SessionContext

        server = ConnectServer()
        server.active_session_id = "abc123"
        server._active_tmux_session = "claude-connect_abc123"
        server.viewed_session_id = "abc123"
        server.tmux = Mock()
        server.tmux.kill_session = Mock(return_value=True)
        server.tts_queue = asyncio.Queue()
        server.tts_cancel = asyncio.Event()
        server.clients = set()

        ctx = SessionContext(session_id="abc123", folder_name="test", tmux_session_name="claude-connect_abc123")
        server.active_sessions["claude-connect_abc123"] = ctx

        mock_ws = AsyncMock()
        mock_ws.send = AsyncMock()

        await server.handle_stop_session(mock_ws, {"session_id": "abc123"})

        assert server.active_session_id is None

    @pytest.mark.asyncio
    async def test_new_session_clears_active_session_id(self):
        """new_session should clear active_session_id (new session has no ID yet)"""
        from server.main import ConnectServer

        server = ConnectServer()
        server.active_session_id = "old-session"
        server.tmux = Mock()
        server.tmux.start_session = Mock(return_value=True)
        server.poll_claude_ready = AsyncMock(return_value=True)
        server.broadcast_connection_status = AsyncMock()

        mock_ws = AsyncMock()
        mock_ws.send = AsyncMock()

        await server.handle_new_session(mock_ws, {"project_path": "/test"})

        assert server.active_session_id is None


class TestTTSCancelOnSessionLeave:
    """Tests that TTS is cancelled when leaving a session"""

    @pytest.mark.asyncio
    async def test_stop_audio_message_cancels_tts(self):
        """Inbound stop_audio message should cancel any active TTS"""
        from server.main import ConnectServer

        server = ConnectServer()
        server.tts_queue = asyncio.Queue()
        server.tts_cancel = asyncio.Event()
        server.tts_active = True
        server.clients = set()

        await server.tts_queue.put("some text")

        mock_ws = AsyncMock()
        await server.handle_message(mock_ws, json.dumps({"type": "stop_audio"}))

        assert server.tts_cancel.is_set()
        assert server.tts_queue.empty()

    @pytest.mark.asyncio
    async def test_stop_session_cancels_tts(self):
        """stop_session should cancel TTS when stopping the viewed session"""
        from server.main import ConnectServer
        from server.models.session_context import SessionContext

        server = ConnectServer()
        server.tts_queue = asyncio.Queue()
        server.tts_cancel = asyncio.Event()
        server.tts_active = True
        server.viewed_session_id = "sess1"
        server.tmux = Mock()
        server.tmux.kill_session = Mock(return_value=True)
        server.clients = set()

        ctx = SessionContext(session_id="sess1", folder_name="test", tmux_session_name="claude-connect_sess1")
        server.active_sessions["claude-connect_sess1"] = ctx

        await server.tts_queue.put("queued text")

        mock_ws = AsyncMock()
        await server.handle_stop_session(mock_ws, {"session_id": "sess1"})

        assert server.tts_cancel.is_set()
        assert server.tts_queue.empty()

    @pytest.mark.asyncio
    async def test_stop_session_does_not_cancel_tts_for_other_session(self):
        """stop_session should NOT cancel TTS when stopping a non-viewed session"""
        from server.main import ConnectServer
        from server.models.session_context import SessionContext

        server = ConnectServer()
        server.tts_queue = asyncio.Queue()
        server.tts_cancel = asyncio.Event()
        server.tts_active = True
        server.viewed_session_id = "sess1"
        server.tmux = Mock()
        server.tmux.kill_session = Mock(return_value=True)
        server.clients = set()

        ctx = SessionContext(session_id="sess2", folder_name="test", tmux_session_name="claude-connect_sess2")
        server.active_sessions["claude-connect_sess2"] = ctx

        await server.tts_queue.put("queued text")

        mock_ws = AsyncMock()
        await server.handle_stop_session(mock_ws, {"session_id": "sess2"})

        assert not server.tts_cancel.is_set()
        assert not server.tts_queue.empty()

    @pytest.mark.asyncio
    async def test_view_session_cancels_tts(self):
        """view_session should cancel TTS from the previous session"""
        from server.main import ConnectServer
        from server.models.session_context import SessionContext

        server = ConnectServer()
        server.tts_queue = asyncio.Queue()
        server.tts_cancel = asyncio.Event()
        server.tts_active = True
        server.viewed_session_id = "old-session"
        server.clients = set()

        ctx = SessionContext(session_id="new-session", folder_name="test", tmux_session_name="claude-connect_new")
        server.active_sessions["claude-connect_new"] = ctx
        server.switch_watched_session = Mock()
        server.broadcast_connection_status = AsyncMock()
        server.broadcast_message = AsyncMock()

        await server.tts_queue.put("old session text")

        mock_ws = AsyncMock()
        await server.handle_view_session(mock_ws, {"session_id": "new-session"})

        assert server.tts_cancel.is_set()
        assert server.tts_queue.empty()


class TestConnectionStatusBranch:
    """Tests for branch field in connection_status"""

    @pytest.mark.asyncio
    async def test_connection_status_includes_branch(self):
        """connection_status should include branch field"""
        from server.main import ConnectServer

        server = ConnectServer()
        mock_ws = AsyncMock()
        server.tmux = Mock()
        server.tmux.session_exists = Mock(return_value=True)
        server.active_session_id = "test-session"

        await server.send_connection_status(mock_ws)

        response = json.loads(mock_ws.send.call_args[0][0])
        assert "branch" in response
        assert isinstance(response["branch"], str)


class TestConnectionStatusBroadcast:
    """Tests for connection status broadcasting"""

    @pytest.mark.asyncio
    async def test_broadcast_includes_connected_status(self):
        """broadcast_connection_status should include connected"""
        from server.main import ConnectServer

        server = ConnectServer()
        server.tmux = Mock()
        server._active_tmux_session = "claude-connect_test-session"
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
        from server.main import ConnectServer

        server = ConnectServer()
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


class TestListDirectory:
    """Tests for list_directory handler"""

    @pytest.mark.asyncio
    async def test_list_directory_returns_entries(self):
        """list_directory should return files and directories"""
        from server.main import ConnectServer

        server = ConnectServer()

        with tempfile.TemporaryDirectory() as tmpdir:
            # Create test files and directories
            os.makedirs(os.path.join(tmpdir, "subdir"))
            with open(os.path.join(tmpdir, "file1.txt"), "w") as f:
                f.write("content")
            with open(os.path.join(tmpdir, "file2.py"), "w") as f:
                f.write("print('hello')")

            mock_ws = AsyncMock()
            sent_messages = []
            mock_ws.send = AsyncMock(side_effect=lambda msg: sent_messages.append(msg))

            await server.handle_list_directory(mock_ws, {"path": tmpdir})

            assert len(sent_messages) == 1
            response = json.loads(sent_messages[0])
            assert response["type"] == "directory_listing"
            assert response["path"] == tmpdir
            assert "entries" in response
            # Should have subdir, file1.txt, file2.py
            names = [e["name"] for e in response["entries"]]
            assert "subdir" in names
            assert "file1.txt" in names
            assert "file2.py" in names

    @pytest.mark.asyncio
    async def test_list_directory_sorts_directories_first(self):
        """list_directory should sort directories before files, alphabetically"""
        from server.main import ConnectServer

        server = ConnectServer()

        with tempfile.TemporaryDirectory() as tmpdir:
            # Create mixed entries
            os.makedirs(os.path.join(tmpdir, "zebra_dir"))
            os.makedirs(os.path.join(tmpdir, "alpha_dir"))
            with open(os.path.join(tmpdir, "beta.txt"), "w") as f:
                f.write("")
            with open(os.path.join(tmpdir, "alpha.txt"), "w") as f:
                f.write("")

            mock_ws = AsyncMock()
            sent_messages = []
            mock_ws.send = AsyncMock(side_effect=lambda msg: sent_messages.append(msg))

            await server.handle_list_directory(mock_ws, {"path": tmpdir})

            response = json.loads(sent_messages[0])
            entries = response["entries"]
            # Directories first (alphabetical), then files (alphabetical)
            assert entries[0]["name"] == "alpha_dir"
            assert entries[0]["type"] == "directory"
            assert entries[1]["name"] == "zebra_dir"
            assert entries[1]["type"] == "directory"
            assert entries[2]["name"] == "alpha.txt"
            assert entries[2]["type"] == "file"
            assert entries[3]["name"] == "beta.txt"
            assert entries[3]["type"] == "file"

    @pytest.mark.asyncio
    async def test_list_directory_invalid_path_returns_error(self):
        """list_directory should return error for invalid path"""
        from server.main import ConnectServer

        server = ConnectServer()

        mock_ws = AsyncMock()
        sent_messages = []
        mock_ws.send = AsyncMock(side_effect=lambda msg: sent_messages.append(msg))

        await server.handle_list_directory(mock_ws, {"path": "/nonexistent/path"})

        response = json.loads(sent_messages[0])
        assert response["type"] == "directory_listing"
        assert response["error"] == "invalid_path"
        assert response["entries"] == []

    @pytest.mark.asyncio
    async def test_list_directory_message_routing(self):
        """list_directory message type should route to handler"""
        from server.main import ConnectServer

        server = ConnectServer()

        with tempfile.TemporaryDirectory() as tmpdir:
            mock_ws = AsyncMock()
            sent_messages = []
            mock_ws.send = AsyncMock(side_effect=lambda msg: sent_messages.append(msg))

            await server.handle_message(mock_ws, json.dumps({
                "type": "list_directory",
                "path": tmpdir
            }))

            response = json.loads(sent_messages[0])
            assert response["type"] == "directory_listing"


class TestReadFile:
    """Tests for read_file handler"""

    @pytest.mark.asyncio
    async def test_read_file_returns_contents(self):
        """read_file should return file contents"""
        from server.main import ConnectServer

        server = ConnectServer()

        with tempfile.TemporaryDirectory() as tmpdir:
            file_path = os.path.join(tmpdir, "test.txt")
            with open(file_path, "w") as f:
                f.write("Hello, World!")

            mock_ws = AsyncMock()
            sent_messages = []
            mock_ws.send = AsyncMock(side_effect=lambda msg: sent_messages.append(msg))

            await server.handle_read_file(mock_ws, {"path": file_path})

            response = json.loads(sent_messages[0])
            assert response["type"] == "file_contents"
            assert response["path"] == file_path
            assert response["contents"] == "Hello, World!"

    @pytest.mark.asyncio
    async def test_read_file_not_found_returns_error(self):
        """read_file should return error for nonexistent file"""
        from server.main import ConnectServer

        server = ConnectServer()

        mock_ws = AsyncMock()
        sent_messages = []
        mock_ws.send = AsyncMock(side_effect=lambda msg: sent_messages.append(msg))

        await server.handle_read_file(mock_ws, {"path": "/nonexistent/file.txt"})

        response = json.loads(sent_messages[0])
        assert response["type"] == "file_contents"
        assert response["error"] == "not_found"

    @pytest.mark.asyncio
    async def test_read_file_binary_returns_error(self):
        """read_file should return error for binary files"""
        from server.main import ConnectServer

        server = ConnectServer()

        with tempfile.TemporaryDirectory() as tmpdir:
            file_path = os.path.join(tmpdir, "binary.bin")
            with open(file_path, "wb") as f:
                f.write(bytes([0x00, 0x01, 0xFF, 0xFE]))

            mock_ws = AsyncMock()
            sent_messages = []
            mock_ws.send = AsyncMock(side_effect=lambda msg: sent_messages.append(msg))

            await server.handle_read_file(mock_ws, {"path": file_path})

            response = json.loads(sent_messages[0])
            assert response["type"] == "file_contents"
            assert response["error"] == "binary_file"

    @pytest.mark.asyncio
    async def test_read_file_returns_image_data_for_png(self):
        """read_file should return base64-encoded image data for PNG files"""
        from server.main import ConnectServer

        server = ConnectServer()

        with tempfile.TemporaryDirectory() as tmpdir:
            file_path = os.path.join(tmpdir, "test.png")
            # Write minimal PNG bytes (1x1 red pixel)
            import base64
            png_bytes = base64.b64decode(
                "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8/5+hHgAHggJ/PchI7wAAAABJRU5ErkJggg=="
            )
            with open(file_path, "wb") as f:
                f.write(png_bytes)

            mock_ws = AsyncMock()
            sent_messages = []
            mock_ws.send = AsyncMock(side_effect=lambda msg: sent_messages.append(msg))

            await server.handle_read_file(mock_ws, {"path": file_path})

            response = json.loads(sent_messages[0])
            assert response["type"] == "file_contents"
            assert response["path"] == file_path
            assert "image_data" in response
            assert response["image_format"] == "png"
            assert response["file_size"] == len(png_bytes)
            # Should NOT have contents or error fields
            assert "contents" not in response
            assert "error" not in response

    @pytest.mark.asyncio
    async def test_read_file_returns_image_data_for_jpg(self):
        """read_file should return base64-encoded image data for JPG files"""
        from server.main import ConnectServer

        server = ConnectServer()

        with tempfile.TemporaryDirectory() as tmpdir:
            file_path = os.path.join(tmpdir, "photo.jpg")
            with open(file_path, "wb") as f:
                f.write(b'\xff\xd8\xff\xe0' + b'\x00' * 100)  # JPEG header + padding

            mock_ws = AsyncMock()
            sent_messages = []
            mock_ws.send = AsyncMock(side_effect=lambda msg: sent_messages.append(msg))

            await server.handle_read_file(mock_ws, {"path": file_path})

            response = json.loads(sent_messages[0])
            assert response["type"] == "file_contents"
            assert "image_data" in response
            assert response["image_format"] == "jpg"

    @pytest.mark.asyncio
    async def test_read_file_rejects_oversized_image(self):
        """read_file should return error for images over 10MB"""
        from server.main import ConnectServer

        server = ConnectServer()

        with tempfile.TemporaryDirectory() as tmpdir:
            file_path = os.path.join(tmpdir, "huge.png")
            with open(file_path, "wb") as f:
                f.write(b'\x00' * (11 * 1024 * 1024))  # 11MB

            mock_ws = AsyncMock()
            sent_messages = []
            mock_ws.send = AsyncMock(side_effect=lambda msg: sent_messages.append(msg))

            await server.handle_read_file(mock_ws, {"path": file_path})

            response = json.loads(sent_messages[0])
            assert response["type"] == "file_contents"
            assert response["error"] == "file_too_large"
            assert response["file_size"] == 11 * 1024 * 1024

    @pytest.mark.asyncio
    async def test_read_file_svg_returns_text(self):
        """read_file should return SVG as text content (not image_data)"""
        from server.main import ConnectServer

        server = ConnectServer()

        with tempfile.TemporaryDirectory() as tmpdir:
            file_path = os.path.join(tmpdir, "icon.svg")
            with open(file_path, "w") as f:
                f.write('<svg xmlns="http://www.w3.org/2000/svg"><circle r="10"/></svg>')

            mock_ws = AsyncMock()
            sent_messages = []
            mock_ws.send = AsyncMock(side_effect=lambda msg: sent_messages.append(msg))

            await server.handle_read_file(mock_ws, {"path": file_path})

            response = json.loads(sent_messages[0])
            assert response["type"] == "file_contents"
            assert "contents" in response
            assert "image_data" not in response

    @pytest.mark.asyncio
    async def test_read_file_non_image_binary_still_returns_error(self):
        """read_file should still return binary_file error for non-image binary files"""
        from server.main import ConnectServer

        server = ConnectServer()

        with tempfile.TemporaryDirectory() as tmpdir:
            file_path = os.path.join(tmpdir, "data.bin")
            with open(file_path, "wb") as f:
                f.write(bytes([0x00, 0x01, 0xFF, 0xFE]))

            mock_ws = AsyncMock()
            sent_messages = []
            mock_ws.send = AsyncMock(side_effect=lambda msg: sent_messages.append(msg))

            await server.handle_read_file(mock_ws, {"path": file_path})

            response = json.loads(sent_messages[0])
            assert response["error"] == "binary_file"

    @pytest.mark.asyncio
    async def test_read_file_message_routing(self):
        """read_file message type should route to handler"""
        from server.main import ConnectServer

        server = ConnectServer()

        with tempfile.TemporaryDirectory() as tmpdir:
            file_path = os.path.join(tmpdir, "test.txt")
            with open(file_path, "w") as f:
                f.write("test content")

            mock_ws = AsyncMock()
            sent_messages = []
            mock_ws.send = AsyncMock(side_effect=lambda msg: sent_messages.append(msg))

            await server.handle_message(mock_ws, json.dumps({
                "type": "read_file",
                "path": file_path
            }))

            response = json.loads(sent_messages[0])
            assert response["type"] == "file_contents"
            assert response["contents"] == "test content"


class TestInterruptHandler:
    """Tests for interrupt message handler"""

    @pytest.mark.asyncio
    async def test_interrupt_sends_escape_to_tmux(self):
        """interrupt message should send Escape to tmux"""
        from server.main import ConnectServer

        server = ConnectServer()
        server._active_tmux_session = "claude-connect_test"

        escape_called = False
        def mock_send_escape(session_name):
            nonlocal escape_called
            escape_called = True
            return True
        server.tmux = Mock()
        server.tmux.session_exists.return_value = True
        server.tmux.send_escape = mock_send_escape

        mock_ws = AsyncMock()
        await server.handle_message(mock_ws, json.dumps({"type": "interrupt"}))

        assert escape_called, "send_escape was not called"

    @pytest.mark.asyncio
    async def test_interrupt_does_nothing_when_no_session(self):
        """interrupt should not crash when no tmux session exists"""
        from server.main import ConnectServer

        server = ConnectServer()
        server.tmux = Mock()
        server.tmux.session_exists.return_value = False

        mock_ws = AsyncMock()
        await server.handle_message(mock_ws, json.dumps({"type": "interrupt"}))

        server.tmux.send_escape.assert_not_called()


@pytest.mark.asyncio
async def test_handle_user_message_sends_to_clients():
    """handle_user_message should send user_message JSON to all clients"""
    from server.main import ConnectServer

    server = ConnectServer()
    server.active_session_id = "sess-123"

    sent_messages = []

    class MockWebSocket:
        async def send(self, data):
            sent_messages.append(json.loads(data))

    server.clients = {MockWebSocket()}

    await server.handle_user_message("hello from terminal")

    assert len(sent_messages) == 1
    msg = sent_messages[0]
    assert msg["type"] == "user_message"
    assert msg["role"] == "user"
    assert msg["content"] == "hello from terminal"
    assert msg["session_id"] == "sess-123"
    assert "timestamp" in msg


class TestResetSessionState:
    """Tests for _reset_session_state"""

    def test_reset_session_state_clears_all_state(self):
        """_reset_session_state should clear all session-related state."""
        from server.main import ConnectServer

        server = ConnectServer()
        # Set up dirty state
        server.active_session_id = "old-session"
        server.active_folder_name = "old-folder"
        server.transcript_path = "/some/path.jsonl"
        server._pending_session_snapshot = ("folder", {"id1"})
        server.current_branch = "main"

        server._reset_session_state()

        assert server.active_session_id is None
        assert server.active_folder_name is None
        assert server.transcript_path is None
        assert server._pending_session_snapshot is None
        assert server.current_branch == ""

    @pytest.mark.asyncio
    async def test_reset_session_state_preserves_cross_session_permissions(self):
        """_reset_session_state should NOT clear permissions from other sessions."""
        from server.main import ConnectServer

        server = ConnectServer()
        # Simulate a pending permission for session A
        server.permission_handler.pending_permissions["req-a"] = asyncio.Event()
        server.permission_handler.pending_messages["req-a"] = {
            "type": "permission_request",
            "session_id": "session-a",
        }

        # Starting a new session calls _reset_session_state
        server._reset_session_state()

        # Session A's permission should still be pending
        assert "req-a" in server.permission_handler.pending_permissions
        assert "req-a" in server.permission_handler.pending_messages
        assert server.permission_handler.is_request_pending("req-a")


class TestPollClaudeReady:
    """Tests for poll_claude_ready"""

    @pytest.mark.asyncio
    async def test_poll_claude_ready_success(self):
        """poll_claude_ready returns True when Claude becomes ready."""
        from server.main import ConnectServer

        server = ConnectServer()
        call_count = 0
        def mock_capture(session_name, include_history=True):
            nonlocal call_count
            call_count += 1
            if call_count >= 3:
                return "❯ Try something\n"
            return "$ claude\n"

        server.tmux = Mock()
        server.tmux.capture_pane = mock_capture
        result = await server.poll_claude_ready(tmux_name="claude-connect_test", timeout=5.0, interval=0.1)
        assert result is True

    @pytest.mark.asyncio
    async def test_poll_claude_ready_timeout(self):
        """poll_claude_ready returns False on timeout."""
        from server.main import ConnectServer

        server = ConnectServer()
        server.tmux = Mock()
        server.tmux.capture_pane = Mock(return_value="$ claude\n")
        result = await server.poll_claude_ready(tmux_name="claude-connect_test", timeout=0.5, interval=0.1)
        assert result is False


class TestResumeSessionLifecycle:
    """Tests for resume_session state reset and readiness"""

    @pytest.mark.asyncio
    async def test_resume_session_resets_state_before_starting(self):
        """handle_resume_session must reset all state before starting."""
        from server.main import ConnectServer

        server = ConnectServer()
        server.active_session_id = "stale-session"

        server.tmux = Mock()
        server.tmux.start_session = Mock(return_value=True)
        server.poll_claude_ready = AsyncMock(return_value=True)
        server.broadcast_connection_status = AsyncMock()
        server.session_manager.get_session_cwd = Mock(return_value="/tmp/test")
        server.switch_watched_session = Mock(return_value=True)

        mock_ws = AsyncMock()
        await server.handle_resume_session(mock_ws, {
            "session_id": "new-session-id",
            "folder_name": "test-folder"
        })

        sent = json.loads(mock_ws.send.call_args_list[0][0][0])
        assert sent["success"] is True

    @pytest.mark.asyncio
    async def test_resume_session_fails_when_claude_not_ready(self):
        """handle_resume_session sends failure when Claude doesn't become ready."""
        from server.main import ConnectServer

        server = ConnectServer()
        server.tmux = Mock()
        server.tmux.start_session = Mock(return_value=True)
        server.tmux.kill_session = Mock(return_value=True)
        server.poll_claude_ready = AsyncMock(return_value=False)
        server.session_manager.get_session_cwd = Mock(return_value="/tmp/test")

        mock_ws = AsyncMock()
        await server.handle_resume_session(mock_ws, {
            "session_id": "test-id",
            "folder_name": "test-folder"
        })

        sent = json.loads(mock_ws.send.call_args_list[0][0][0])
        assert sent["success"] is False
        assert "error" in sent


class TestNewSessionLifecycle:
    """Tests for new_session state reset and readiness"""

    @pytest.mark.asyncio
    async def test_new_session_resets_state_before_starting(self):
        """handle_new_session must reset all state before starting."""
        from server.main import ConnectServer

        server = ConnectServer()
        # Set up stale state
        server.active_session_id = "stale-session"
        server.transcript_path = "/old/path.jsonl"

        server.tmux = Mock()
        server.tmux.start_session = Mock(return_value=True)
        server.poll_claude_ready = AsyncMock(return_value=True)
        server.broadcast_connection_status = AsyncMock()

        mock_ws = AsyncMock()
        await server.handle_new_session(mock_ws, {"project_path": "/tmp/test"})

        # Verify stale state was cleared
        assert server.transcript_path is None

        # Verify success was sent
        sent = json.loads(mock_ws.send.call_args_list[0][0][0])
        assert sent["success"] is True

    @pytest.mark.asyncio
    async def test_new_session_fails_when_claude_not_ready(self):
        """handle_new_session sends failure when Claude doesn't become ready."""
        from server.main import ConnectServer

        server = ConnectServer()
        server.tmux = Mock()
        server.tmux.start_session = Mock(return_value=True)
        server.tmux.kill_session = Mock(return_value=True)
        server.poll_claude_ready = AsyncMock(return_value=False)

        mock_ws = AsyncMock()
        await server.handle_new_session(mock_ws, {"project_path": "/tmp/test"})

        # Verify failure was sent
        sent = json.loads(mock_ws.send.call_args_list[0][0][0])
        assert sent["success"] is False
        assert "error" in sent

        # Verify tmux was killed
        server.tmux.kill_session.assert_called()


class TestUserInput:
    """Tests for user_input message handler"""

    @pytest.mark.asyncio
    async def test_user_input_text_only(self):
        """user_input with text only should send text to terminal."""
        from server.main import ConnectServer

        server = ConnectServer()
        server.tmux = Mock()
        server._active_tmux_session = "claude-connect_test"
        server.tmux.session_exists.return_value = True
        server.tmux.send_input = Mock(return_value=True)

        mock_ws = AsyncMock()
        await server.handle_message(
            mock_ws,
            json.dumps({"type": "user_input", "text": "hello claude", "images": [], "timestamp": 1234})
        )

        server.tmux.send_input.assert_called_once_with("claude-connect_test", "hello claude")

    @pytest.mark.asyncio
    async def test_user_input_with_images_saves_files(self):
        """user_input with images should save them and include paths in prompt."""
        from server.main import ConnectServer
        import base64

        server = ConnectServer()
        server.tmux = Mock()
        server._active_tmux_session = "claude-connect_test"
        server.tmux.session_exists.return_value = True
        server.tmux.send_input = Mock(return_value=True)

        # Create a tiny valid base64 image
        img_data = base64.b64encode(b"\x89PNG\r\n\x1a\nfakedata").decode()

        mock_ws = AsyncMock()
        await server.handle_message(
            mock_ws,
            json.dumps({
                "type": "user_input",
                "text": "what is this",
                "images": [{"data": img_data, "filename": "photo.png"}],
                "timestamp": 1234
            })
        )

        # Verify send_input was called with session name and text that includes an image path
        call_args = server.tmux.send_input.call_args[0]
        assert call_args[0] == "claude-connect_test"  # session name
        text_arg = call_args[1]
        assert "what is this" in text_arg
        assert "/tmp/claude_voice_img_" in text_arg
        assert ".png" in text_arg


class TestCommandsList:
    """Tests for commands_list message handling"""

    @pytest.mark.asyncio
    async def test_commands_list_sent_on_connect(self):
        """Server should send commands_list during handle_client setup"""
        from server.main import ConnectServer

        server = ConnectServer()
        # Verify server has commands_provider
        assert hasattr(server, 'commands_provider')
        commands = server.commands_provider.get_all_commands()
        assert len(commands) > 50  # builtins + user skills

    @pytest.mark.asyncio
    async def test_handle_list_commands_returns_commands(self):
        """Should return commands_list when list_commands is received"""
        from server.main import ConnectServer

        server = ConnectServer()
        mock_ws = AsyncMock()
        sent_messages = []
        mock_ws.send = AsyncMock(side_effect=lambda msg: sent_messages.append(msg))

        await server.handle_message(mock_ws, json.dumps({"type": "list_commands"}))

        assert len(sent_messages) == 1
        response = json.loads(sent_messages[0])
        assert response["type"] == "commands_list"
        assert isinstance(response["commands"], list)
        assert len(response["commands"]) > 50
        # Verify structure
        first = response["commands"][0]
        assert "name" in first
        assert "description" in first
        assert "source" in first
