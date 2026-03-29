"""Smoke test: verify pane capture works for slash commands.

Requires a running Claude Code tmux session. Run manually:
    cd server/tests && python -m pytest test_command_capture.py -v -s

Marked as integration so it's skipped in normal test runs.
"""
import asyncio
import re
import time

import pytest

from server.infra.tmux_controller import TmuxController

ANSI_RE = re.compile(r'\x1b\[[0-9;]*[a-zA-Z]')


def strip_ansi(text: str) -> str:
    return ANSI_RE.sub('', text)


async def capture_stable_pane(tmux: TmuxController, session_name: str,
                               initial_delay: float = 0.3,
                               poll_interval: float = 0.2,
                               timeout: float = 3.0) -> str:
    """Poll pane until output stabilizes (2 identical captures)."""
    await asyncio.sleep(initial_delay)
    deadline = time.time() + timeout
    prev = None
    while time.time() < deadline:
        current = tmux.capture_pane(session_name, include_history=False)
        if current is not None and current == prev:
            return current
        prev = current
        await asyncio.sleep(poll_interval)
    return prev or ""


@pytest.mark.integration
class TestCommandCapture:
    """Manual integration tests — require a claude-connect tmux session."""

    @pytest.fixture
    def tmux(self):
        return TmuxController()

    @pytest.fixture
    def session_name(self, tmux):
        """Find a running claude-connect session."""
        sessions = tmux.list_sessions()
        if not sessions:
            pytest.skip("No claude-connect tmux session running")
        return sessions[0]

    @pytest.mark.asyncio
    async def test_capture_help(self, tmux, session_name):
        """Send /help to a live session and capture the overlay."""
        tmux.send_input(session_name, "/help")
        output = await capture_stable_pane(tmux, session_name)
        tmux.send_escape(session_name)

        cleaned = strip_ansi(output)
        print("--- Captured /help output ---")
        print(cleaned[:2000])
        print(f"--- Total length: {len(cleaned)} ---")

        # /help should produce some recognizable content
        assert len(cleaned) > 50, f"Captured output too short: {len(cleaned)} chars"

    @pytest.mark.asyncio
    async def test_capture_context(self, tmux, session_name):
        """Send /context (Category 1 — writes to transcript) and capture."""
        tmux.send_input(session_name, "/context")
        output = await capture_stable_pane(tmux, session_name)

        cleaned = strip_ansi(output)
        print("--- Captured /context output ---")
        print(cleaned[:2000])
        print(f"--- Total length: {len(cleaned)} ---")

        assert len(cleaned) > 20, f"Captured output too short: {len(cleaned)} chars"
