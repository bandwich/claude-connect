"""Tests for activity state idle debounce behavior."""

import time
from unittest.mock import AsyncMock, Mock, patch
import pytest

from server.main import ConnectServer
from server.infra.pane_parser import ActivityState
from server.models.session_context import SessionContext


def make_ctx(session_id="test-session", tmux_name="claude-connect_test"):
    """Create a SessionContext for testing."""
    return SessionContext(
        session_id=session_id,
        folder_name="test-folder",
        tmux_session_name=tmux_name,
    )


@pytest.fixture
def server():
    s = ConnectServer()
    s.broadcast_message = AsyncMock()
    s.viewed_session_id = "test-session"
    return s


class TestIdleDebounce:
    """Test that idle state is debounced — not broadcast until 3s of continuous idle."""

    @pytest.mark.asyncio
    async def test_idle_not_broadcast_immediately_after_thinking(self, server):
        """When pane goes thinking -> idle, idle should NOT broadcast right away."""
        ctx = make_ctx()
        ctx.last_activity_state = ActivityState(state="thinking", detail="")
        server.active_sessions = {"claude-connect_test": ctx}

        with patch.object(server.tmux, 'session_exists', return_value=True), \
             patch.object(server.tmux, 'capture_pane', return_value="some idle pane"), \
             patch('server.infra.pane_parser.parse_pane_status',
                   return_value=ActivityState(state="idle", detail="")):
            await server._check_activity_state()

        # Should NOT have broadcast idle
        server.broadcast_message.assert_not_called()
        # But idle_since should be set
        assert ctx.idle_since is not None

    @pytest.mark.asyncio
    async def test_non_idle_during_debounce_resets_and_broadcasts(self, server):
        """When debouncing idle and a non-idle state appears, reset debounce and broadcast."""
        ctx = make_ctx()
        # Was tool_active, went idle (debouncing), last_activity_state still tool_active
        ctx.last_activity_state = ActivityState(state="tool_active", detail="Reading...")
        ctx.idle_since = time.time() - 1.0  # Was idle for 1s
        server.active_sessions = {"claude-connect_test": ctx}

        with patch.object(server.tmux, 'session_exists', return_value=True), \
             patch.object(server.tmux, 'capture_pane', return_value="spinner pane"), \
             patch('server.infra.pane_parser.parse_pane_status',
                   return_value=ActivityState(state="thinking", detail="")):
            await server._check_activity_state()

        # Should broadcast thinking (state changed from tool_active)
        server.broadcast_message.assert_called_once()
        msg = server.broadcast_message.call_args[0][0]
        assert msg["state"] == "thinking"
        # idle_since should be reset
        assert ctx.idle_since is None

    @pytest.mark.asyncio
    async def test_idle_broadcasts_after_debounce_period(self, server):
        """After 3s of continuous idle, idle should finally broadcast."""
        ctx = make_ctx()
        ctx.last_activity_state = ActivityState(state="thinking", detail="")
        ctx.idle_since = time.time() - 4.0  # Idle for 4s (past debounce)
        server.active_sessions = {"claude-connect_test": ctx}

        with patch.object(server.tmux, 'session_exists', return_value=True), \
             patch.object(server.tmux, 'capture_pane', return_value="idle pane"), \
             patch('server.infra.pane_parser.parse_pane_status',
                   return_value=ActivityState(state="idle", detail="")):
            await server._check_activity_state()

        # Should broadcast idle now
        server.broadcast_message.assert_called_once()
        msg = server.broadcast_message.call_args[0][0]
        assert msg["state"] == "idle"

    @pytest.mark.asyncio
    async def test_tool_active_broadcasts_immediately(self, server):
        """Non-idle states always broadcast immediately without debounce."""
        ctx = make_ctx()
        ctx.last_activity_state = ActivityState(state="idle", detail="")
        server.active_sessions = {"claude-connect_test": ctx}

        with patch.object(server.tmux, 'session_exists', return_value=True), \
             patch.object(server.tmux, 'capture_pane', return_value="tool pane"), \
             patch('server.infra.pane_parser.parse_pane_status',
                   return_value=ActivityState(state="tool_active", detail="Reading 3 files...")):
            await server._check_activity_state()

        server.broadcast_message.assert_called_once()
        msg = server.broadcast_message.call_args[0][0]
        assert msg["state"] == "tool_active"
        assert msg["detail"] == "Reading 3 files..."
        assert ctx.idle_since is None

    @pytest.mark.asyncio
    async def test_idle_to_idle_no_double_broadcast(self, server):
        """If already idle (debounced and broadcast), don't broadcast again."""
        ctx = make_ctx()
        ctx.last_activity_state = ActivityState(state="idle", detail="")
        ctx.idle_since = None  # Already settled into idle
        server.active_sessions = {"claude-connect_test": ctx}

        with patch.object(server.tmux, 'session_exists', return_value=True), \
             patch.object(server.tmux, 'capture_pane', return_value="idle pane"), \
             patch('server.infra.pane_parser.parse_pane_status',
                   return_value=ActivityState(state="idle", detail="")):
            await server._check_activity_state()

        # Already idle, no change — should not broadcast
        server.broadcast_message.assert_not_called()


class TestSuppressIdle:
    """Test suppress_idle parameter for event-driven activity checks."""

    @pytest.mark.asyncio
    async def test_suppress_idle_skips_idle_broadcast(self, server):
        """With suppress_idle=True, idle pane state should not broadcast."""
        ctx = make_ctx()
        ctx.last_activity_state = ActivityState(state="thinking", detail="")
        server.active_sessions = {"claude-connect_test": ctx}

        with patch.object(server.tmux, 'session_exists', return_value=True), \
             patch.object(server.tmux, 'capture_pane', return_value="idle pane"), \
             patch('server.infra.pane_parser.parse_pane_status',
                   return_value=ActivityState(state="idle", detail="")):
            await server._check_activity_state(suppress_idle=True)

        server.broadcast_message.assert_not_called()
        # last_activity_state should NOT be updated to idle (preserve previous state)
        assert ctx.last_activity_state.state == "thinking"

    @pytest.mark.asyncio
    async def test_suppress_idle_still_broadcasts_non_idle(self, server):
        """With suppress_idle=True, non-idle states still broadcast normally."""
        ctx = make_ctx()
        ctx.last_activity_state = ActivityState(state="idle", detail="")
        server.active_sessions = {"claude-connect_test": ctx}

        with patch.object(server.tmux, 'session_exists', return_value=True), \
             patch.object(server.tmux, 'capture_pane', return_value="tool pane"), \
             patch('server.infra.pane_parser.parse_pane_status',
                   return_value=ActivityState(state="tool_active", detail="Searching...")):
            await server._check_activity_state(suppress_idle=True)

        server.broadcast_message.assert_called_once()
        msg = server.broadcast_message.call_args[0][0]
        assert msg["state"] == "tool_active"
