"""Tests for mock transcript JSONL generation."""

import json
import os
import tempfile
import pytest

from server.integration_tests.mock_transcript import (
    MockTranscript,
    create_empty_transcript,
    create_sample_transcript,
)


@pytest.fixture
def transcript_file():
    """Create a temp file for transcript testing."""
    fd, path = tempfile.mkstemp(suffix=".jsonl")
    os.close(fd)
    yield path
    os.unlink(path)


class TestMockTranscript:
    """Tests for MockTranscript JSONL format."""

    def test_add_user_message_format(self, transcript_file):
        """User messages use real transcript format: {"message": {"role": "user", ...}}"""
        t = MockTranscript(transcript_file)
        t.add_user_message("hello")

        with open(transcript_file) as f:
            entry = json.loads(f.readline())

        assert "message" in entry
        assert entry["message"]["role"] == "user"
        assert entry["message"]["content"] == [{"type": "text", "text": "hello"}]

    def test_add_assistant_message_format(self, transcript_file):
        """Assistant messages use real transcript format."""
        t = MockTranscript(transcript_file)
        t.add_assistant_message("world")

        with open(transcript_file) as f:
            entry = json.loads(f.readline())

        assert entry["message"]["role"] == "assistant"
        assert entry["message"]["content"] == [{"type": "text", "text": "world"}]

    def test_add_assistant_with_tool_use(self, transcript_file):
        """Tool use blocks have id, name, input."""
        t = MockTranscript(transcript_file)
        t.add_assistant_with_tool_use("Read", "tool-123", {"file_path": "/tmp/x"})

        with open(transcript_file) as f:
            entry = json.loads(f.readline())

        blocks = entry["message"]["content"]
        assert len(blocks) == 1
        assert blocks[0]["type"] == "tool_use"
        assert blocks[0]["id"] == "tool-123"
        assert blocks[0]["name"] == "Read"
        assert blocks[0]["input"] == {"file_path": "/tmp/x"}

    def test_add_tool_result(self, transcript_file):
        """Tool results are user messages with tool_result content."""
        t = MockTranscript(transcript_file)
        t.add_tool_result("tool-123", "file contents here")

        with open(transcript_file) as f:
            entry = json.loads(f.readline())

        assert entry["message"]["role"] == "user"
        blocks = entry["message"]["content"]
        assert blocks[0]["type"] == "tool_result"
        assert blocks[0]["tool_use_id"] == "tool-123"
        assert blocks[0]["content"] == "file contents here"

    def test_add_tool_result_with_error(self, transcript_file):
        """Tool results can indicate errors."""
        t = MockTranscript(transcript_file)
        t.add_tool_result("tool-456", "command failed", is_error=True)

        with open(transcript_file) as f:
            entry = json.loads(f.readline())

        blocks = entry["message"]["content"]
        assert blocks[0]["is_error"] is True

    def test_add_thinking_block(self, transcript_file):
        """Thinking blocks have thinking text and signature."""
        t = MockTranscript(transcript_file)
        t.add_thinking_block("Let me think about this...")

        with open(transcript_file) as f:
            entry = json.loads(f.readline())

        blocks = entry["message"]["content"]
        assert blocks[0]["type"] == "thinking"
        assert blocks[0]["thinking"] == "Let me think about this..."
        assert "signature" in blocks[0]

    def test_add_assistant_message_with_blocks(self, transcript_file):
        """Arbitrary blocks can be added."""
        t = MockTranscript(transcript_file)
        blocks = [
            {"type": "text", "text": "First"},
            {"type": "tool_use", "id": "t1", "name": "Bash", "input": {"command": "ls"}},
        ]
        t.add_assistant_message_with_blocks(blocks)

        with open(transcript_file) as f:
            entry = json.loads(f.readline())

        assert len(entry["message"]["content"]) == 2
        assert entry["message"]["content"][0]["type"] == "text"
        assert entry["message"]["content"][1]["type"] == "tool_use"

    def test_multiple_messages_are_valid_jsonl(self, transcript_file):
        """Each message is a separate JSON line."""
        t = MockTranscript(transcript_file)
        t.add_user_message("hello")
        t.add_assistant_message("hi")
        t.add_assistant_with_tool_use("Read", "t1", {"file_path": "/x"})
        t.add_tool_result("t1", "contents")

        with open(transcript_file) as f:
            lines = f.readlines()

        assert len(lines) == 4
        for line in lines:
            entry = json.loads(line)
            assert "message" in entry
            assert "timestamp" in entry

    def test_clear(self, transcript_file):
        """Clear removes all messages."""
        t = MockTranscript(transcript_file)
        t.add_user_message("hello")
        t.add_assistant_message("hi")
        t.clear()

        with open(transcript_file) as f:
            content = f.read()

        assert content == ""
        assert len(t.messages) == 0

    def test_get_last_assistant_message(self, transcript_file):
        """get_last_assistant_message returns text from last assistant entry."""
        t = MockTranscript(transcript_file)
        t.add_user_message("hello")
        t.add_assistant_message("first response")
        t.add_user_message("follow up")
        t.add_assistant_message("second response")

        assert t.get_last_assistant_message() == "second response"

    def test_create_empty_transcript(self, transcript_file):
        """create_empty_transcript produces an empty file."""
        create_empty_transcript(transcript_file)
        with open(transcript_file) as f:
            assert f.read() == ""

    def test_create_sample_transcript(self, transcript_file):
        """create_sample_transcript produces valid JSONL with messages."""
        t = create_sample_transcript(transcript_file)
        with open(transcript_file) as f:
            lines = f.readlines()

        assert len(lines) == 2
        first = json.loads(lines[0])
        assert first["message"]["role"] == "user"
        second = json.loads(lines[1])
        assert second["message"]["role"] == "assistant"
