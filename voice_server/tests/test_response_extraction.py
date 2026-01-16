import json
import os
import tempfile

from voice_server.ios_server import TranscriptHandler
from voice_server.content_models import TextBlock, ThinkingBlock


def test_extract_incremental_blocks():
    """Test extracting only new blocks since last extraction"""
    with tempfile.NamedTemporaryFile(mode='w', suffix='.jsonl', delete=False) as f:
        # User message
        f.write(json.dumps({
            "message": {"role": "user", "content": "test input"}
        }) + "\n")

        # First assistant message - thinking block
        f.write(json.dumps({
            "message": {
                "role": "assistant",
                "id": "msg_123",
                "content": [
                    {"type": "thinking", "thinking": "Let me think", "signature": "sig1"}
                ]
            }
        }) + "\n")
        temp_path = f.name

    try:
        mock_server = type('obj', (), {'last_voice_input': 'test input'})()
        handler = TranscriptHandler(None, None, None, mock_server)

        # First extraction - should get thinking block
        new_blocks = handler.extract_new_assistant_content(temp_path)
        assert len(new_blocks) == 1
        assert isinstance(new_blocks[0], ThinkingBlock)

        # No file changes - should get nothing (line count already at end)
        new_blocks = handler.extract_new_assistant_content(temp_path)
        assert len(new_blocks) == 0

        # Add text block to file
        with open(temp_path, 'a') as f:
            f.write(json.dumps({
                "message": {
                    "role": "assistant",
                    "id": "msg_123",
                    "content": [
                        {"type": "text", "text": "Here's my answer"}
                    ]
                }
            }) + "\n")

        # Second extraction - should only get new text block
        new_blocks = handler.extract_new_assistant_content(temp_path)
        assert len(new_blocks) == 1
        assert isinstance(new_blocks[0], TextBlock)
        assert new_blocks[0].text == "Here's my answer"

    finally:
        os.unlink(temp_path)


def test_streaming_sends_blocks_incrementally():
    """Test that handler sends blocks as they arrive, not batched"""
    import asyncio

    with tempfile.NamedTemporaryFile(mode='w', suffix='.jsonl', delete=False) as f:
        f.write(json.dumps({
            "message": {"role": "user", "content": "test"}
        }) + "\n")
        temp_path = f.name

    try:
        # Track what was sent
        sent_responses = []

        async def mock_content_callback(response):
            sent_responses.append(response)

        mock_server = type('obj', (), {
            'last_voice_input': 'test',
            'waiting_for_response': True
        })()

        loop = asyncio.new_event_loop()
        handler = TranscriptHandler(mock_content_callback, None, loop, mock_server)

        # Simulate first file modification - thinking block added
        with open(temp_path, 'a') as f:
            f.write(json.dumps({
                "message": {
                    "role": "assistant",
                    "id": "msg_1",
                    "content": [{"type": "thinking", "thinking": "Thinking...", "signature": "s1"}]
                }
            }) + "\n")

        # Manually call on_modified (simulating file watcher)
        from watchdog.events import FileModifiedEvent
        event = FileModifiedEvent(temp_path)
        handler.last_modified = 0  # Reset debounce
        handler.on_modified(event)

        # Give async callbacks time to run
        loop.run_until_complete(asyncio.sleep(0.1))

        # Should have sent first response with thinking block
        assert len(sent_responses) == 1
        assert len(sent_responses[0].content_blocks) == 1
        assert isinstance(sent_responses[0].content_blocks[0], ThinkingBlock)

        # Simulate second file modification - text block added
        with open(temp_path, 'a') as f:
            f.write(json.dumps({
                "message": {
                    "role": "assistant",
                    "id": "msg_1",
                    "content": [{"type": "text", "text": "Answer"}]
                }
            }) + "\n")

        handler.last_modified = 0  # Reset debounce
        handler.on_modified(event)
        loop.run_until_complete(asyncio.sleep(0.1))

        # Should have sent second response with ONLY the text block
        assert len(sent_responses) == 2
        assert len(sent_responses[1].content_blocks) == 1
        assert isinstance(sent_responses[1].content_blocks[0], TextBlock)

        loop.close()
    finally:
        os.unlink(temp_path)


def test_state_resets_on_new_voice_input():
    """Test that tracking state resets when processing a new voice input"""
    with tempfile.NamedTemporaryFile(mode='w', suffix='.jsonl', delete=False) as f:
        # First conversation
        f.write(json.dumps({
            "message": {"role": "user", "content": "first question"}
        }) + "\n")
        f.write(json.dumps({
            "message": {
                "role": "assistant",
                "id": "msg_1",
                "content": [{"type": "text", "text": "first answer"}]
            }
        }) + "\n")
        temp_path = f.name

    try:
        mock_server = type('obj', (), {'last_voice_input': 'first question'})()
        handler = TranscriptHandler(None, None, None, mock_server)

        # Extract blocks from first conversation
        blocks = handler.extract_new_assistant_content(temp_path)
        assert len(blocks) == 1
        assert handler.processed_line_count == 2

        # Reset for new conversation
        handler.reset_tracking_state()

        # State should be cleared
        assert handler.processed_line_count == 0
        assert handler.expected_session_file is None

        # Add second conversation
        with open(temp_path, 'a') as f:
            f.write(json.dumps({
                "message": {"role": "user", "content": "second question"}
            }) + "\n")
            f.write(json.dumps({
                "message": {
                    "role": "assistant",
                    "id": "msg_2",
                    "content": [{"type": "text", "text": "second answer"}]
                }
            }) + "\n")

        # After reset, should extract ALL blocks from beginning
        blocks = handler.extract_new_assistant_content(temp_path)
        # Should get both assistant messages (line 2 and line 4)
        assert len(blocks) == 2
        assert blocks[0].text == "first answer"
        assert blocks[1].text == "second answer"

    finally:
        os.unlink(temp_path)
