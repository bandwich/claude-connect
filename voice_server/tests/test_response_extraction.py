import json
import os
import re
import tempfile

from voice_server.ios_server import TranscriptHandler
from voice_server.content_models import TextBlock, ThinkingBlock, ToolUseBlock, ToolResultBlock


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

        async def mock_content_callback(response, start_line=0):
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


def test_extract_tool_result_from_user_message():
    """Should extract tool_result blocks from user messages in transcript"""
    with tempfile.NamedTemporaryFile(mode='w', suffix='.jsonl', delete=False) as f:
        # Assistant message with tool_use
        f.write(json.dumps({
            "message": {
                "role": "assistant",
                "content": [
                    {"type": "tool_use", "id": "toolu_01ABC", "name": "Bash", "input": {"command": "ls -la"}}
                ]
            }
        }) + "\n")
        # User message with tool_result
        f.write(json.dumps({
            "message": {
                "role": "user",
                "content": [
                    {"type": "tool_result", "tool_use_id": "toolu_01ABC", "content": "file1.txt\nfile2.txt", "is_error": False}
                ]
            }
        }) + "\n")
        temp_path = f.name

    try:
        mock_server = type('obj', (), {'last_voice_input': 'test'})()
        handler = TranscriptHandler(None, None, None, mock_server)

        blocks = handler.extract_new_assistant_content(temp_path)
        assert len(blocks) == 2
        assert isinstance(blocks[0], ToolUseBlock)
        assert isinstance(blocks[1], ToolResultBlock)
        assert blocks[1].tool_use_id == "toolu_01ABC"
        assert blocks[1].content == "file1.txt\nfile2.txt"
    finally:
        os.unlink(temp_path)


def test_extract_parallel_tool_results():
    """Should extract multiple tool_results from a single user message"""
    with tempfile.NamedTemporaryFile(mode='w', suffix='.jsonl', delete=False) as f:
        # Assistant with 2 parallel tool_uses
        f.write(json.dumps({
            "message": {
                "role": "assistant",
                "content": [
                    {"type": "tool_use", "id": "toolu_01A", "name": "Grep", "input": {"pattern": "foo"}},
                    {"type": "tool_use", "id": "toolu_01B", "name": "Grep", "input": {"pattern": "bar"}}
                ]
            }
        }) + "\n")
        # User message with both results
        f.write(json.dumps({
            "message": {
                "role": "user",
                "content": [
                    {"type": "tool_result", "tool_use_id": "toolu_01A", "content": "match1"},
                    {"type": "tool_result", "tool_use_id": "toolu_01B", "content": "match2"}
                ]
            }
        }) + "\n")
        temp_path = f.name

    try:
        mock_server = type('obj', (), {'last_voice_input': 'test'})()
        handler = TranscriptHandler(None, None, None, mock_server)

        blocks = handler.extract_new_assistant_content(temp_path)
        assert len(blocks) == 4  # 2 tool_use + 2 tool_result
        assert isinstance(blocks[2], ToolResultBlock)
        assert isinstance(blocks[3], ToolResultBlock)
        assert blocks[2].tool_use_id == "toolu_01A"
        assert blocks[3].tool_use_id == "toolu_01B"
    finally:
        os.unlink(temp_path)


def test_extract_skips_non_tool_result_user_messages():
    """Should not extract regular user text messages"""
    with tempfile.NamedTemporaryFile(mode='w', suffix='.jsonl', delete=False) as f:
        f.write(json.dumps({
            "message": {
                "role": "user",
                "content": "just a regular user message"
            }
        }) + "\n")
        f.write(json.dumps({
            "message": {
                "role": "assistant",
                "content": [{"type": "text", "text": "hello"}]
            }
        }) + "\n")
        temp_path = f.name

    try:
        mock_server = type('obj', (), {'last_voice_input': 'test'})()
        handler = TranscriptHandler(None, None, None, mock_server)

        blocks = handler.extract_new_assistant_content(temp_path)
        assert len(blocks) == 1  # Only the text block
        assert isinstance(blocks[0], TextBlock)
    finally:
        os.unlink(temp_path)


