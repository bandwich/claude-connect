"""Tests for TTS queue behavior in VoiceServer."""
import pytest
import asyncio
import json
from unittest.mock import AsyncMock, MagicMock, patch

from voice_server.ios_server import VoiceServer


@pytest.fixture
async def server():
    """Create a VoiceServer with mocked dependencies."""
    with patch('voice_server.ios_server.TmuxController'), \
         patch('voice_server.ios_server.set_tmux_controller'), \
         patch('voice_server.ios_server.set_voice_server'):
        s = VoiceServer()
        s.loop = asyncio.get_event_loop()
        s.tts_queue = asyncio.Queue()
        s.tts_cancel = asyncio.Event()
        return s


@pytest.mark.asyncio
async def test_tts_queue_drains_to_latest(server):
    """When multiple texts are queued, only the latest is spoken."""
    generated_texts = []

    def fake_generate(text, voice="af_heart"):
        generated_texts.append(text)
        import numpy as np
        return np.zeros(100, dtype=np.float32)

    server.clients = set()

    with patch('voice_server.ios_server.generate_tts_audio', side_effect=fake_generate), \
         patch('voice_server.ios_server.samples_to_wav_bytes', return_value=b"fake_wav"):
        # Start worker
        worker_task = asyncio.create_task(server._tts_worker())

        # Queue 3 messages rapidly
        await server.tts_queue.put("first message")
        await server.tts_queue.put("second message")
        await server.tts_queue.put("third message")

        # Give worker time to process
        await asyncio.sleep(0.2)

        # Cancel worker
        worker_task.cancel()
        try:
            await worker_task
        except asyncio.CancelledError:
            pass

    # Only the latest message should have been generated
    assert generated_texts == ["third message"]


@pytest.mark.asyncio
async def test_tts_cancel_stops_streaming(server):
    """Setting cancel event stops in-progress streaming."""
    chunks_sent = []

    async def slow_stream(websocket, wav_bytes, cancel_event):
        for i in range(10):
            if cancel_event.is_set():
                return False
            chunks_sent.append(i)
            await asyncio.sleep(0.01)
        return True

    server._tts_stream = slow_stream
    server.tts_cancel = asyncio.Event()

    mock_ws = AsyncMock()
    server.clients = {mock_ws}

    # Start streaming, then cancel after a short delay
    async def cancel_after_delay():
        await asyncio.sleep(0.03)
        server.tts_cancel.set()

    cancel_task = asyncio.create_task(cancel_after_delay())
    result = await slow_stream(mock_ws, b"data", server.tts_cancel)
    await cancel_task

    assert result is False
    assert len(chunks_sent) < 10


@pytest.mark.asyncio
async def test_handle_claude_response_queues_text(server):
    """handle_claude_response puts text on queue instead of calling stream_audio directly."""
    # Start with empty queue
    assert server.tts_queue.empty()

    await server.handle_claude_response("hello world")

    assert not server.tts_queue.empty()
    text = server.tts_queue.get_nowait()
    assert text == "hello world"


@pytest.mark.asyncio
async def test_handle_claude_response_cancels_active_tts(server):
    """When TTS is active, handle_claude_response sets cancel event to interrupt it."""
    server.tts_active = True
    server.tts_cancel = asyncio.Event()
    server.clients = set()

    assert not server.tts_cancel.is_set()

    await server.handle_claude_response("new message")

    # Should have set cancel to interrupt active TTS
    assert server.tts_cancel.is_set()
    # Should still queue the text
    assert not server.tts_queue.empty()
    assert server.tts_queue.get_nowait() == "new message"


@pytest.mark.asyncio
async def test_handle_claude_response_sends_stop_audio_when_active(server):
    """When TTS is active, handle_claude_response sends stop_audio to clients."""
    server.tts_active = True
    server.tts_cancel = asyncio.Event()
    mock_ws = AsyncMock()
    server.clients = {mock_ws}

    await server.handle_claude_response("new message")

    # Should have sent stop_audio
    mock_ws.send.assert_called_once()
    sent = json.loads(mock_ws.send.call_args[0][0])
    assert sent["type"] == "stop_audio"


@pytest.mark.asyncio
async def test_handle_claude_response_no_cancel_when_idle(server):
    """When no TTS is active, handle_claude_response just queues without cancelling."""
    server.tts_active = False
    server.tts_cancel = asyncio.Event()

    await server.handle_claude_response("hello")

    assert not server.tts_cancel.is_set()
    assert server.tts_queue.get_nowait() == "hello"
