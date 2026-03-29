"""Tests for TTS preference handling."""
import pytest
import json
import asyncio
from unittest.mock import AsyncMock, Mock, patch

from server.main import ConnectServer


@pytest.fixture
async def server():
    """Create a ConnectServer with mocked dependencies."""
    with patch('server.main.TmuxController'), \
         patch('server.main.set_tmux_controller'), \
         patch('server.main.set_server'):
        s = ConnectServer()
        s.loop = asyncio.get_event_loop()
        s.tts_queue = asyncio.Queue()
        s.tts_cancel = asyncio.Event()
        return s


@pytest.mark.asyncio
async def test_tts_enabled_default_true(server):
    """TTS should be enabled by default."""
    assert server.tts_enabled is True


@pytest.mark.asyncio
async def test_set_preference_disables_tts(server):
    """set_preference with tts_enabled=false should disable TTS."""
    mock_ws = AsyncMock()
    await server.handle_message(
        mock_ws,
        json.dumps({"type": "set_preference", "tts_enabled": False})
    )
    assert server.tts_enabled is False


@pytest.mark.asyncio
async def test_set_preference_enables_tts(server):
    """set_preference with tts_enabled=true should enable TTS."""
    mock_ws = AsyncMock()
    server.tts_enabled = False
    await server.handle_message(
        mock_ws,
        json.dumps({"type": "set_preference", "tts_enabled": True})
    )
    assert server.tts_enabled is True


@pytest.mark.asyncio
async def test_handle_claude_response_skips_when_disabled(server):
    """When TTS is disabled, handle_claude_response should not queue audio."""
    server.tts_enabled = False
    server.clients = {AsyncMock()}

    await server.handle_claude_response("Hello world")

    # Queue should be empty — nothing was queued
    assert server.tts_queue.empty()


@pytest.mark.asyncio
async def test_handle_claude_response_queues_when_enabled(server):
    """When TTS is enabled, handle_claude_response should queue audio."""
    server.tts_enabled = True
    server.clients = {AsyncMock()}

    await server.handle_claude_response("Hello world")

    assert not server.tts_queue.empty()
    text = server.tts_queue.get_nowait()
    assert text == "Hello world"
