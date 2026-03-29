"""Tests for /clear command handling."""

from unittest.mock import AsyncMock, MagicMock, patch

import pytest

from server.models.session_context import SessionContext


def _make_server():
    """Create a minimal mock ConnectServer for testing."""
    server = MagicMock()
    server.active_session_id = "old-session-id"
    server.active_folder_name = "test-folder"
    server.viewed_session_id = "old-session-id"
    server._active_tmux_session = "claude-connect_old-session-id"
    server.transcript_path = "/tmp/test/old-session-id.jsonl"
    server.broadcast_message = AsyncMock()
    server.broadcast_connection_status = AsyncMock()
    server.switch_watched_session = MagicMock(return_value=True)
    server.session_manager = MagicMock()
    server.transcript_handler = MagicMock()
    server.active_sessions = {}
    return server


class TestHandleClearCommand:
    """Test _handle_clear_command detects new file and switches watcher."""

    @pytest.mark.asyncio
    async def test_detects_new_transcript_and_switches(self):
        """After /clear, server finds new session file and switches to it."""
        server = _make_server()

        # Simulate: snapshot has old ID, then new ID appears
        server.session_manager.list_session_ids.return_value = {"old-session-id", "new-session-id"}
        server.session_manager.find_new_session.return_value = "new-session-id"

        ctx = SessionContext(
            session_id="old-session-id",
            folder_name="test-folder",
            tmux_session_name="claude-connect_old-session-id",
        )
        server.active_sessions["claude-connect_old-session-id"] = ctx

        from server.main import ConnectServer

        # Patch poll_for_session_file to return immediately
        async def fast_poll(find_fn, timeout=10.0, interval=0.2):
            return find_fn()

        with patch("server.main.poll_for_session_file", side_effect=fast_poll):
            await ConnectServer._handle_clear_command(server, ctx)

        # Should switch to new session file
        server.switch_watched_session.assert_called_once_with(
            "test-folder", "new-session-id", from_beginning=True
        )

        # Should update session IDs
        assert server.active_session_id == "new-session-id"
        assert server.viewed_session_id == "new-session-id"
        assert ctx.session_id == "new-session-id"

        # Should broadcast session_cleared
        server.broadcast_message.assert_any_await(
            {"type": "session_cleared", "session_id": "new-session-id"}
        )

    @pytest.mark.asyncio
    async def test_timeout_when_no_new_file(self):
        """If no new session file appears, log warning and don't crash."""
        server = _make_server()
        server.session_manager.find_new_session.return_value = None

        ctx = SessionContext(
            session_id="old-session-id",
            folder_name="test-folder",
            tmux_session_name="claude-connect_old-session-id",
        )
        server.active_sessions["claude-connect_old-session-id"] = ctx

        from server.main import ConnectServer

        async def fast_poll(find_fn, timeout=10.0, interval=0.2):
            return find_fn()

        with patch("server.main.poll_for_session_file", side_effect=fast_poll):
            await ConnectServer._handle_clear_command(server, ctx)

        # Should NOT switch or broadcast
        server.switch_watched_session.assert_not_called()
        server.broadcast_message.assert_not_awaited()

    @pytest.mark.asyncio
    async def test_no_folder_name_returns_early(self):
        """If session context has no folder_name, return without action."""
        server = _make_server()

        ctx = SessionContext(
            session_id="old-session-id",
            folder_name="",
            tmux_session_name="claude-connect_old-session-id",
        )

        from server.main import ConnectServer
        await ConnectServer._handle_clear_command(server, ctx)

        server.session_manager.list_session_ids.assert_not_called()
        server.broadcast_message.assert_not_awaited()


class TestClearCommandRouting:
    """Test that /clear is routed to special handling, not generic UI command."""

    @pytest.mark.asyncio
    async def test_clear_routes_to_handle_clear(self):
        """CommandHandler.execute sends /clear to tmux then triggers _handle_clear_command."""
        from server.handlers.command_handler import CommandHandler

        server = _make_server()
        server._active_tmux_session = "claude-connect_old-session-id"
        server.send_to_terminal = AsyncMock()
        server._handle_clear_command = AsyncMock()
        server._get_viewed_context = MagicMock()

        ctx = SessionContext(
            session_id="old-session-id",
            folder_name="test-folder",
            tmux_session_name="claude-connect_old-session-id",
        )
        server._get_viewed_context.return_value = ctx
        server.active_sessions["claude-connect_old-session-id"] = ctx

        handler = CommandHandler(server)
        await handler.execute("/clear")

        # Should send /clear to tmux
        server.send_to_terminal.assert_awaited_once_with("/clear")

        # Should trigger clear command handling
        server._handle_clear_command.assert_awaited_once_with(ctx)

    @pytest.mark.asyncio
    async def test_clear_without_viewed_context_still_sends(self):
        """If no viewed context, /clear is still sent to tmux but no detection."""
        from server.handlers.command_handler import CommandHandler

        server = _make_server()
        server._active_tmux_session = "claude-connect_old-session-id"
        server.send_to_terminal = AsyncMock()
        server._handle_clear_command = AsyncMock()
        server._get_viewed_context = MagicMock(return_value=None)

        handler = CommandHandler(server)
        await handler.execute("/clear")

        server.send_to_terminal.assert_awaited_once_with("/clear")
        server._handle_clear_command.assert_not_awaited()
