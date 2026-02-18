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

        # Verify start_session was called with resume_id (working_dir is None when no folder_name provided)
        server.tmux.start_session.assert_called_once_with(working_dir=None, resume_id="abc123-def456")

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

    @pytest.mark.asyncio
    async def test_add_project_preserves_spaces_in_name(self):
        """add_project should preserve spaces in the project name"""
        from ios_server import VoiceServer

        server = VoiceServer()

        with tempfile.TemporaryDirectory() as tmpdir:
            server.projects_base_path = tmpdir

            server.tmux = Mock()
            server.tmux.start_session = Mock(return_value=True)
            server.tmux.send_input = Mock(return_value=True)

            mock_ws = AsyncMock()

            await server.handle_add_project(mock_ws, {"name": "Test project"})

            # The project directory should preserve the space
            expected_path = os.path.join(tmpdir, "Test project")
            assert os.path.exists(expected_path)
            assert os.path.isdir(expected_path)
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


class TestConnectionStatusBranch:
    """Tests for branch field in connection_status"""

    @pytest.mark.asyncio
    async def test_connection_status_includes_branch(self):
        """connection_status should include branch field"""
        from ios_server import VoiceServer

        server = VoiceServer()
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


class TestListDirectory:
    """Tests for list_directory handler"""

    @pytest.mark.asyncio
    async def test_list_directory_returns_entries(self):
        """list_directory should return files and directories"""
        from ios_server import VoiceServer

        server = VoiceServer()

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
        from ios_server import VoiceServer

        server = VoiceServer()

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
        from ios_server import VoiceServer

        server = VoiceServer()

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
        from ios_server import VoiceServer

        server = VoiceServer()

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
        from ios_server import VoiceServer

        server = VoiceServer()

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
        from ios_server import VoiceServer

        server = VoiceServer()

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
        from ios_server import VoiceServer

        server = VoiceServer()

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
        from ios_server import VoiceServer

        server = VoiceServer()

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
        from ios_server import VoiceServer

        server = VoiceServer()

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
        from ios_server import VoiceServer

        server = VoiceServer()

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
        from ios_server import VoiceServer

        server = VoiceServer()

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
        from ios_server import VoiceServer

        server = VoiceServer()

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
        from ios_server import VoiceServer

        server = VoiceServer()

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
        from ios_server import VoiceServer

        server = VoiceServer()

        escape_called = False
        def mock_send_escape():
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
        from ios_server import VoiceServer

        server = VoiceServer()
        server.tmux = Mock()
        server.tmux.session_exists.return_value = False

        mock_ws = AsyncMock()
        await server.handle_message(mock_ws, json.dumps({"type": "interrupt"}))

        server.tmux.send_escape.assert_not_called()


@pytest.mark.asyncio
async def test_handle_user_message_sends_to_clients():
    """handle_user_message should send user_message JSON to all clients"""
    from voice_server.ios_server import VoiceServer

    server = VoiceServer()
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


class TestUserInput:
    """Tests for user_input message handler"""

    @pytest.mark.asyncio
    async def test_user_input_text_only(self):
        """user_input with text only should send text to terminal."""
        from ios_server import VoiceServer

        server = VoiceServer()
        server.tmux = Mock()
        server.tmux.session_exists.return_value = True
        server.tmux.send_input = Mock(return_value=True)

        mock_ws = AsyncMock()
        await server.handle_message(
            mock_ws,
            json.dumps({"type": "user_input", "text": "hello claude", "images": [], "timestamp": 1234})
        )

        server.tmux.send_input.assert_called_once_with("hello claude")

    @pytest.mark.asyncio
    async def test_user_input_with_images_saves_files(self):
        """user_input with images should save them and include paths in prompt."""
        from ios_server import VoiceServer
        import base64

        server = VoiceServer()
        server.tmux = Mock()
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

        # Verify send_input was called with text that includes an image path
        call_args = server.tmux.send_input.call_args[0][0]
        assert "what is this" in call_args
        assert "/tmp/claude_voice_img_" in call_args
        assert ".png" in call_args
