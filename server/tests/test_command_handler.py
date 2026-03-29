import pytest
import json
import asyncio
import os
import tempfile
from unittest.mock import Mock, AsyncMock, patch, PropertyMock


def _make_server(pane_output="❯\n❯"):
    """Create a mock server with standard defaults for CommandHandler tests."""
    server = Mock()
    server._active_tmux_session = "claude-connect_abc123"
    server.send_to_terminal = AsyncMock()
    server.active_session_id = "abc123"
    server.broadcast_message = AsyncMock()
    server.clients = set()
    server.tmux = Mock()
    server.tmux.capture_pane = Mock(return_value=pane_output)
    server.tmux.send_escape = Mock(return_value=True)
    # No transcript handler by default (pane capture path)
    server.transcript_handler = None
    return server


class TestCommandHandlerPaneCapture:
    """Tests for pane capture fallback (overlay commands, no transcript)."""

    @pytest.mark.asyncio
    async def test_execute_sends_command_to_tmux(self):
        from server.handlers.command_handler import CommandHandler

        server = _make_server("❯ /help\nAvailable commands:\n  /compact\n  /clear\n❯")
        handler = CommandHandler(server)
        await handler.execute("/help")

        server.send_to_terminal.assert_called_once_with("/help")

    @pytest.mark.asyncio
    async def test_execute_captures_pane_and_broadcasts(self):
        from server.handlers.command_handler import CommandHandler

        server = _make_server("❯ /help\nAvailable commands:\n  /compact\n  /clear\n❯")
        handler = CommandHandler(server)
        await handler.execute("/help")

        server.broadcast_message.assert_called_once()
        msg = server.broadcast_message.call_args[0][0]
        assert msg["type"] == "command_response"
        assert msg["command"] == "/help"
        assert "session_id" in msg
        assert len(msg["output"]) > 0

    @pytest.mark.asyncio
    async def test_execute_sends_escape_after_capture(self):
        from server.handlers.command_handler import CommandHandler

        server = _make_server("some output\n❯")
        handler = CommandHandler(server)
        await handler.execute("/status")

        server.tmux.send_escape.assert_called_once_with("claude-connect_abc123")

    @pytest.mark.asyncio
    async def test_strips_ansi_codes(self):
        from server.handlers.command_handler import CommandHandler

        server = _make_server("❯ /context\n\x1b[32m████████\x1b[0m Context: 45%\n❯")
        handler = CommandHandler(server)
        await handler.execute("/context")

        msg = server.broadcast_message.call_args[0][0]
        assert "\x1b[" not in msg["output"]
        assert "Context: 45%" in msg["output"]

    @pytest.mark.asyncio
    async def test_empty_output_fallback(self):
        from server.handlers.command_handler import CommandHandler

        server = _make_server("❯ /somecommand\n❯")
        handler = CommandHandler(server)
        await handler.execute("/somecommand")

        msg = server.broadcast_message.call_args[0][0]
        assert msg["output"] == "Command executed"

    @pytest.mark.asyncio
    async def test_trims_old_content_above_command(self):
        from server.handlers.command_handler import CommandHandler

        server = _make_server("Previous response text\nMore old content\n❯ /effort\nEffort level: high\n❯")
        handler = CommandHandler(server)
        await handler.execute("/effort")

        msg = server.broadcast_message.call_args[0][0]
        assert "Previous response" not in msg["output"]
        assert "More old content" not in msg["output"]
        assert "Effort level: high" in msg["output"]

    @pytest.mark.asyncio
    async def test_no_tmux_session_does_nothing(self):
        from server.handlers.command_handler import CommandHandler

        server = Mock()
        server._active_tmux_session = None
        server.send_to_terminal = AsyncMock()
        server.broadcast_message = AsyncMock()

        handler = CommandHandler(server)
        await handler.execute("/help")

        server.send_to_terminal.assert_not_called()
        server.broadcast_message.assert_not_called()

    @pytest.mark.asyncio
    async def test_falls_back_to_pane_when_transcript_has_dismissal(self):
        """When transcript stdout says 'dismissed', should use pane capture instead."""
        from server.handlers.command_handler import CommandHandler

        server = _make_server("Help overlay content\nShortcuts\n/compact /clear")

        # Create transcript with dismissal notice
        with tempfile.NamedTemporaryFile(mode='w', suffix='.jsonl', delete=False) as f:
            entry = {"message": {"role": "user", "content": "<local-command-stdout>Help dialog dismissed</local-command-stdout>"}}
            f.write(json.dumps(entry) + '\n')
            f.flush()
            mock_handler = Mock()
            mock_handler.expected_session_file = f.name
            server.transcript_handler = mock_handler

        handler = CommandHandler(server)
        await handler.execute("/help")

        os.unlink(f.name)
        msg = server.broadcast_message.call_args[0][0]
        # Should use pane output, not "Help dialog dismissed"
        assert "dismissed" not in msg["output"].lower()


class TestCommandHandlerTranscript:
    """Tests for transcript stdout path (inline commands)."""

    @pytest.mark.asyncio
    async def test_prefers_transcript_stdout_over_pane(self):
        """Should use transcript stdout when available."""
        from server.handlers.command_handler import CommandHandler

        server = _make_server("garbled pane content\n❯")

        with tempfile.NamedTemporaryFile(mode='w', suffix='.jsonl', delete=False) as f:
            # Write a pre-existing line (baseline)
            f.write(json.dumps({"message": {"role": "user", "content": "hello"}}) + '\n')
            f.flush()

            mock_handler = Mock()
            mock_handler.expected_session_file = f.name
            server.transcript_handler = mock_handler

            handler = CommandHandler(server)
            # Monkey-patch to write transcript stdout after send
            original_send = server.send_to_terminal

            async def send_and_write(text):
                await original_send(text)
                with open(f.name, 'a') as fh:
                    entry = {"message": {"role": "user", "content": "<local-command-stdout>Effort level: high</local-command-stdout>"}}
                    fh.write(json.dumps(entry) + '\n')

            server.send_to_terminal = send_and_write

            await handler.execute("/effort")

        os.unlink(f.name)
        msg = server.broadcast_message.call_args[0][0]
        assert msg["output"] == "Effort level: high"
        assert "garbled" not in msg["output"]

    @pytest.mark.asyncio
    async def test_strips_ansi_from_transcript_stdout(self):
        """Should strip ANSI codes from transcript stdout."""
        from server.handlers.command_handler import CommandHandler

        server = _make_server("❯\n❯")

        with tempfile.NamedTemporaryFile(mode='w', suffix='.jsonl', delete=False) as f:
            mock_handler = Mock()
            mock_handler.expected_session_file = f.name
            server.transcript_handler = mock_handler

            handler = CommandHandler(server)
            original_send = server.send_to_terminal

            async def send_and_write(text):
                await original_send(text)
                with open(f.name, 'a') as fh:
                    entry = {"message": {"role": "user", "content": "<local-command-stdout>\x1b[1mContext Usage\x1b[0m 45%</local-command-stdout>"}}
                    fh.write(json.dumps(entry) + '\n')

            server.send_to_terminal = send_and_write

            await handler.execute("/context")

        os.unlink(f.name)
        msg = server.broadcast_message.call_args[0][0]
        assert "\x1b[" not in msg["output"]
        assert "Context Usage" in msg["output"]
        assert "45%" in msg["output"]