def test_extract_tool_result_with_list_content():
    """tool_result with list content should join text blocks, not str() the list"""
    with tempfile.NamedTemporaryFile(mode='w', suffix='.jsonl', delete=False) as f:
        f.write(json.dumps({
            "message": {
                "role": "assistant",
                "content": [
                    {"type": "tool_use", "id": "toolu_01XYZ", "name": "Task", "input": {"prompt": "do stuff"}}
                ]
            }
        }) + "\n")
        f.write(json.dumps({
            "message": {
                "role": "user",
                "content": [
                    {
                        "type": "tool_result",
                        "tool_use_id": "toolu_01XYZ",
                        "content": [
                            {"type": "text", "text": "First part of result."},
                            {"type": "text", "text": "Second part of result."}
                        ]
                    }
                ]
            }
        }) + "\n")
        temp_path = f.name

    try:
        mock_server = type('obj', (), {'last_voice_input': 'test'})()
        handler = TranscriptHandler(None, None, None, mock_server)

        blocks = handler.extract_new_assistant_content(temp_path)
        assert len(blocks) == 2
        result_block = blocks[1]
        assert isinstance(result_block, ToolResultBlock)
        # Should be joined text, not "[{'type': 'text', ..."
        assert result_block.content == "First part of result.\nSecond part of result."
        assert "[{" not in result_block.content
    finally:
        os.unlink(temp_path)


def test_extract_user_text_from_string_content():
    """User messages with string content should be returned as user_texts"""
    with tempfile.NamedTemporaryFile(mode='w', suffix='.jsonl', delete=False) as f:
        f.write(json.dumps({
            "type": "user",
            "message": {"role": "user", "content": "hello from terminal"}
        }) + "\n")
        temp_path = f.name

    try:
        mock_server = type('obj', (), {'last_voice_input': None})()
        handler = TranscriptHandler(None, None, None, mock_server)
        blocks, user_texts, _ = handler.extract_new_content(temp_path)
        assert len(blocks) == 0
        assert len(user_texts) == 1
        assert user_texts[0][0] == "hello from terminal"
    finally:
        os.unlink(temp_path)


def test_extract_user_text_from_list_with_text_blocks():
    """User messages with text blocks (non-tool_result) should be returned"""
    with tempfile.NamedTemporaryFile(mode='w', suffix='.jsonl', delete=False) as f:
        f.write(json.dumps({
            "type": "user",
            "message": {"role": "user", "content": [
                {"type": "text", "text": "[Request interrupted by user]"}
            ]}
        }) + "\n")
        temp_path = f.name

    try:
        mock_server = type('obj', (), {'last_voice_input': None})()
        handler = TranscriptHandler(None, None, None, mock_server)
        blocks, user_texts, _ = handler.extract_new_content(temp_path)
        assert len(blocks) == 0
        assert len(user_texts) == 1
        assert user_texts[0][0] == "[Request interrupted by user]"
    finally:
        os.unlink(temp_path)


def test_extract_strips_tool_use_suffix_from_interrupt():
    """[Request interrupted by user for tool use] should become [Request interrupted by user]"""
    with tempfile.NamedTemporaryFile(mode='w', suffix='.jsonl', delete=False) as f:
        f.write(json.dumps({
            "type": "user",
            "message": {"role": "user", "content": [
                {"type": "text", "text": "[Request interrupted by user for tool use]"}
            ]}
        }) + "\n")
        temp_path = f.name

    try:
        mock_server = type('obj', (), {'last_voice_input': None})()
        handler = TranscriptHandler(None, None, None, mock_server)
        blocks, user_texts, _ = handler.extract_new_content(temp_path)
        assert len(user_texts) == 1
        assert user_texts[0][0] == "[Request interrupted by user]"
    finally:
        os.unlink(temp_path)


