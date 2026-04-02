"""
Mock transcript file generation for testing.

Creates JSONL files in the same format as real Claude Code transcripts.
Real format: {"message": {"role": "...", "content": [...]}, ...}
"""

import json
import time
from typing import List, Dict, Any


class MockTranscript:
    """Helper to create and manage mock Claude transcript files"""

    def __init__(self, filepath: str):
        self.filepath = filepath
        self.messages: List[Dict[str, Any]] = []

    def add_user_message(self, text: str):
        """Add a user message to the transcript."""
        entry = {
            "message": {
                "role": "user",
                "content": [{"type": "text", "text": text}],
            },
            "timestamp": time.time(),
        }
        self.messages.append(entry)
        self._write()

    def add_assistant_message(self, text: str):
        """Add an assistant text message to the transcript."""
        entry = {
            "message": {
                "role": "assistant",
                "content": [{"type": "text", "text": text}],
            },
            "timestamp": time.time(),
        }
        self.messages.append(entry)
        self._write()

    def add_assistant_message_with_blocks(self, blocks: List[Dict[str, Any]]):
        """Add an assistant message with arbitrary content blocks."""
        entry = {
            "message": {
                "role": "assistant",
                "content": blocks,
            },
            "timestamp": time.time(),
        }
        self.messages.append(entry)
        self._write()

    def add_assistant_with_tool_use(self, tool_name: str, tool_id: str, tool_input: dict):
        """Add assistant message with a tool_use block."""
        entry = {
            "message": {
                "role": "assistant",
                "content": [{"type": "tool_use", "id": tool_id, "name": tool_name, "input": tool_input}],
            },
            "timestamp": time.time(),
        }
        self.messages.append(entry)
        self._write()

    def add_tool_result(self, tool_use_id: str, content: str, is_error: bool = False):
        """Add user message with a tool_result block."""
        entry = {
            "message": {
                "role": "user",
                "content": [{"type": "tool_result", "tool_use_id": tool_use_id, "content": content, "is_error": is_error}],
            },
            "timestamp": time.time(),
        }
        self.messages.append(entry)
        self._write()

    def add_thinking_block(self, thinking_text: str):
        """Add assistant message with a thinking block."""
        entry = {
            "message": {
                "role": "assistant",
                "content": [{"type": "thinking", "thinking": thinking_text, "signature": "mock"}],
            },
            "timestamp": time.time(),
        }
        self.messages.append(entry)
        self._write()

    def clear(self):
        """Clear all messages"""
        self.messages = []
        self._write()

    def _write(self):
        """Write messages to the transcript file as JSONL."""
        with open(self.filepath, "w") as f:
            for msg in self.messages:
                f.write(json.dumps(msg) + "\n")

    def get_last_assistant_message(self) -> str:
        """Get the last assistant message text"""
        for msg in reversed(self.messages):
            message = msg.get("message", msg)
            if message.get("role") == "assistant":
                content = message.get("content", [])
                if isinstance(content, str):
                    return content
                elif isinstance(content, list):
                    for block in content:
                        if isinstance(block, dict) and block.get("type") == "text":
                            return block.get("text", "")
        return ""

    def simulate_conversation(self, exchanges: List[tuple]):
        """
        Simulate a conversation with multiple exchanges.

        Args:
            exchanges: List of (user_text, assistant_text) tuples
        """
        for user_text, assistant_text in exchanges:
            if user_text:
                self.add_user_message(user_text)
            if assistant_text:
                self.add_assistant_message(assistant_text)
                time.sleep(0.1)


def create_empty_transcript(filepath: str):
    """Create an empty transcript file"""
    with open(filepath, "w") as f:
        f.write("")


def create_sample_transcript(filepath: str):
    """Create a sample transcript with test data"""
    transcript = MockTranscript(filepath)
    transcript.add_user_message("Hello, how are you?")
    transcript.add_assistant_message("I'm doing well, thank you for asking! How can I help you today?")
    return transcript
