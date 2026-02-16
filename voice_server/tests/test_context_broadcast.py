import pytest
import json
import asyncio
import tempfile
import os
from unittest.mock import AsyncMock, MagicMock, patch

# Test that TranscriptHandler broadcasts context_update on file change
def test_context_update_broadcast():
    """TranscriptHandler broadcasts context_update when transcript changes."""
    from ios_server import TranscriptHandler
    from context_tracker import ContextTracker

    # Create mock server with broadcast_message method
    mock_server = MagicMock()
    mock_server.active_session_id = "test-session-123"
    mock_server.broadcast_message = AsyncMock()

    loop = asyncio.new_event_loop()

    handler = TranscriptHandler(
        content_callback=AsyncMock(),
        audio_callback=AsyncMock(),
        loop=loop,
        server=mock_server
    )

    # Create temp transcript with usage data
    transcript_data = [
        {"message": {"role": "assistant", "content": "Hi", "usage": {"input_tokens": 100, "output_tokens": 50}}}
    ]

    with tempfile.NamedTemporaryFile(mode='w', suffix='.jsonl', delete=False) as f:
        for entry in transcript_data:
            f.write(json.dumps(entry) + "\n")
        f.flush()
        transcript_path = f.name

    try:
        handler.set_session_file(transcript_path)

        # Simulate file modification event
        mock_event = MagicMock()
        mock_event.is_directory = False
        mock_event.src_path = transcript_path

        # Call on_modified
        handler.on_modified(mock_event)

        # Give async tasks time to complete
        loop.run_until_complete(asyncio.sleep(0.1))

        # Verify broadcast_message was called with context_update
        calls = mock_server.broadcast_message.call_args_list
        context_calls = [c for c in calls if c[0][0].get("type") == "context_update"]

        assert len(context_calls) >= 1, "Should broadcast context_update"
        context_msg = context_calls[0][0][0]
        assert context_msg["tokens_used"] == 100  # input_tokens only (no output_tokens)
        assert context_msg["session_id"] == "test-session-123"

    finally:
        os.unlink(transcript_path)
        loop.close()