def test_extract_image_source_rewrites_to_filename():
    """[Image: source: /path/to/file.png] should become [Image: file.png]"""
    with tempfile.NamedTemporaryFile(mode='w', suffix='.jsonl', delete=False) as f:
        f.write(json.dumps({
            "type": "user",
            "message": {"role": "user", "content": [
                {"type": "text", "text": "[Image: source: /Users/aaron/Downloads/IMG_5594.PNG]"}
            ]}
        }) + "\n")
        temp_path = f.name

    try:
        mock_server = type('obj', (), {'last_voice_input': None})()
        handler = TranscriptHandler(None, None, None, mock_server)
        blocks, user_texts, _ = handler.extract_new_content(temp_path)
        assert len(user_texts) == 1
        assert user_texts[0][0] == "[Image: IMG_5594.PNG]"
    finally:
        os.unlink(temp_path)


def test_extract_skips_image_blocks():
    """Raw image blocks (base64 data) should be silently skipped"""
    with tempfile.NamedTemporaryFile(mode='w', suffix='.jsonl', delete=False) as f:
        f.write(json.dumps({
            "type": "user",
            "message": {"role": "user", "content": [
                {"type": "image", "source": {"type": "base64", "media_type": "image/png", "data": "abc123"}}
            ]}
        }) + "\n")
        temp_path = f.name

    try:
        mock_server = type('obj', (), {'last_voice_input': None})()
        handler = TranscriptHandler(None, None, None, mock_server)
        blocks, user_texts, _ = handler.extract_new_content(temp_path)
        assert len(blocks) == 0
        assert len(user_texts) == 0
    finally:
        os.unlink(temp_path)


def test_extract_skips_skill_expansions():
    """Skill expansion user messages should not be surfaced"""
    with tempfile.NamedTemporaryFile(mode='w', suffix='.jsonl', delete=False) as f:
        f.write(json.dumps({
            "type": "user",
            "message": {"role": "user", "content": "Base directory for this skill: /foo/bar"}
        }) + "\n")
        temp_path = f.name

    try:
        mock_server = type('obj', (), {'last_voice_input': None})()
        handler = TranscriptHandler(None, None, None, mock_server)
        blocks, user_texts, _ = handler.extract_new_content(temp_path)
        assert len(user_texts) == 0
    finally:
        os.unlink(temp_path)


def test_extract_skips_task_notifications():
    """<task-notification> user messages should not be surfaced as user_texts"""
    with tempfile.NamedTemporaryFile(mode='w', suffix='.jsonl', delete=False) as f:
        f.write(json.dumps({
            "type": "user",
            "message": {"role": "user", "content": "<task-notification>something</task-notification>"}
        }) + "\n")
        temp_path = f.name

    try:
        mock_server = type('obj', (), {'last_voice_input': None})()
        handler = TranscriptHandler(None, None, None, mock_server)
        blocks, user_texts, _ = handler.extract_new_content(temp_path)
        assert len(user_texts) == 0
    finally:
        os.unlink(temp_path)


def test_task_notification_extracts_tool_use_id():
    """<task-notification> with tool-use-id should return it in task_completed_ids"""
    notification = (
        '<task-notification>\n'
        '<task-id>b7ou45mop</task-id>\n'
        '<tool-use-id>toolu_01Dtc8MmBh3YCbZnX4YFBDXg</tool-use-id>\n'
        '<output-file>/tmp/test.output</output-file>\n'
        '<status>completed</status>\n'
        '<summary>done</summary>\n'
        '</task-notification>\nRead the output file.'
    )
    with tempfile.NamedTemporaryFile(mode='w', suffix='.jsonl', delete=False) as f:
        f.write(json.dumps({
            "type": "user",
            "message": {"role": "user", "content": notification}
        }) + "\n")
        temp_path = f.name

    try:
        mock_server = type('obj', (), {'last_voice_input': None})()
        handler = TranscriptHandler(None, None, None, mock_server)
        blocks, user_texts, task_completed_ids = handler.extract_new_content(temp_path)
        assert len(user_texts) == 0
        assert len(task_completed_ids) == 1
        assert task_completed_ids[0] == "toolu_01Dtc8MmBh3YCbZnX4YFBDXg"
    finally:
        os.unlink(temp_path)


def test_task_notification_in_list_content_extracts_tool_use_id():
    """<task-notification> in list-style content should also extract tool-use-id"""
    notification = (
        '<task-notification>\n'
        '<task-id>abc123</task-id>\n'
        '<tool-use-id>toolu_01ABC</tool-use-id>\n'
        '</task-notification>'
    )
    with tempfile.NamedTemporaryFile(mode='w', suffix='.jsonl', delete=False) as f:
        f.write(json.dumps({
            "type": "user",
            "message": {"role": "user", "content": [
                {"type": "text", "text": notification}
            ]}
        }) + "\n")
        temp_path = f.name

    try:
        mock_server = type('obj', (), {'last_voice_input': None})()
        handler = TranscriptHandler(None, None, None, mock_server)
        blocks, user_texts, task_completed_ids = handler.extract_new_content(temp_path)
        assert len(user_texts) == 0
        assert len(task_completed_ids) == 1
        assert task_completed_ids[0] == "toolu_01ABC"
    finally:
        os.unlink(temp_path)


def test_taskoutput_tool_use_is_hidden():
    """TaskOutput tool_use blocks and their results should be filtered out"""
    with tempfile.NamedTemporaryFile(mode='w', suffix='.jsonl', delete=False) as f:
        # Assistant sends a TaskOutput call
        f.write(json.dumps({
            "message": {
                "role": "assistant",
                "content": [
                    {"type": "tool_use", "id": "toolu_01ABC", "name": "TaskOutput", "input": {"task_id": "bfb6bf6", "block": True}}
                ]
            }
        }) + "\n")
        # The tool result comes back
        f.write(json.dumps({
            "message": {
                "role": "user",
                "content": [
                    {
                        "type": "tool_result",
                        "tool_use_id": "toolu_01ABC",
                        "content": "<output>Agent found stuff</output>"
                    }
                ]
            }
        }) + "\n")
        temp_path = f.name

    try:
        mock_server = type('obj', (), {'last_voice_input': 'test'})()
        handler = TranscriptHandler(None, None, None, mock_server)

        blocks = handler.extract_new_assistant_content(temp_path)
        # Both the TaskOutput tool_use and its result should be filtered out
        assert len(blocks) == 0, f"Expected 0 blocks but got {len(blocks)}: {blocks}"
    finally:
        os.unlink(temp_path)


def test_taskoutput_hidden_alongside_visible_tools():
    """TaskOutput should be hidden but Task and other tools should still appear"""
    with tempfile.NamedTemporaryFile(mode='w', suffix='.jsonl', delete=False) as f:
        # Assistant sends a regular Task tool and a TaskOutput
        f.write(json.dumps({
            "message": {
                "role": "assistant",
                "content": [
                    {"type": "tool_use", "id": "toolu_01TASK", "name": "Task", "input": {"description": "Explore stuff", "subagent_type": "Explore", "prompt": "do things"}},
                    {"type": "tool_use", "id": "toolu_01OUT", "name": "TaskOutput", "input": {"task_id": "abc123", "block": True}}
                ]
            }
        }) + "\n")
        # Results for both
        f.write(json.dumps({
            "message": {
                "role": "user",
                "content": [
                    {"type": "tool_result", "tool_use_id": "toolu_01TASK", "content": "agent done"},
                    {"type": "tool_result", "tool_use_id": "toolu_01OUT", "content": "<output>result</output>"}
                ]
            }
        }) + "\n")
        temp_path = f.name

    try:
        mock_server = type('obj', (), {'last_voice_input': 'test'})()
        handler = TranscriptHandler(None, None, None, mock_server)

        blocks = handler.extract_new_assistant_content(temp_path)
        # Task tool_use + its result should appear; TaskOutput + its result should not
        tool_names = [b.name for b in blocks if isinstance(b, ToolUseBlock)]
        assert "Task" in tool_names
        assert "TaskOutput" not in tool_names
        # The Task result should be present
        result_ids = [b.tool_use_id for b in blocks if isinstance(b, ToolResultBlock)]
        assert "toolu_01TASK" in result_ids
        assert "toolu_01OUT" not in result_ids
    finally:
        os.unlink(temp_path)
